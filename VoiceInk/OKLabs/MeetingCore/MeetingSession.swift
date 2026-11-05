import Foundation

public enum MeetingAudioSource: String, Codable, Sendable {
    case microphone
    case system
}

public enum MeetingSessionError: Error, Equatable {
    case invalidTime
    case invalidTransition
    case outsideRecording
    case finalSegmentCannotChange
    case audioSourceCannotChange
    case unsupportedCheckpoint
    case invalidSpeakerCue
}

/// Seconds on one monotonic session clock, including time spent paused.
public struct MeetingTimeRange: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else {
            throw MeetingSessionError.invalidTime
        }
        self.start = start
        self.end = end
    }

    func contains(_ other: MeetingTimeRange) -> Bool {
        start <= other.start && end >= other.end
    }
}

/// Raw ASR text. Enhancement output must never replace this text.
public struct MeetingTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let source: MeetingAudioSource
    public let range: MeetingTimeRange
    public let text: String
    public let isFinal: Bool

    public init(
        id: UUID = UUID(), source: MeetingAudioSource, range: MeetingTimeRange,
        text: String, isFinal: Bool
    ) {
        self.id = id
        self.source = source
        self.range = range
        self.text = text
        self.isFinal = isFinal
    }
}

public enum MeetingSessionState: String, Codable, Sendable {
    case recording
    case paused
    case finished
}

/// Capture state is separate from ASR delivery: a result can arrive after pause/stop.
public struct MeetingSession: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public private(set) var state: MeetingSessionState
    public private(set) var segments: [MeetingTranscriptSegment]
    public private(set) var recordedRanges: [MeetingTimeRange]
    public private(set) var speakerCues: [MeetingSpeakerCue]
    private var openRangeStart: TimeInterval?
    private var lastControlTime: TimeInterval

    public init(id: UUID = UUID(), title: String, startedAt: Date = Date()) {
        self.schemaVersion = 1
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.state = .recording
        self.segments = []
        self.recordedRanges = []
        self.speakerCues = []
        self.openRangeStart = 0
        self.lastControlTime = 0
    }

    public mutating func pause(at time: TimeInterval) throws {
        guard state == .recording else { throw MeetingSessionError.invalidTransition }
        try validateControlTime(time)
        try closeRange(at: time)
        state = .paused
        lastControlTime = time
    }

    public mutating func resume(at time: TimeInterval) throws {
        guard state == .paused else { throw MeetingSessionError.invalidTransition }
        try validateControlTime(time)
        openRangeStart = time
        state = .recording
        lastControlTime = time
    }

    public mutating func finish(at time: TimeInterval) throws {
        guard state != .finished else { throw MeetingSessionError.invalidTransition }
        try validateControlTime(time)
        if state == .recording { try closeRange(at: time) }
        state = .finished
        lastControlTime = time
    }

    /// A provider must reuse the segment ID when replacing a partial with its final text.
    public mutating func upsert(_ segment: MeetingTranscriptSegment) throws {
        try validateRange(segment.range)
        guard isRecorded(segment.range) else { throw MeetingSessionError.outsideRecording }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            let previous = segments[index]
            guard previous.source == segment.source else { throw MeetingSessionError.audioSourceCannotChange }
            guard !previous.isFinal || previous == segment else {
                throw MeetingSessionError.finalSegmentCannotChange
            }
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        segments.sort(by: Self.precedes)
    }

    public var finalSegments: [MeetingTranscriptSegment] {
        segments.filter(\.isFinal).sorted(by: Self.precedes)
    }

    /// Lower bound for closing an interrupted capture without reusing a process's host clock.
    public var latestActivityTime: TimeInterval {
        max(lastControlTime, segments.map(\.range.end).max() ?? 0)
    }

    public mutating func recordSpeakerCue(_ cue: MeetingSpeakerCue) throws {
        try validateSpeakerCue(cue)
        speakerCues.append(cue)
    }

    /// Validate decoded checkpoints before using them for recovery.
    public func validate() throws {
        guard schemaVersion == 1 else { throw MeetingSessionError.unsupportedCheckpoint }
        guard lastControlTime.isFinite, lastControlTime >= 0 else { throw MeetingSessionError.invalidTime }
        guard (state == .recording) == (openRangeStart != nil) else {
            throw MeetingSessionError.invalidTransition
        }
        if let openRangeStart {
            guard openRangeStart == lastControlTime else { throw MeetingSessionError.invalidTime }
        }
        var end: TimeInterval = 0
        for range in recordedRanges {
            try validateRange(range)
            guard range.start >= end, range.end <= lastControlTime else {
                throw MeetingSessionError.invalidTime
            }
            end = range.end
        }
        guard Set(segments.map(\.id)).count == segments.count else {
            throw MeetingSessionError.unsupportedCheckpoint
        }
        for segment in segments {
            try validateRange(segment.range)
            guard isRecorded(segment.range) else { throw MeetingSessionError.outsideRecording }
        }
        for cue in speakerCues { try validateSpeakerCue(cue) }
    }

    private func validateControlTime(_ time: TimeInterval) throws {
        guard time.isFinite, time >= lastControlTime else { throw MeetingSessionError.invalidTime }
        // A control event must not close capture before audio already accepted from it.
        if let openRangeStart {
            let latest = segments.filter { $0.range.start >= openRangeStart }.map(\.range.end).max() ?? openRangeStart
            guard time >= latest else { throw MeetingSessionError.invalidTime }
        }
    }

    private func validateRange(_ range: MeetingTimeRange) throws {
        _ = try MeetingTimeRange(start: range.start, end: range.end)
    }

    private func validateSpeakerCue(_ cue: MeetingSpeakerCue) throws {
        try validateRange(cue.range)
        guard !cue.participantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !cue.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MeetingSessionError.invalidSpeakerCue }
    }

    private func isRecorded(_ range: MeetingTimeRange) -> Bool {
        recordedRanges.contains { $0.contains(range) }
            || openRangeStart.map { range.start >= $0 } == true
    }

    private mutating func closeRange(at time: TimeInterval) throws {
        guard let start = openRangeStart else { throw MeetingSessionError.invalidTransition }
        recordedRanges.append(try MeetingTimeRange(start: start, end: time))
        openRangeStart = nil
    }

    private static func precedes(_ lhs: MeetingTranscriptSegment, _ rhs: MeetingTranscriptSegment) -> Bool {
        lhs.range.start == rhs.range.start
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.range.start < rhs.range.start
    }
}
