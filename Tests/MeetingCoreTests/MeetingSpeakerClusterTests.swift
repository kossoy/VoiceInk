import Foundation
import XCTest

@testable import MeetingCore

final class MeetingSpeakerClusterTests: XCTestCase {
    private func range(_ start: Double, _ end: Double) throws -> MeetingTimeRange {
        try MeetingTimeRange(start: start, end: end)
    }

    private func segment(
        _ start: Double, _ end: Double, _ text: String = "raw text",
        source: MeetingAudioSource = .system, id: UUID = UUID()
    ) throws -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(id: id, source: source, range: try range(start, end), text: text, isFinal: true)
    }

    private func turn(_ cluster: String, _ start: Double, _ end: Double) throws -> MeetingSpeakerTurn {
        MeetingSpeakerTurn(clusterID: cluster, range: try range(start, end))
    }

    private func cue(_ start: Double, _ end: Double, _ person: String) throws -> MeetingSpeakerCue {
        MeetingSpeakerCue(participantID: person, displayName: person, range: try range(start, end))
    }

    private func diarization(_ turns: [MeetingSpeakerTurn]) -> MeetingDiarization {
        MeetingDiarization(
            engine: "test", createdAt: Date(timeIntervalSince1970: 0), audioSeconds: 60,
            processingSeconds: 1, turns: turns)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Dominant overlap

    func testSegmentTakesTheClusterThatCoversMostOfIt() throws {
        let d = diarization([try turn("S2", 0, 4), try turn("S1", 4, 12)])
        XCTAssertEqual(d.dominantCluster(for: try range(2, 10)), "S1")  // S1 6 s, S2 2 s
        XCTAssertEqual(d.dominantCluster(for: try range(0, 3)), "S2")
        XCTAssertEqual(d.clusterIDs, ["S2", "S1"])
        XCTAssertEqual(d.ordinalName(of: "S2"), "Speaker 1")
        XCTAssertEqual(d.ordinalName(of: "S1"), "Speaker 2")
    }

    func testThinOrMissingCoverageLeavesTheSegmentUnclustered() throws {
        let d = diarization([try turn("S1", 0, 1)])
        XCTAssertNil(d.dominantCluster(for: try range(0, 10)))  // 10 % < 25 %
        XCTAssertNil(d.dominantCluster(for: try range(20, 30)))
        XCTAssertEqual(d.dominantCluster(for: try range(0, 3)), "S1")  // 33 %
    }

    func testEqualOverlapBreaksTiesDeterministically() throws {
        let d = diarization([try turn("S1", 0, 2), try turn("S2", 2, 4)])
        let first = d.dominantCluster(for: try range(0, 4))
        for _ in 0..<5 { XCTAssertEqual(d.dominantCluster(for: try range(0, 4)), first) }
    }

    // MARK: - Majority vote from cues

    func testOneConfidentCueNamesEveryTurnOfThatVoice() throws {
        let d = diarization([
            try turn("S1", 0, 5), try turn("S2", 5, 9), try turn("S1", 20, 30), try turn("S2", 40, 44),
        ])
        let names = MeetingSpeakerNaming.clusterNames(
            diarization: d, cues: [try cue(0, 4, "Alex"), try cue(41, 44, "Sam")])
        XCTAssertEqual(names, ["S1": "Alex", "S2": "Sam"])

        var session = MeetingSession(title: "T")
        let late = try segment(21, 29)
        try session.upsert(late)
        try session.recordSpeakerCue(cue(0, 4, "Alex"))
        let labeler = MeetingSpeakerLabeler(session: session, diarization: d)
        XCTAssertEqual(labeler.label(for: late), "Alex")  // no cue at 21-29, named through its voice
    }

    func testSplitEvidenceLeavesTheClusterUnnamed() throws {
        let d = diarization([try turn("S1", 0, 10)])
        XCTAssertEqual(
            MeetingSpeakerNaming.clusterNames(diarization: d, cues: [try cue(0, 5, "Alex"), try cue(5, 10, "Sam")]),
            [:])
        XCTAssertEqual(
            MeetingSpeakerNaming.clusterNames(diarization: d, cues: [try cue(0, 6, "Alex"), try cue(6, 10, "Sam")]),
            ["S1": "Alex"])
        // Too little evidence.
        XCTAssertEqual(MeetingSpeakerNaming.clusterNames(diarization: d, cues: [try cue(0, 0.5, "Alex")]), [:])
    }

    // MARK: - Precedence

    func testUserNamesWinOverMeetingAppEvidence() throws {
        var session = MeetingSession(title: "T")
        let a = try segment(0, 4)
        let b = try segment(5, 9)
        let mine = try segment(10, 12, source: .microphone)
        for s in [a, b, mine] { try session.upsert(s) }
        try session.recordSpeakerCue(cue(0, 10, "Alex"))
        let d = diarization([try turn("S1", 0, 10)])

        XCTAssertEqual(MeetingSpeakerLabeler(session: session, diarization: d).label(for: a), "Alex")
        session.nameSpeakerCluster("S1", as: "Alexandra")
        var labeler = MeetingSpeakerLabeler(session: session, diarization: d)
        XCTAssertEqual(labeler.label(for: a), "Alexandra")
        XCTAssertEqual(labeler.label(for: b), "Alexandra")
        try session.nameSegment(b.id, as: "Sam")
        labeler = MeetingSpeakerLabeler(session: session, diarization: d)
        XCTAssertEqual(labeler.label(for: a), "Alexandra")
        XCTAssertEqual(labeler.label(for: b), "Sam")
        XCTAssertEqual(labeler.label(for: mine), "Me")
        XCTAssertEqual(labeler.knownNames, ["Alex", "Alexandra", "Sam"])

        // Clearing names falls back to evidence, then to the ordinal.
        try session.nameSegment(b.id, as: "  ")
        session.nameSpeakerCluster("S1", as: nil)
        XCTAssertEqual(MeetingSpeakerLabeler(session: session, diarization: d).label(for: b), "Alex")
        var noCues = MeetingSession(title: "T")
        try noCues.upsert(a)
        XCTAssertEqual(MeetingSpeakerLabeler(session: noCues, diarization: d).label(for: a), "Speaker 1")
        XCTAssertEqual(MeetingSpeakerLabeler(session: noCues, diarization: nil).label(for: a), "Others")
        XCTAssertThrowsError(try noCues.nameSegment(UUID(), as: "Nobody"))
    }

    // MARK: - Stitching

    func testStitchMapReturnsSessionTimeAndSkipsSilence() throws {
        var map = MeetingStitchMap()
        map.append(sessionStart: 100, duration: 4, gap: 0.5)
        map.append(sessionStart: 300, duration: 2, gap: 0.5)
        XCTAssertEqual(map.stitchedDuration, 7)
        XCTAssertEqual(map.sessionRanges(stitchedStart: 1, stitchedEnd: 3), [try range(101, 103)])
        // Spans the gap: one range per chunk, silence maps to nothing.
        XCTAssertEqual(
            map.sessionRanges(stitchedStart: 3, stitchedEnd: 5.5), [try range(103, 104), try range(300, 301)])
        XCTAssertEqual(map.sessionRanges(stitchedStart: 4.1, stitchedEnd: 4.4), [])
    }

    // MARK: - Persistence

    func testVersionOneCheckpointMigratesAndKeepsItsTranscript() throws {
        let root = try temporaryDirectory()
        let store = MeetingTranscriptStore(root: root)
        var session = MeetingSession(title: "Old")
        try session.upsert(segment(0, 2, "hello"))
        try session.finish(at: 3)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MeetingTranscriptExport.encoder().encode(session)) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "speakerAssignments")
        let directory = store.directory(for: session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("session.json"))

        var migrated = try store.load(id: session.id)
        XCTAssertEqual(migrated.schemaVersion, MeetingSession.currentSchemaVersion)
        XCTAssertEqual(migrated.speakerAssignments, .empty)
        XCTAssertEqual(migrated.finalSegments.map(\.text), ["hello"])
        migrated.nameSpeakerCluster("S1", as: "Alex")
        try store.save(migrated)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("session.json")))
                as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try store.load(id: session.id), migrated)

        object["schemaVersion"] = 3
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try store.load(id: session.id))
    }

    func testDiarizationIsStoredBesideTheSessionAndUsedByExports() throws {
        let store = MeetingTranscriptStore(root: try temporaryDirectory())
        var session = MeetingSession(title: "T")
        let line = try segment(0, 4, "status update")
        try session.upsert(line)
        try session.finish(at: 5)
        try store.save(session)
        XCTAssertNil(try store.loadDiarization(id: session.id))

        let d = diarization([try turn("S1", 0, 4)])
        try store.saveDiarization(d, for: session)
        XCTAssertEqual(try store.loadDiarization(id: session.id), d)
        let text = try String(
            contentsOf: store.directory(for: session.id).appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: status update"), text)

        session.nameSpeakerCluster("S1", as: "Alex")
        try store.save(session)
        let renamed = try String(
            contentsOf: store.directory(for: session.id).appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(renamed.contains("Alex**"), renamed)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MeetingTranscriptExport.json(session, diarization: d))
                as? [[String: Any]])
        XCTAssertEqual(rows.first?["speakerCluster"] as? String, "S1")
        XCTAssertEqual(rows.first?["speaker"] as? String, "Alex")

        // A damaged diarization.json never blocks saving the transcript.
        try Data("{".utf8).write(to: store.directory(for: session.id).appendingPathComponent("diarization.json"))
        XCTAssertNoThrow(try store.save(session))
        XCTAssertThrowsError(try store.loadDiarization(id: session.id))
    }
}
