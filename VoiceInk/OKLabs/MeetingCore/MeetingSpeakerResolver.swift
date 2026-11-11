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

/// Labels transcript lines from every source of speaker evidence. Build one per render or
/// export; it precomputes the cue majority vote over voice clusters.
///
/// Precedence for system audio ("Others"), strongest first:
/// 1. the user's name for this one line;
/// 2. the user's name for the line's voice cluster;
/// 3. complete, unambiguous meeting-app cues for the line (`MeetingSpeakerResolver.name`);
/// 4. the cue majority name of the line's voice cluster (`MeetingSpeakerNaming`);
/// 5. "Speaker N" for the line's voice cluster;
/// 6. "Others".
/// The microphone is always "Me".
public struct MeetingSpeakerLabeler {
    public let session: MeetingSession
    public let diarization: MeetingDiarization?
    private let cueClusterNames: [String: String]

    public init(session: MeetingSession, diarization: MeetingDiarization?) {
        self.session = session
        self.diarization = diarization
        cueClusterNames = diarization.map {
            MeetingSpeakerNaming.clusterNames(diarization: $0, cues: session.speakerCues)
        } ?? [:]
    }

    /// The voice cluster that dominates a system-audio line, if diarization ran.
    public func clusterID(for segment: MeetingTranscriptSegment) -> String? {
        guard segment.source == .system else { return nil }
        return diarization?.dominantCluster(for: segment.range)
    }

    /// The name a cluster shows without a per-line override.
    public func name(ofCluster clusterID: String) -> String? {
        session.speakerAssignments.clusterNames[clusterID]
            ?? cueClusterNames[clusterID]
            ?? diarization?.ordinalName(of: clusterID)
    }

    public func label(for segment: MeetingTranscriptSegment) -> String {
        guard segment.source == .system else { return "Me" }
        if let name = session.speakerAssignments.segmentNames[segment.id] { return name }
        let cluster = clusterID(for: segment)
        if let cluster, let name = session.speakerAssignments.clusterNames[cluster] { return name }
        if let name = MeetingSpeakerResolver.name(for: segment, cues: session.speakerCues) { return name }
        if let cluster, let name = cueClusterNames[cluster] ?? diarization?.ordinalName(of: cluster) { return name }
        return "Others"
    }

    /// Distinct names already in use, for a rename menu.
    public var knownNames: [String] {
        let names = Array(session.speakerAssignments.clusterNames.values)
            + Array(session.speakerAssignments.segmentNames.values)
            + Array(cueClusterNames.values) + session.speakerCues.map(\.displayName)
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
