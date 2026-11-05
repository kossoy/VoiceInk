import Foundation
import XCTest

@testable import MeetingCore

final class MeetingCoreTests: XCTestCase {
    private func range(_ start: Double, _ end: Double) throws -> MeetingTimeRange {
        try MeetingTimeRange(start: start, end: end)
    }

    private func segment(
        _ start: Double, _ end: Double, _ text: String = "raw text",
        source: MeetingAudioSource = .system, id: UUID = UUID(), final: Bool = true
    ) throws -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id, source: source, range: try range(start, end), text: text, isFinal: final)
    }

    private func cue(_ start: Double, _ end: Double, _ person: String) throws -> MeetingSpeakerCue {
        MeetingSpeakerCue(participantID: person, displayName: person, range: try range(start, end))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLateResultsFromBothChannelsAreOrderedByAudioTime() throws {
        var session = MeetingSession(title: "Test")
        try session.upsert(segment(8, 10, "remote"))
        try session.upsert(segment(2, 4, "local", source: .microphone))
        XCTAssertEqual(session.finalSegments.map(\.text), ["local", "remote"])
        XCTAssertTrue(MeetingTranscriptExport.text(session).hasPrefix("[00:00:02.000] Me: local"))
    }

    func testFinalReplacesPartialWithoutDuplicatesOrEditingRawWords() throws {
        var session = MeetingSession(title: "Test")
        let id = UUID()
        try session.upsert(segment(0, 1, "partial", id: id, final: false))
        XCTAssertTrue(MeetingTranscriptExport.text(session).isEmpty)
        let final = try segment(0, 2, "Э-э, [API] — да.\nSecond line.", id: id)
        try session.upsert(final)
        try session.upsert(final) // Replayed final events are idempotent.
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.finalSegments.first?.text, final.text)
        XCTAssertTrue(MeetingTranscriptExport.text(session).contains(final.text))
        XCTAssertThrowsError(try session.upsert(segment(0, 2, "rewritten", id: id))) {
            XCTAssertEqual($0 as? MeetingSessionError, .finalSegmentCannotChange)
        }
        XCTAssertThrowsError(try session.upsert(segment(0, 2, source: .microphone, id: id))) {
            XCTAssertEqual($0 as? MeetingSessionError, .audioSourceCannotChange)
        }
    }

    func testPauseKeepsClockGapAndAcceptsAnEarlierASRResult() throws {
        var session = MeetingSession(title: "Test")
        try session.pause(at: 10)
        try session.upsert(segment(8, 10, "arrived after pause"))
        XCTAssertThrowsError(try session.upsert(segment(9, 11, "crosses pause")))
        XCTAssertThrowsError(try session.upsert(segment(12, 13, "not recorded")))
        try session.resume(at: 30)
        try session.upsert(segment(30, 31, "after resume"))
        try session.finish(at: 35)
        try session.upsert(segment(33, 35, "last result after stop"))
        XCTAssertThrowsError(try session.upsert(segment(35, 36, "past stop")))
        XCTAssertTrue(MeetingTranscriptExport.text(session).contains("[00:00:30.000]"))
        XCTAssertEqual(session.recordedRanges, [try range(0, 10), try range(30, 35)])
        XCTAssertEqual(session.state, .finished)
    }

    func testInvalidTransitionsAndTimesDoNotChangeCaptureState() throws {
        var session = MeetingSession(title: "Test")
        XCTAssertThrowsError(try session.resume(at: 0))
        try session.upsert(segment(0, 5))
        XCTAssertThrowsError(try session.pause(at: 4))
        XCTAssertEqual(session.state, .recording)
        try session.pause(at: 5)
        XCTAssertThrowsError(try session.resume(at: 4))
        XCTAssertThrowsError(try session.resume(at: .infinity))
        XCTAssertEqual(session.state, .paused)
        try session.finish(at: 8)
        XCTAssertThrowsError(try session.resume(at: 9))
        XCTAssertThrowsError(try session.finish(at: 9))
        for (start, end) in [(-1.0, 0.0), (2, 1), (0, Double.nan), (0, .infinity)] {
            XCTAssertThrowsError(try range(start, end))
        }
    }

    func testSpeakerNamesRequireCompleteUnambiguousEvidence() throws {
        let utterance = try segment(2, 6)
        XCTAssertNil(MeetingSpeakerResolver.name(for: utterance, cues: []))
        XCTAssertNil(MeetingSpeakerResolver.name(for: utterance, cues: [try cue(0, 4, "Alex")]))
        XCTAssertNil(MeetingSpeakerResolver.name(
            for: utterance, cues: [try cue(0, 3, "Alex"), try cue(4, 8, "Alex")]))
        XCTAssertNil(MeetingSpeakerResolver.name(
            for: utterance, cues: [try cue(0, 8, "Alex"), try cue(3, 4, "Sam")]))
        XCTAssertEqual(MeetingSpeakerResolver.name(
            for: utterance, cues: [try cue(0, 3, "Alex"), try cue(3, 8, "Alex")]), "Alex")
        XCTAssertEqual(MeetingSpeakerResolver.name(
            for: try segment(5, 8), cues: [try cue(0, 5, "Alex"), try cue(5, 9, "Sam")]), "Sam")
    }

    func testRemoteSpeakerEvidenceNeverRelabelsTheMicrophone() throws {
        let utterance = try segment(2, 6, source: .microphone)
        let cues = [try cue(0, 8, "Alex")]
        XCTAssertNil(MeetingSpeakerResolver.name(for: utterance, cues: cues))
        XCTAssertEqual(MeetingSpeakerResolver.label(for: utterance, cues: cues), "Me")
    }

    func testCheckpointPreservesPausedSessionPartialAndSpeakerCues() throws {
        let root = try temporaryDirectory()
        let store = MeetingTranscriptStore(root: root)
        var session = MeetingSession(title: "RU / EN session", startedAt: Date())
        try session.upsert(segment(0, 2, "Привет / hello"))
        let partialID = UUID()
        try session.upsert(segment(2, 3, "unfinished hypothesis", id: partialID, final: false))
        try session.recordSpeakerCue(cue(0, 2, "Alex"))
        try session.pause(at: 4)
        let directory = try store.save(session)
        var restored = try store.load(id: session.id)
        XCTAssertEqual(restored, session)
        let text = try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Alex: Привет / hello"))
        XCTAssertFalse(text.contains("unfinished hypothesis"))
        try restored.upsert(segment(2, 3, "final words", id: partialID))
        try restored.resume(at: 70)
        try restored.upsert(segment(70, 71, "resumed", source: .microphone))
        try restored.finish(at: 72)
        try store.save(restored)
        XCTAssertEqual(try store.load(id: session.id), restored)
    }

    func testJSONExportContainsOnlyFinalRawTextAndSourceMetadata() throws {
        var session = MeetingSession(title: "Test")
        try session.upsert(segment(3, 4, "draft", final: false))
        try session.upsert(segment(1, 2, "literal [text]", source: .microphone))
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MeetingTranscriptExport.json(session)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["text"] as? String, "literal [text]")
        XCTAssertEqual(rows[0]["source"] as? String, "microphone")
        XCTAssertEqual(rows[0]["speaker"] as? String, "Me")
        XCTAssertEqual(rows[0]["start"] as? Double, 1)
        XCTAssertEqual(rows[0]["end"] as? Double, 2)
    }

    func testLongMeetingTimestampsDoNotWrapAfterAnHour() throws {
        var session = MeetingSession(title: "Test")
        try session.upsert(segment(3_661.125, 3_662, "later"))
        XCTAssertTrue(MeetingTranscriptExport.text(session).contains("[01:01:01.125]"))
    }

    func testUnsupportedOrCorruptCheckpointIsRejected() throws {
        let store = MeetingTranscriptStore(root: try temporaryDirectory())
        var session = MeetingSession(title: "Test")
        try session.upsert(segment(0, 2))
        let directory = try store.save(session)
        let url = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.load(id: session.id)) {
            XCTAssertEqual($0 as? MeetingSessionError, .unsupportedCheckpoint)
        }
        object["schemaVersion"] = 1
        object["openRangeStart"] = -1
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.load(id: session.id))
    }
}
