import Foundation

/// How a live session ended.
public enum ScribeOutcome: Equatable, Sendable {
    /// Every commit was answered; the joined text of all segments.
    case text(String)
    /// The stream cannot be trusted. Retryable failures go to batch re-upload.
    case failed(ScribeError)
}

/// What the UI hears while the user speaks.
public enum ScribeSessionEvent: Equatable, Sendable {
    case partial(String)
    case committed(String)
    case warning(String)
    case failed(ScribeError)
}

public struct ScribeSessionConfig: Sendable {
    public var url: URL
    public var apiKey: String
    public var previousText: String? = nil
    public var connectTimeout: TimeInterval = ScribeLimits.connectTimeout
    /// Longest wait after `finish()`, counted from the stop request (voxtype 884b6bb).
    public var finalWait: TimeInterval = ScribeLimits.liveFinalWait
    public var sendStall: TimeInterval = ScribeLimits.sendStall
    public var frameSamples: Int = ScribeLimits.liveFrameSamples

    public init(
        url: URL,
        apiKey: String,
        previousText: String? = nil,
        connectTimeout: TimeInterval = ScribeLimits.connectTimeout,
        finalWait: TimeInterval = ScribeLimits.liveFinalWait,
        sendStall: TimeInterval = ScribeLimits.sendStall,
        frameSamples: Int = ScribeLimits.liveFrameSamples
    ) {
        self.url = url
        self.apiKey = apiKey
        self.previousText = previousText
        self.connectTimeout = connectTimeout
        self.finalWait = finalWait
        self.sendStall = sendStall
        self.frameSamples = frameSamples
    }
}

public struct ScribeSessionStats: Equatable, Sendable {
    public init() {}

    public var receivedSamples = 0
    /// Real audio written to the socket (padding excluded).
    public var sentSamples = 0
    public var paddedSamples = 0
    public var framesSent = 0
    public var commitsSent = 0
    public var commitsAnswered = 0
    public var unsolicitedCommits = 0
    public var throttledCommits = 0
    public var partials = 0
    public var segments = 0
}

/// Failure flag readable without `await` (the provider's `stopDisposition` is synchronous).
public final class ScribeSessionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: ScribeError?

    public var failure: ScribeError? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    fileprivate func record(_ error: ScribeError) {
        lock.lock()
        if storedFailure == nil { storedFailure = error }
        lock.unlock()
    }
}

/// One live dictation on one Scribe v2 Realtime connection (voxtype `run_live` + `Conn`).
///
/// - `append(_:)` never blocks: audio is framed into 100 ms frames, the segmenter
///   marks mid-stream commits (first pause after 30 s, always by 34 s), and a
///   single writer sends frames in order.
/// - Any send error, a write that blocks for `sendStall`, a server error, or the
///   connection closing marks the session failed. The app then re-uploads the
///   whole recording to the mode's batch model.
/// - `finish()` sends the tail, padded so the final commit is never throttled,
///   and waits until every commit is answered, at most `finalWait` after the stop
///   request, stalled writes included.
public actor ScribeLiveSession {
    public nonisolated let status = ScribeSessionStatus()
    public nonisolated let events: AsyncStream<ScribeSessionEvent>
    private let eventSink: AsyncStream<ScribeSessionEvent>.Continuation

    private let config: ScribeSessionConfig
    private let makeConnection: ScribeConnectionFactory
    private var connection: (any ScribeConnection)?
    private var receiveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    private var framer: PCMFramer
    private var segmenter = Segmenter()
    private var ledger = CommitLedger()
    private var previousText: String?

    private struct Outgoing: Sendable {
        let text: String
        let commit: Bool
        let realSamples: Int
    }

    private var outbox: [Outgoing] = []
    private var writing = false
    private var connected = false
    private var failure: ScribeError?
    private var finishing = false
    private var resolved = false
    private var closed = false
    private var waiter: AsyncStream<ScribeOutcome>.Continuation?
    private var stats = ScribeSessionStats()

    public init(
        config: ScribeSessionConfig,
        connectionFactory: @escaping ScribeConnectionFactory = URLSessionScribeConnection.factory
    ) {
        self.config = config
        self.makeConnection = connectionFactory
        self.framer = PCMFramer(frameSamples: config.frameSamples)
        self.previousText = config.previousText
        let (stream, continuation) = AsyncStream.makeStream(of: ScribeSessionEvent.self)
        self.events = stream
        self.eventSink = continuation
    }

    // MARK: - Public API

    /// Opens the socket and waits for `session_started`, within `connectTimeout`.
    public func connect() async throws {
        if let failure { throw failure }
        guard !closed, !resolved else { throw ScribeError.retryable("cancelled") }
        guard connection == nil else { return }
        let conn = makeConnection(config.url, config.apiKey)
        connection = conn
        conn.resume()
        let result = await Self.handshake(conn, timeout: config.connectTimeout)
        if let failure { throw failure }
        if closed {
            // close() ran during the handshake: it already closed `conn`.
            throw ScribeError.retryable("cancelled")
        }
        switch result {
        case .success:
            connected = true
            startReceiving(conn)
            pump()
        case .failure(let error):
            fail(error)
            throw error
        }
    }

    /// Queues raw PCM16 LE 16 kHz mono audio. Never blocks on the network.
    public func append(_ data: Data) {
        guard !finishing else { return }
        let frames = framer.append(data)
        stats.receivedSamples = framer.receivedSamples
        guard failure == nil else { return }
        for frame in frames {
            enqueue(frame, commit: segmenter.push(frame), realSamples: frame.count)
        }
    }

    /// Queues samples directly (tests and uploads).
    public func append(samples: [Int16]) {
        guard !finishing else { return }
        let frames = framer.append(samples: samples)
        stats.receivedSamples = framer.receivedSamples
        guard failure == nil else { return }
        for frame in frames {
            enqueue(frame, commit: segmenter.push(frame), realSamples: frame.count)
        }
    }

    /// Stop: send the tail and the final commit, wait for every answer.
    public func finish() async -> ScribeOutcome {
        guard !finishing else { return .failed(.retryable("finish called twice")) }
        finishing = true
        if closed || resolved {
            // Cancelled before stop finished draining: nothing can be answered any more.
            return .failed(failure ?? .retryable("cancelled"))
        }
        if let failure {
            closeConnection()
            return .failed(failure)
        }
        guard connection != nil else { return .failed(.retryable("no connection")) }

        let rest = framer.takeRemainder()
        if !rest.isEmpty {
            // Last frame: commit it, padded if the final segment is short.
            let uncommitted = segmenter.uncommitted + rest.count
            var frame = rest
            if uncommitted < ScribeLimits.minCommitSamples {
                frame.append(contentsOf: repeatElement(0, count: ScribeLimits.minCommitSamples - uncommitted))
            }
            stats.paddedSamples += frame.count - rest.count
            enqueue(frame, commit: true, realSamples: rest.count)
            segmenter.reset()
        } else if segmenter.uncommitted > 0 {
            // Nothing left to send: commit whatever was streamed.
            let pad = max(0, ScribeLimits.minCommitSamples - segmenter.uncommitted)
            stats.paddedSamples += pad
            enqueue(Array(repeating: 0, count: pad), commit: true, realSamples: 0)
            segmenter.reset()
        }

        if let outcome = currentOutcome() {
            resolved = true
            closeConnection()
            return outcome
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ScribeOutcome.self)
        waiter = continuation
        let wait = max(0, config.finalWait)
        deadlineTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await self?.deadlineReached()
        }
        for await outcome in stream {
            return outcome
        }
        return .failed(.retryable("final wait interrupted"))
    }

    /// Cancel: never commits, closes the socket, ends `events`.
    public func close() {
        if waiter != nil { deliver(.failed(.retryable("cancelled"))) }
        resolved = true
        closeConnection()
        eventSink.finish()
    }

    public func snapshot() -> ScribeSessionStats {
        var snapshot = stats
        snapshot.commitsSent = ledger.commitsSent
        snapshot.commitsAnswered = ledger.commitsAnswered
        snapshot.unsolicitedCommits = ledger.unsolicitedCommits
        snapshot.throttledCommits = ledger.throttledCommits
        snapshot.partials = ledger.partials
        snapshot.segments = ledger.segments.count
        return snapshot
    }

    // MARK: - Connection

    private static func handshake(_ conn: any ScribeConnection, timeout: TimeInterval) async -> Result<
        Void, ScribeError
    > {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, ScribeError>, Never>) in
            let once = ScribeOneShot(continuation)
            Task.detached {
                once.resume(await waitForSessionStarted(conn))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(.retryable("connect timed out after \(Self.seconds(timeout))")))
            }
        }
    }

    private static func waitForSessionStarted(_ conn: any ScribeConnection) async -> Result<Void, ScribeError> {
        do {
            while true {
                let raw = try await conn.receive()
                guard let message = ScribeServerMessage.parse(raw) else { continue }
                if message.messageType == "session_started" { return .success(()) }
                if let error = ScribeError.classify(
                    messageType: message.messageType, detail: message.error ?? "(no detail)")
                {
                    return .failure(error)
                }
            }
        } catch {
            if let code = conn.handshakeStatusCode, code == 401 || code == 403 {
                return .failure(.fatal("WebSocket handshake rejected: HTTP \(code)"))
            }
            return .failure(.retryable("connect failed: \(error.localizedDescription)"))
        }
    }

    private func startReceiving(_ conn: any ScribeConnection) {
        receiveTask = Task.detached { [weak self] in
            while true {
                let raw: String
                do {
                    raw = try await conn.receive()
                } catch {
                    await self?.connectionLost(error)
                    return
                }
                guard let self else { return }
                await self.handle(raw)
            }
        }
    }

    private func handle(_ raw: String) {
        guard failure == nil, !resolved, let message = ScribeServerMessage.parse(raw) else { return }
        do {
            switch try ledger.on(message) {
            case .partial(let text): eventSink.yield(.partial(text))
            case .committed(let text): eventSink.yield(.committed(text))
            case .warning(let text): eventSink.yield(.warning(text))
            case .none: break
            }
        } catch let error as ScribeError {
            fail(error)
            return
        } catch {
            fail(.retryable(error.localizedDescription))
            return
        }
        resolveIfDone()
    }

    private func connectionLost(_ error: Error) {
        guard !closed, !resolved else { return }
        fail(.retryable("connection closed (\(error.localizedDescription))"))
    }

    // MARK: - Writer

    private func enqueue(_ samples: [Int16], commit: Bool, realSamples: Int) {
        let text = ScribeWire.chunkMessage(samples: samples, commit: commit, previousText: previousText)
        previousText = nil
        outbox.append(Outgoing(text: text, commit: commit, realSamples: realSamples))
        pump()
    }

    /// One write at a time, in order. A write that does not complete within
    /// `sendStall` fails the session; it is never awaited by `finish()`.
    private func pump() {
        guard connected, !writing, failure == nil, !closed, !outbox.isEmpty, let conn = connection else { return }
        let next = outbox.removeFirst()
        writing = true
        if next.commit { ledger.recordCommitSent() }
        let stall = config.sendStall
        Task.detached { [weak self] in
            let error = await Self.write(next.text, on: conn, stall: stall)
            await self?.didWrite(next, error: error)
        }
    }

    private static func write(_ text: String, on conn: any ScribeConnection, stall: TimeInterval) async
        -> ScribeError?
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<ScribeError?, Never>) in
            let once = ScribeOneShot(continuation)
            conn.send(text) { error in
                once.resume(error.map { ScribeError.retryable("send failed: \($0.localizedDescription)") })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + stall) {
                once.resume(.retryable("connection stalled (a write blocked for \(Self.seconds(stall)))"))
            }
        }
    }

    private func didWrite(_ message: Outgoing, error: ScribeError?) {
        writing = false
        if let error {
            fail(error)
            return
        }
        stats.framesSent += 1
        stats.sentSamples += message.realSamples
        pump()
        resolveIfDone()
    }

    // MARK: - Completion

    private func currentOutcome() -> ScribeOutcome? {
        if let failure { return .failed(failure) }
        guard finishing, connected, outbox.isEmpty, !writing, ledger.isComplete else { return nil }
        return .text(ledger.text)
    }

    private func resolveIfDone() {
        guard waiter != nil, let outcome = currentOutcome() else { return }
        deliver(outcome)
    }

    private func deliver(_ outcome: ScribeOutcome) {
        guard let waiter else { return }
        self.waiter = nil
        resolved = true
        deadlineTask?.cancel()
        deadlineTask = nil
        waiter.yield(outcome)
        waiter.finish()
        closeConnection()
    }

    private func deadlineReached() {
        guard waiter != nil else { return }
        let error = ScribeError.retryable(
            "no final transcript (\(ledger.commitsAnswered) of \(ledger.commitsSent) commits answered) before the deadline")
        fail(error)
        // fail() is a no-op once resolved; the waiter must be resumed regardless.
        if waiter != nil { deliver(.failed(failure ?? error)) }
    }

    private func fail(_ error: ScribeError) {
        guard failure == nil, !resolved else { return }
        failure = error
        status.record(error)
        outbox.removeAll()
        eventSink.yield(.failed(error))
        closeConnection()
        if waiter != nil { deliver(.failed(error)) }
    }

    private func closeConnection() {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        connection?.close()
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value))s" : String(format: "%.1fs", value)
    }
}
