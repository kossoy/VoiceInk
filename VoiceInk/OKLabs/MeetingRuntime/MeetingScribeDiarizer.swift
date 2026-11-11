import Foundation
import os

/// Optional cloud pass after the local diarization: uploads a meeting's stitched system-audio
/// track once to ElevenLabs Scribe v3 with `diarize=true` and returns its words with speaker
/// labels on the session clock. `MeetingSpeakerLabeler` uses them to label lines the local pass
/// left unassigned and to split a line between two voices; the local clusters stay authoritative.
///
/// The audio already goes to ElevenLabs for transcription in Scribe meetings; this pass sends the
/// system track a second time (billed as Scribe v3 batch audio). Nothing else leaves the Mac.
actor MeetingScribeDiarizer {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OKLabsMeetingScribe")

    enum Failure: LocalizedError {
        case missingAPIKey
        case notEnoughAudio(TimeInterval)
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No ElevenLabs API key."
            case .notEnoughAudio(let seconds):
                return String(format: "Only %.1f s of audio from other apps; nothing to send.", seconds)
            }
        }
    }

    /// Whether an ElevenLabs key is configured (the setting defaults to on only then).
    static var hasAPIKey: Bool {
        !(APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs") ?? "").isEmpty
    }

    func diarize(_ chunks: [MeetingDiarizer.Chunk]) async throws -> MeetingScribeDiarization {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
            throw Failure.missingAPIKey
        }
        let started = Date()
        let stitched = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-scribe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stitched) }
        let map = try MeetingDiarizer.stitch(chunks, into: stitched)
        let speech = map.pieces.reduce(0) { $0 + $1.duration }
        guard speech >= MeetingDiarizer.minimumAudioSeconds else { throw Failure.notEnoughAudio(speech) }
        let sent = map.stitchedDuration
        logger.notice(
            "Scribe diarization: sending \(sent / 60, format: .fixed(precision: 1), privacy: .public) min (\(map.pieces.count, privacy: .public) chunks, \(speech / 60, format: .fixed(precision: 1), privacy: .public) min speech) to scribe_v3"
        )
        let words = try await ScribeDiarizationRequest(apiKey: apiKey).run(audio: stitched)
        var mapped: [MeetingSpeakerWord] = []
        for word in words {
            // A word never spans two chunks in practice; take the part in the first one.
            guard let range = map.sessionRanges(stitchedStart: word.start, stitchedEnd: max(word.end, word.start + 0.01))
                .first
            else { continue }
            mapped.append(MeetingSpeakerWord(speakerID: word.speakerID, range: range, text: word.text))
        }
        let elapsed = Date().timeIntervalSince(started)
        logger.notice(
            "Scribe diarization: \(mapped.count, privacy: .public) words, \(Set(mapped.map(\.speakerID)).count, privacy: .public) speakers in \(elapsed, format: .fixed(precision: 1), privacy: .public) s; billed audio \(sent / 60, format: .fixed(precision: 1), privacy: .public) min"
        )
        return MeetingScribeDiarization(
            audioSecondsSent: sent, processingSeconds: elapsed, requests: 1, words: mapped)
    }
}
