import Foundation

public enum MeetingTranscriptExport {
    public static func text(_ session: MeetingSession) -> String {
        session.finalSegments.map { segment in
            "[\(timestamp(segment.range.start))] \(MeetingSpeakerResolver.label(for: segment, cues: session.speakerCues)): \(segment.text)"
        }.joined(separator: "\n")
    }

    public static func markdown(_ session: MeetingSession) -> String {
        let title = session.title.components(separatedBy: .newlines).joined(separator: " ")
        let paragraphs = session.finalSegments.map { segment in
            "**[\(timestamp(segment.range.start))] \(MeetingSpeakerResolver.label(for: segment, cues: session.speakerCues))**\n\n\(segment.text)"
        }
        return (["# \(title)"] + paragraphs).joined(separator: "\n\n") + "\n"
    }

    /// JSON is a raw, structured transcript; partial hypotheses are excluded.
    public static func json(_ session: MeetingSession) throws -> Data {
        try encoder().encode(session.finalSegments.map {
            ExportedSegment(
                id: $0.id, start: $0.range.start, end: $0.range.end, source: $0.source,
                speaker: MeetingSpeakerResolver.label(for: $0, cues: session.speakerCues), text: $0.text
            )
        })
    }

    private struct ExportedSegment: Encodable {
        let id: UUID
        let start: TimeInterval
        let end: TimeInterval
        let source: MeetingAudioSource
        let speaker: String
        let text: String
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        // Valid session ranges are finite and nonnegative. Avoid integer conversion overflow.
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1_000) else { return "unknown" }
        let milliseconds = Int(seconds * 1_000)
        return String(
            format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000, milliseconds / 60_000 % 60,
            milliseconds / 1_000 % 60, milliseconds % 1_000
        )
    }
}

/// Call from one serialized owner. The atomic checkpoint is authoritative; exports are derived.
public struct MeetingTranscriptStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    @discardableResult
    public func save(_ session: MeetingSession) throws -> URL {
        try session.validate()
        let directory = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MeetingTranscriptExport.encoder().encode(session)
            .write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try refreshExports(session, in: directory)
        return directory
    }

    public func load(id: UUID) throws -> MeetingSession {
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("session.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let session = try decoder.decode(MeetingSession.self, from: Data(contentsOf: url))
        guard session.id == id else { throw MeetingSessionError.unsupportedCheckpoint }
        try session.validate()
        return session
    }

    private func refreshExports(_ session: MeetingSession, in directory: URL) throws {
        try MeetingTranscriptExport.text(session).write(
            to: directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try MeetingTranscriptExport.markdown(session).write(
            to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try MeetingTranscriptExport.json(session).write(
            to: directory.appendingPathComponent("transcript.json"), options: .atomic)
    }
}
