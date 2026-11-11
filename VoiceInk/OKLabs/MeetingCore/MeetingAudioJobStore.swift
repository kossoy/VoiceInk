import Foundation

public struct MeetingAudioJob: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, failed, completed }
    public let id: UUID
    public let source: MeetingAudioSource
    public let range: MeetingTimeRange
    public let modelKey: String
    public let language: String?
    public var state: State
    public var error: String?
    /// Transient failures of this chunk so far (auto-retried). Absent in job files written
    /// before auto-retry, decoded as 0.
    public var attempts: Int = 0

    private enum CodingKeys: String, CodingKey { case id, source, range, modelKey, language, state, error, attempts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(MeetingAudioSource.self, forKey: .source)
        range = try c.decode(MeetingTimeRange.self, forKey: .range)
        modelKey = try c.decode(String.self, forKey: .modelKey)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        state = try c.decode(State.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }

    public init(chunk: MeetingAudioChunk, modelKey: String, language: String?) {
        id = UUID()
        source = chunk.source
        range = chunk.range
        self.modelKey = modelKey
        self.language = language
        state = .pending
    }
}

/// Durable queue: audio is written before a job becomes available to ASR.
/// Serialized with the session store by the meeting coordinator.
public struct MeetingAudioJobStore {
    public let directory: URL

    public init(sessionDirectory: URL) {
        directory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    public func audioURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).wav") }

    public func enqueue(_ chunk: MeetingAudioChunk, modelKey: String, language: String?) throws -> MeetingAudioJob {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = MeetingAudioJob(chunk: chunk, modelKey: modelKey, language: language)
        try MeetingWAV.encode(chunk.samples).write(to: audioURL(for: job.id), options: .atomic)
        try save(job)
        return job
    }

    public func save(_ job: MeetingAudioJob) throws {
        try MeetingTranscriptExport.encoder().encode(job).write(
            to: directory.appendingPathComponent("\(job.id.uuidString).json"), options: .atomic)
    }

    public func load() throws -> [MeetingAudioJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        return try urls.filter { $0.pathExtension == "json" }.map { url in
            let job = try decoder.decode(MeetingAudioJob.self, from: Data(contentsOf: url))
            guard url.deletingPathExtension().lastPathComponent == job.id.uuidString else {
                throw MeetingSessionError.unsupportedCheckpoint
            }
            _ = try MeetingTimeRange(start: job.range.start, end: job.range.end)
            return job
        }.sorted { $0.range.start < $1.range.start }
    }
}
