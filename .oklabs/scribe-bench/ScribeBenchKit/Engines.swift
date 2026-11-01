import Foundation
import ScribeCore

/// Batch `scribe_v2` over REST, with the parameters VoiceInk's batch fallback uses
/// (LLMkit `ElevenLabsClient`: temperature 0, no audio events, no_verbatim, keyterms).
public struct BatchScribe: Sendable {
    public let apiKey: String
    public let keyterms: [String]
    public var endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public var timeout: TimeInterval = 60

    public init(apiKey: String, keyterms: [String]) {
        self.apiKey = apiKey
        self.keyterms = keyterms
    }

    public func transcribe(_ samples: [Int16]) async throws -> String {
        let boundary = "oklabs-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                    .utf8))
        body.append(BenchAudio.wav16k(samples))
        body.append(Data("\r\n".utf8))
        field("model_id", "scribe_v2")
        field("temperature", "0.0")
        field("tag_audio_events", "false")
        field("no_verbatim", "true")
        for term in keyterms { field("keyterms", term) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Status only: an error body may echo request details. A bad key, missing
            // credits or permissions cannot get better by retrying; 429 can.
            if status == 401 || status == 402 || status == 403 { throw ScribeError.fatal("batch HTTP \(status)") }
            throw ScribeError.retryable("batch HTTP \(status)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String
        else {
            throw ScribeError.retryable("batch response without text")
        }
        return text
    }
}

/// The fork's live engine (`ScribeLiveSession`, the same code the app runs).
public struct LiveScribe: Sendable {
    public let apiKey: String
    public let keyterms: [String]
    public var endpoint = ScribeLimits.defaultEndpoint
    public var language: String? = nil

    public init(apiKey: String, keyterms: [String]) {
        self.apiKey = apiKey
        self.keyterms = keyterms
    }

    public struct Result: Sendable {
        public let outcome: ScribeOutcome
        /// From the end of the audio (stop) to the outcome.
        public let stopToResult: TimeInterval
        public let stats: ScribeSessionStats

        public init(outcome: ScribeOutcome, stopToResult: TimeInterval, stats: ScribeSessionStats) {
            self.outcome = outcome
            self.stopToResult = stopToResult
            self.stats = stats
        }
    }

    /// Streams `samples` in 10 ms render-sized chunks; `realtime` paces them at 1x
    /// like a microphone, otherwise they go out as fast as the socket takes them.
    public func run(_ samples: [Int16], realtime: Bool) async throws -> Result {
        let url = try ScribeURL.build(endpoint: endpoint, language: language, keyterms: keyterms)
        // At 1x the app's 8 s final wait applies. At upload speed the same wait would
        // also have to cover sending the whole file, so give it what voxtype gives an
        // upload (timeout + audio/2); frames stay 100 ms, as in the app.
        let audioSeconds = Double(samples.count) / Double(ScribeLimits.sampleRate)
        let finalWait = realtime ? ScribeLimits.liveFinalWait : 20 + audioSeconds / 2
        let session = ScribeLiveSession(config: ScribeSessionConfig(url: url, apiKey: apiKey, finalWait: finalWait))
        try await session.connect()
        let chunk = 160
        let started = Date()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            await session.append(ScribeWire.pcmBytes(Array(samples[offset..<end])))
            offset = end
            if realtime {
                let due = started.addingTimeInterval(Double(offset) / Double(ScribeLimits.sampleRate))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
        }
        let stop = Date()
        let outcome = await session.finish()
        let elapsed = Date().timeIntervalSince(stop)
        let stats = await session.snapshot()
        await session.close()
        return Result(outcome: outcome, stopToResult: elapsed, stats: stats)
    }
}
