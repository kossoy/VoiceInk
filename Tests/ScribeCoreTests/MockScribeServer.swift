import CryptoKit
import Darwin
import Foundation

/// A scripted ElevenLabs Scribe v2 Realtime server on 127.0.0.1.
///
/// Minimal RFC 6455 over POSIX sockets, one thread per connection, so a test can
/// control everything the real server does, including never reading (a
/// black-holed network) or never finishing the handshake. Mirrors voxtype's
/// mock in `src/transcribe/elevenlabs/tests.rs`.
final class MockScribeServer: @unchecked Sendable {
    enum Script: Equatable, Sendable {
        /// Answers every commit with `committed_transcript` "seg<n>", partial "p" per chunk.
        case normal
        /// Like normal, plus one unsolicited "auto<n>" commit once this many samples arrived.
        case autoCommitAfter(Int)
        /// `auth_error` instead of `session_started`.
        case authError
        /// `transcriber_error` after the first audio chunk, then close.
        case failAfterFirstChunk
        /// Closes the socket (no message) once this many samples arrived.
        case closeAfter(Int)
        /// Never answers commits.
        case silent
        /// Answers every commit with `commit_throttled`.
        case throttleAll
        /// Accepts TCP but never completes the WebSocket handshake.
        case hang
        /// Completes the handshake, then never reads again.
        case blackhole
    }

    struct Chunk: Equatable, Sendable {
        let samples: Int
        let commit: Bool
        let hasPreviousText: Bool
    }

    struct Connection: Sendable {
        var path = ""
        var apiKey: String?
        var chunks: [Chunk] = []
        var closed = false

        var samples: Int { chunks.reduce(0) { $0 + $1.samples } }
        var commits: Int { chunks.filter(\.commit).count }
        /// Audio per segment, in samples, ending at each commit.
        var segments: [Int] {
            var out: [Int] = []
            var acc = 0
            for chunk in chunks {
                acc += chunk.samples
                if chunk.commit {
                    out.append(acc)
                    acc = 0
                }
            }
            return out
        }
    }

    enum MockError: Error { case socket(String) }

    /// The real server commits on its own after ~36 s of uncommitted audio.
    static let serverAutoCommitSamples = 36 * 16_000

    let port: UInt16
    private let listenFD: Int32
    private let scripts: [Script]
    private let lock = NSLock()
    private var connectionLogs: [Connection] = []
    private var clientFDs: [Int32] = []
    private var stopped = false

    var endpoint: URL { URL(string: "ws://127.0.0.1:\(port)/v1/speech-to-text/realtime")! }

    init(_ scripts: [Script], receiveBufferBytes: Int32? = nil) throws {
        precondition(!scripts.isEmpty)
        self.scripts = scripts
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockError.socket("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if var size = receiveBufferBytes {
            // Inherited by accepted sockets: a tiny receive window stalls the client's writes quickly.
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw MockError.socket("bind/listen")
        }
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: out.sin_port)
        listenFD = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        Thread { [self] in acceptLoop() }.start()
    }

    deinit {
        stop()
    }

    var connections: [Connection] {
        locked { connectionLogs }
    }

    func stop() {
        let first: Bool = locked {
            guard !stopped else { return false }
            stopped = true
            // Under the lock: a serve thread closes (and forgets) its fd under the same
            // lock, so a reused descriptor number is never shut down by mistake.
            for fd in clientFDs { shutdown(fd, SHUT_RDWR) }
            return true
        }
        if first { Darwin.close(listenFD) }
    }

    /// Waits until `condition` holds on the logs, up to `timeout` seconds.
    func waitFor(timeout: TimeInterval = 3, _ condition: ([Connection]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(connections) { return true }
            usleep(20_000)
        }
        return condition(connections)
    }

    // MARK: - Server loop

    private var isStopped: Bool { locked { stopped } }

    private func acceptLoop() {
        while !isStopped {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready <= 0 { continue }
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            let flags = fcntl(client, F_GETFL)
            _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let (script, slot): (Script, Int) = locked {
                let index = connectionLogs.count
                connectionLogs.append(Connection())
                clientFDs.append(client)
                return (scripts[min(index, scripts.count - 1)], index)
            }
            Thread { [self] in serve(client, script: script, slot: slot) }.start()
        }
    }

    private func serve(_ fd: Int32, script: Script, slot: Int) {
        defer {
            locked {
                connectionLogs[slot].closed = true
                clientFDs.removeAll { $0 == fd }
                Darwin.close(fd)
            }
        }
        if script == .hang {
            drainUntilClosed(fd)
            return
        }
        guard let request = readRequest(fd) else { return }
        let (path, headers) = parseRequest(request)
        locked {
            connectionLogs[slot].path = path
            connectionLogs[slot].apiKey = headers["xi-api-key"]
        }
        guard let key = headers["sec-websocket-key"] else { return }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard writeAll(fd, Data(response.utf8)) else { return }

        if script == .authError {
            sendText(fd, Self.message("auth_error", "Invalid API key"))
            sendFrame(fd, opcode: 0x8, payload: Data())
            return
        }
        sendText(fd, #"{"message_type":"session_started","session_id":"mock","config":{}}"#)
        if script == .blackhole {
            idle()
            return
        }

        var uncommitted = 0
        var total = 0
        var answered = 0
        var autos = 0
        var scriptedAutoSent = false
        while let text = readMessage(fd) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                object["message_type"] as? String == "input_audio_chunk"
            else {
                continue
            }
            let audio = Data(base64Encoded: object["audio_base_64"] as? String ?? "") ?? Data()
            let samples = audio.count / 2
            let commit = object["commit"] as? Bool ?? false
            locked {
                connectionLogs[slot].chunks.append(
                    Chunk(samples: samples, commit: commit, hasPreviousText: object["previous_text"] != nil))
            }
            uncommitted += samples
            total += samples

            if script == .failAfterFirstChunk {
                sendText(fd, Self.message("transcriber_error", "boom"))
                sendFrame(fd, opcode: 0x8, payload: Data())
                return
            }
            if case .closeAfter(let limit) = script, total >= limit {
                return
            }
            sendText(fd, Self.message("partial_transcript", "p"))
            if case .autoCommitAfter(let after) = script, !scriptedAutoSent, total >= after {
                scriptedAutoSent = true
                uncommitted = 0
                autos += 1
                sendText(fd, Self.message("committed_transcript", "auto\(autos)"))
            }
            if uncommitted >= Self.serverAutoCommitSamples {
                uncommitted = 0
                autos += 1
                sendText(fd, Self.message("committed_transcript", "auto\(autos)"))
            }
            if commit && script != .silent {
                if script == .throttleAll || uncommitted < 4_800 {
                    sendText(fd, Self.message("commit_throttled", "too little audio"))
                } else {
                    answered += 1
                    uncommitted = 0
                    sendText(fd, Self.message("committed_transcript", "seg\(answered)"))
                }
            }
        }
    }

    /// Reads and discards everything (never answering the upgrade) until the client goes away.
    private func drainUntilClosed(_ fd: Int32) {
        let end = Date().addingTimeInterval(60)
        var scratch = [UInt8](repeating: 0, count: 4_096)
        while !isStopped && Date() < end {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let n = scratch.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
            if n <= 0 { return }
        }
    }

    private func idle() {
        let end = Date().addingTimeInterval(60)
        while !isStopped && Date() < end { usleep(50_000) }
    }

    static func message(_ type: String, _ text: String) -> String {
        let object: [String: Any] = ["message_type": type, "text": text, "error": text]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - HTTP + WebSocket framing

    private func readRequest(_ fd: Int32) -> String? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            guard buffer.count < 65_536, let byte = readExact(fd, 1) else { return nil }
            buffer.append(byte)
        }
        return String(data: buffer, encoding: .utf8)
    }

    private func parseRequest(_ request: String) -> (String, [String: String]) {
        var lines = request.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : ""
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (path, headers)
    }

    /// Next complete text message; nil once the client closes or the socket fails.
    private func readMessage(_ fd: Int32) -> String? {
        var payload = Data()
        while true {
            guard let header = readExact(fd, 2) else { return nil }
            let bytes = [UInt8](header)
            let fin = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = UInt64(bytes[1] & 0x7F)
            if length == 126 {
                guard let ext = readExact(fd, 2) else { return nil }
                length = ext.reduce(0) { ($0 << 8) | UInt64($1) }
            } else if length == 127 {
                guard let ext = readExact(fd, 8) else { return nil }
                length = ext.reduce(0) { ($0 << 8) | UInt64($1) }
            }
            var mask: [UInt8] = [0, 0, 0, 0]
            if masked {
                guard let key = readExact(fd, 4) else { return nil }
                mask = [UInt8](key)
            }
            guard let raw = readExact(fd, Int(length)) else { return nil }
            var body = [UInt8](raw)
            if masked {
                for i in body.indices { body[i] ^= mask[i & 3] }
            }
            switch opcode {
            case 0x8:
                sendFrame(fd, opcode: 0x8, payload: Data())
                return nil
            case 0x9:
                sendFrame(fd, opcode: 0xA, payload: Data(body))
            case 0xA:
                continue
            case 0x0, 0x1, 0x2:
                payload.append(contentsOf: body)
                if fin { return String(data: payload, encoding: .utf8) ?? "" }
            default:
                return nil
            }
        }
    }

    private func readExact(_ fd: Int32, _ count: Int) -> Data? {
        if count == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + got, count - got, 0)
            }
            if n <= 0 { return nil }
            got += n
        }
        return Data(buffer)
    }

    private func sendText(_ fd: Int32, _ text: String) {
        sendFrame(fd, opcode: 0x1, payload: Data(text.utf8))
    }

    @discardableResult
    private func sendFrame(_ fd: Int32, opcode: UInt8, payload: Data) -> Bool {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return writeAll(fd, frame)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
