import Foundation

/// Only a verified meeting-app adapter or an explicit user assignment may create name cues.
/// A participant list or an OCR name by itself is not evidence that the person is speaking.
public struct MeetingSpeakerCue: Codable, Equatable, Sendable {
    public let participantID: String
    public let displayName: String
    public let range: MeetingTimeRange

    public init(participantID: String, displayName: String, range: MeetingTimeRange) {
        self.participantID = participantID
        self.displayName = displayName
        self.range = range
    }
}

public enum MeetingSpeakerResolver {
    /// Missing, conflicting, or incomplete evidence leaves a segment unattributed.
    public static func name(
        for segment: MeetingTranscriptSegment, cues: [MeetingSpeakerCue]
    ) -> String? {
        guard segment.source == .system, segment.range.end > segment.range.start else { return nil }
        let relevant = cues.filter {
            $0.range.start < segment.range.end && $0.range.end > segment.range.start
        }
        guard let first = relevant.first,
            !first.participantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !first.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            relevant.allSatisfy({
                $0.participantID == first.participantID && $0.displayName == first.displayName
                    && $0.range.start.isFinite && $0.range.end.isFinite
            })
        else { return nil }

        var coveredUntil = segment.range.start
        for cue in relevant.sorted(by: { $0.range.start < $1.range.start }) {
            guard cue.range.start <= coveredUntil else { return nil }
            coveredUntil = max(coveredUntil, cue.range.end)
        }
        return coveredUntil >= segment.range.end ? first.displayName : nil
    }

    public static func label(
        for segment: MeetingTranscriptSegment, cues: [MeetingSpeakerCue]
    ) -> String {
        segment.source == .microphone ? "Me" : name(for: segment, cues: cues) ?? "Others"
    }
}
