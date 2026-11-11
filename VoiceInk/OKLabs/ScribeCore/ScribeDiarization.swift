import Foundation

/// Batch Scribe v3 with speaker diarization over one finished audio file (a meeting's stitched
/// system-audio track). `POST /v1/speech-to-text` with `diarize=true` and word timestamps:
/// https://elevenlabs.io/docs/api-reference/speech-to-text/convert
///
/// The request body is written to a temporary file and uploaded from disk: a 3 h track is
/// ~345 MB of 16 kHz PCM. The API takes files under 5 GB and splits long audio itself, so one
/// request carries the whole track (one request keeps `speaker_id` consistent end to end).
public struct ScribeDiarizationRequest: Sendable {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    /// Stay clear of the documented 5 GB limit.
    public static let maxUploadBytes: Int64 = 4_500_000_000

    public struct Word: Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let speakerID: String
    }

    public let apiKey: String
    public var model = ScribeModels.batchV3
    public var endpoint = ScribeDiarizationRequest.endpoint
    /// Long tracks take minutes to transcribe server-side.
    public var timeout: TimeInterval = 1_800

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Form fields, in order. No keyterms (they cost 20% extra and the transcript text is not used).
    public var fields: [(String, String)] {
        [
            ("model_id", model),
            ("diarize", "true"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
            ("no_verbatim", "true"),
        ]
    }

    /// Writes the multipart body around `audio` into `body`; returns the content type.
    public func writeBody(audio: URL, to body: URL, boundary: String = "oklabs-\(UUID().uuidString)") throws -> String {
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        defer { try? out.close() }
        for (name, value) in fields {
            try out.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try out.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"system.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                .utf8))
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return "multipart/form-data; boundary=\(boundary)"
    }

    /// Uploads `audio` and returns its words with speaker labels, in time order.
    public func run(audio: URL) async throws -> [Word] {
        let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int64) ?? 0
        guard size > 0, size < Self.maxUploadBytes else {
            throw ScribeError.fatal("audio of \(size) bytes is outside the upload limit")
        }
        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-diarization-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        let contentType = try writeBody(audio: audio, to: body)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Status only: an error body may echo request details.
            if status == 401 || status == 402 || status == 403 { throw ScribeError.fatal("diarization HTTP \(status)") }
            throw ScribeError.retryable("diarization HTTP \(status)")
        }
        return try Self.parse(data)
    }

    /// Spoken words with a speaker and timing; spacing, audio events and unlabeled words are skipped.
    public static func parse(_ data: Data) throws -> [Word] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScribeError.retryable("diarization response is not a JSON object")
        }
        guard let words = object["words"] as? [[String: Any]] else {
            throw ScribeError.retryable("diarization response without words")
        }
        return words.compactMap { word in
            guard (word["type"] as? String ?? "word") == "word",
                let text = word["text"] as? String,
                let start = (word["start"] as? NSNumber)?.doubleValue,
                let end = (word["end"] as? NSNumber)?.doubleValue, end >= start,
                let speaker = word["speaker_id"] as? String, !speaker.isEmpty
            else { return nil }
            return Word(text: text, start: start, end: end, speakerID: speaker)
        }.sorted { $0.start < $1.start }
    }
}
