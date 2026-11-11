import Foundation

/// One continuous stretch of speech that a diarizer attributes to one voice cluster.
/// Times are on the session clock, like transcript segments.
public struct MeetingSpeakerTurn: Codable, Equatable, Sendable {
    public let clusterID: String
    public let range: MeetingTimeRange

    public init(clusterID: String, range: MeetingTimeRange) {
        self.clusterID = clusterID
        self.range = range
    }
}

/// Machine output of a diarization pass over the system-audio track ("Others").
/// Stored beside session.json as diarization.json and regenerated, never edited by hand:
/// user names live in the session (`MeetingSpeakerAssignments`) so a rerun keeps them.
/// Voice embeddings are deliberately not stored.
public struct MeetingDiarization: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// For example "fluidaudio-offline-vbx".
    public let engine: String
    public let createdAt: Date
    /// Seconds of audio the diarizer processed.
    public let audioSeconds: TimeInterval
    /// Seconds it took, for diagnostics.
    public let processingSeconds: TimeInterval
    public let turns: [MeetingSpeakerTurn]

    public init(
        engine: String, createdAt: Date = Date(), audioSeconds: TimeInterval,
        processingSeconds: TimeInterval, turns: [MeetingSpeakerTurn]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.engine = engine
        self.createdAt = createdAt
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
        self.turns = turns.sorted { $0.range.start < $1.range.start }
    }

    /// Cluster IDs ordered by first appearance, which numbers them "Speaker 1", "Speaker 2", ...
    public var clusterIDs: [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.clusterID).inserted ? $0.clusterID : nil }
    }

    /// Default label for a cluster: "Speaker N" by first appearance.
    public func ordinalName(of clusterID: String) -> String? {
        clusterIDs.firstIndex(of: clusterID).map { "Speaker \($0 + 1)" }
    }

    /// The cluster that covers most of `range`, if it covers at least `minimumShare` of it.
    /// A transcript segment of up to 12 s can hold two voices; it takes the dominant one.
    public func dominantCluster(for range: MeetingTimeRange, minimumShare: Double = 0.25) -> String? {
        let duration = range.end - range.start
        guard duration > 0 else { return nil }
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let seconds = Self.overlap(turn.range, range)
            if seconds > 0 { overlap[turn.clusterID, default: 0] += seconds }
        }
        guard let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
            best.value >= duration * minimumShare
        else { return nil }
        return best.key
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw MeetingSessionError.unsupportedCheckpoint }
        for turn in turns {
            _ = try MeetingTimeRange(start: turn.range.start, end: turn.range.end)
            guard !turn.clusterID.isEmpty else { throw MeetingSessionError.unsupportedCheckpoint }
        }
    }

    static func overlap(_ a: MeetingTimeRange, _ b: MeetingTimeRange) -> TimeInterval {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }
}

/// Names the user gave. Stored in session.json (schema 2), so they survive a diarization rerun.
public struct MeetingSpeakerAssignments: Codable, Equatable, Sendable {
    /// Cluster ID -> name. Renames every line of that voice.
    public var clusterNames: [String: String]
    /// Transcript segment ID -> name. "Only this line"; wins over everything else.
    public var segmentNames: [UUID: String]

    public init(clusterNames: [String: String] = [:], segmentNames: [UUID: String] = [:]) {
        self.clusterNames = clusterNames
        self.segmentNames = segmentNames
    }

    public static let empty = MeetingSpeakerAssignments()
}

public enum MeetingSpeakerNaming {
    /// Names voice clusters from speaker cues (a verified meeting-app adapter) by majority vote.
    ///
    /// For each cluster, cue time overlapping its turns is summed per display name. The winner
    /// must hold more than `minimumShare` of that cluster's cue-covered time and at least
    /// `minimumSeconds` of evidence; otherwise the cluster stays unnamed. One confident stretch
    /// of "Alex is speaking" can thus name every line of Alex's voice, while a cluster whose
    /// evidence is split between two names stays unnamed. User names are applied separately
    /// and always win (see `MeetingSpeakerResolver`).
    public static func clusterNames(
        diarization: MeetingDiarization, cues: [MeetingSpeakerCue],
        minimumShare: Double = 0.5, minimumSeconds: TimeInterval = 1
    ) -> [String: String] {
        var votes: [String: [String: TimeInterval]] = [:]
        for turn in diarization.turns {
            for cue in cues {
                let name = cue.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let seconds = MeetingDiarization.overlap(turn.range, cue.range)
                if seconds > 0 { votes[turn.clusterID, default: [:]][name, default: 0] += seconds }
            }
        }
        var names: [String: String] = [:]
        for (cluster, tally) in votes {
            let total = tally.values.reduce(0, +)
            guard let best = tally.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                best.value >= minimumSeconds, best.value > total * minimumShare
            else { continue }
            names[cluster] = best.key
        }
        return names
    }
}

/// Maps between the session clock and one stitched audio buffer made of system-audio chunks
/// with short silences between them (diarizers want one continuous signal; the session clock
/// has long gaps while nobody else speaks).
public struct MeetingStitchMap: Equatable, Sendable {
    public struct Piece: Equatable, Sendable {
        public let stitchedStart: TimeInterval
        public let sessionStart: TimeInterval
        public let duration: TimeInterval
    }

    public private(set) var pieces: [Piece] = []
    public private(set) var stitchedDuration: TimeInterval = 0

    public init() {}

    /// Appends a chunk of `duration` seconds that starts at `sessionStart`, then `gap` seconds of silence.
    public mutating func append(sessionStart: TimeInterval, duration: TimeInterval, gap: TimeInterval) {
        guard duration > 0 else { return }
        pieces.append(Piece(stitchedStart: stitchedDuration, sessionStart: sessionStart, duration: duration))
        stitchedDuration += duration + max(0, gap)
    }

    /// Session ranges covered by a stitched interval. Silence between pieces maps to nothing,
    /// so a diarized turn that spans a gap becomes one range per chunk.
    public func sessionRanges(stitchedStart: TimeInterval, stitchedEnd: TimeInterval) -> [MeetingTimeRange] {
        guard stitchedEnd > stitchedStart else { return [] }
        return pieces.compactMap { piece in
            let start = max(stitchedStart, piece.stitchedStart)
            let end = min(stitchedEnd, piece.stitchedStart + piece.duration)
            guard end > start else { return nil }
            return try? MeetingTimeRange(
                start: piece.sessionStart + (start - piece.stitchedStart),
                end: piece.sessionStart + (end - piece.stitchedStart))
        }
    }
}
