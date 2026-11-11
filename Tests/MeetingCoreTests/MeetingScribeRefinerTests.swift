import Foundation
import XCTest

@testable import MeetingCore

/// The optional ElevenLabs Scribe v3 pass refines the local (FluidAudio) clusters; synthetic data only.
final class MeetingScribeRefinerTests: XCTestCase {
    private func range(_ start: Double, _ end: Double) throws -> MeetingTimeRange {
        try MeetingTimeRange(start: start, end: end)
    }

    private func segment(_ start: Double, _ end: Double, _ text: String, id: UUID = UUID()) throws
        -> MeetingTranscriptSegment
    {
        MeetingTranscriptSegment(id: id, source: .system, range: try range(start, end), text: text, isFinal: true)
    }

    private func local(_ turns: [(String, Double, Double)]) throws -> MeetingDiarization {
        MeetingDiarization(
            engine: "test", createdAt: Date(timeIntervalSince1970: 0), audioSeconds: 60, processingSeconds: 1,
            turns: try turns.map { MeetingSpeakerTurn(clusterID: $0.0, range: try range($0.1, $0.2)) })
    }

    /// Words spread evenly over `start..<end`, all from `speaker`.
    private func words(_ speaker: String, _ text: String, _ start: Double, _ end: Double) throws -> [MeetingSpeakerWord] {
        let tokens = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(tokens.count)
        return try tokens.enumerated().map { i, t in
            MeetingSpeakerWord(
                speakerID: speaker, range: try range(start + Double(i) * step, start + Double(i + 1) * step - 0.01), text: t)
        }
    }

    private func scribe(_ words: [MeetingSpeakerWord]) -> MeetingScribeDiarization {
        MeetingScribeDiarization(
            createdAt: Date(timeIntervalSince1970: 0), audioSecondsSent: 60, processingSeconds: 2, words: words)
    }

    /// Local: A speaks 0-20, B 20-40. The cloud calls them speaker_1 and speaker_0.
    private func baseline() throws -> (MeetingDiarization, [MeetingSpeakerWord]) {
        let localResult = try local([("A", 0, 20), ("B", 20, 40)])
        let cloud = try words("speaker_1", "one two three four five six seven eight", 0, 18)
            + words("speaker_0", "nine ten eleven twelve thirteen fourteen", 21, 39)
        return (localResult, cloud)
    }

    // MARK: - Mapping

    func testCloudSpeakersMapOntoLocalClustersByOverlap() throws {
        let (localResult, cloud) = try baseline()
        XCTAssertEqual(scribe(cloud).speakerMap(to: localResult), ["speaker_1": "A", "speaker_0": "B"])
    }

    func testSpeakerSplitAcrossLocalClustersStaysUnmapped() throws {
        let localResult = try local([("A", 0, 10), ("B", 10, 20)])
        let cloud = try words("speaker_0", "a b c d e f g h i j", 0, 20)  // half in A, half in B
        XCTAssertEqual(scribe(cloud).speakerMap(to: localResult), [:])
    }

    // MARK: - Unassigned lines

    func testLineTheLocalPassLeftUnassignedGetsTheCloudVoice() throws {
        // Local covers only 0-2 of a 0-12 line (< 25 %), so locally it has no voice.
        let localResult = try local([("A", 0, 2), ("A", 30, 50), ("B", 60, 80)])
        let cloud = try words("speaker_0", "warm up words", 31, 49)
            + words("speaker_0", "yes okay sure thing", 1, 11)
        var session = MeetingSession(title: "T")
        let line = try segment(0, 12, "yes okay sure thing")
        try session.upsert(line)
        XCTAssertNil(MeetingSpeakerLabeler(session: session, diarization: localResult).clusterID(for: line))
        let refined = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertEqual(refined.clusterID(for: line), "A")
        XCTAssertEqual(refined.label(for: line), "Speaker 1")
    }

    func testLocalClusterStaysAuthoritative() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40)])
        // The cloud thinks 2-10 is the voice it otherwise hears in B's time.
        let cloud = try words("speaker_0", "x y z w", 2, 10) + words("speaker_0", "p q r s t u", 21, 39)
        var session = MeetingSession(title: "T")
        let line = try segment(2, 10, "x y z w")
        try session.upsert(line)
        let refined = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertEqual(refined.clusterID(for: line), "A")
    }

    // MARK: - Splitting

    func testLineWithTwoSubstantialVoicesSplitsByWordKeepingItsOwnText() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40), ("A", 40, 50), ("B", 50, 60)])
        let cloud = try words("speaker_1", "first part of it", 40, 45) + words("speaker_0", "then the reply here", 45, 50)
            + words("speaker_1", "filler words to map a", 0, 18) + words("speaker_0", "filler words to map b", 21, 39)
        var session = MeetingSession(title: "T")
        let line = try segment(40, 50, "First part of it, then the reply here.")
        try session.upsert(line)
        let labeler = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        let parts = try XCTUnwrap(labeler.parts(for: line))
        XCTAssertEqual(parts.map(\.text), ["First part of it,", "then the reply here."])
        XCTAssertEqual(parts.map(\.clusterID), ["A", "B"])
        XCTAssertEqual(parts.map { labeler.label(for: $0) }, ["Speaker 1", "Speaker 2"])

        let text = MeetingTranscriptExport.text(session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertEqual(text, "[00:00:40.000] Speaker 1: First part of it,\n[00:00:40.000] Speaker 2: then the reply here.")
    }

    func testStrayWordOrThinSecondVoiceDoesNotSplit() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40)])
        let cloud = try words("speaker_1", "one two three four five six seven", 0, 7)
            + words("speaker_0", "eight", 7, 8)
            + words("speaker_0", "map b words here now", 21, 39)
        var session = MeetingSession(title: "T")
        let line = try segment(0, 8, "one two three four five six seven eight")
        try session.upsert(line)
        let labeler = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertNil(labeler.parts(for: line))
        XCTAssertEqual(labeler.label(for: line), "Speaker 1")
    }

    func testDifferentWordingStillAlignsWhenMostWordsMatch() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40), ("A", 40, 50), ("B", 50, 60)])
        let cloud = try words("speaker_1", "we should ship it today", 40, 45)
            + words("speaker_0", "no wait until friday please", 45, 50)
            + words("speaker_1", "map a words here now", 0, 18) + words("speaker_0", "map b words here now", 21, 39)
        var session = MeetingSession(title: "T")
        // The line's own transcript differs in a few words ("we'd", "Friday,").
        let line = try segment(40, 50, "We'd should ship it today. No, wait until Friday, please")
        try session.upsert(line)
        let parts = try XCTUnwrap(MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
            .parts(for: line))
        XCTAssertEqual(parts.map(\.clusterID), ["A", "B"])
        XCTAssertEqual(parts.first?.text, "We'd should ship it today.")
    }

    // MARK: - Precedence

    func testUserNamesStayAuthoritative() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40), ("A", 40, 50), ("B", 50, 60)])
        let cloud = try words("speaker_1", "first part of it", 40, 45) + words("speaker_0", "then the reply here", 45, 50)
            + words("speaker_1", "filler words to map a", 0, 18) + words("speaker_0", "filler words to map b", 21, 39)
        var session = MeetingSession(title: "T")
        let line = try segment(40, 50, "First part of it, then the reply here.")
        try session.upsert(line)
        session.nameSpeakerCluster("B", as: "Dana")
        var labeler = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertEqual(try XCTUnwrap(labeler.parts(for: line)).map { labeler.label(for: $0) }, ["Speaker 1", "Dana"])

        // A name for this one line keeps it whole.
        try session.nameSegment(line.id, as: "Lee")
        labeler = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertNil(labeler.parts(for: line))
        XCTAssertEqual(labeler.label(for: line), "Lee")
    }

    func testMeetingAppCuesStillNameClustersByMajority() throws {
        let localResult = try local([("A", 0, 20), ("B", 20, 40), ("A", 40, 50), ("B", 50, 60)])
        let cloud = try words("speaker_1", "first part of it", 40, 45) + words("speaker_0", "then the reply here", 45, 50)
            + words("speaker_1", "filler words to map a", 0, 18) + words("speaker_0", "filler words to map b", 21, 39)
        var session = MeetingSession(title: "T")
        let line = try segment(40, 50, "First part of it, then the reply here.")
        try session.upsert(line)
        try session.recordSpeakerCue(MeetingSpeakerCue(participantID: "p1", displayName: "Alex", range: try range(2, 10)))
        let labeler = MeetingSpeakerLabeler(session: session, diarization: localResult, scribe: scribe(cloud))
        XCTAssertEqual(try XCTUnwrap(labeler.parts(for: line)).map { labeler.label(for: $0) }, ["Alex", "Speaker 2"])
    }

    func testWithoutLocalDiarizationTheCloudPassIsIgnored() throws {
        let (_, cloud) = try baseline()
        var session = MeetingSession(title: "T")
        let line = try segment(0, 18, "one two three four five six seven eight")
        try session.upsert(line)
        let labeler = MeetingSpeakerLabeler(session: session, diarization: nil, scribe: scribe(cloud))
        XCTAssertNil(labeler.refiner)
        XCTAssertEqual(labeler.label(for: line), "Others")
    }

    // MARK: - Storage

    func testScribePassIsStoredBesideTheSessionAndUsedByExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MeetingTranscriptStore(root: root)
        let localResult = try local([("A", 0, 20), ("B", 20, 40), ("A", 40, 50), ("B", 50, 60)])
        let cloud = scribe(
            try words("speaker_1", "first part of it", 40, 45) + words("speaker_0", "then the reply here", 45, 50)
                + words("speaker_1", "filler words to map a", 0, 18) + words("speaker_0", "filler words to map b", 21, 39))
        var session = MeetingSession(title: "T")
        try session.upsert(try segment(40, 50, "First part of it, then the reply here."))
        _ = try store.save(session)
        XCTAssertNil(try store.loadScribeDiarization(id: session.id))
        try store.saveDiarization(localResult, for: session)
        try store.saveScribeDiarization(cloud, for: session)
        XCTAssertEqual(try store.loadScribeDiarization(id: session.id), cloud)
        let directory = store.directory(for: session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("diarization-scribe.json").path))
        let exported = try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(exported.contains("Speaker 2: then the reply here."), exported)
        let json = try String(contentsOf: directory.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"parts\""), json)
        XCTAssertEqual(cloud.turns.count, 4)
    }

    func testUnknownSchemaIsRejected() throws {
        let data = Data(
            #"{"schemaVersion":9,"engine":"x","createdAt":0,"audioSecondsSent":1,"processingSeconds":1,"requests":1,"words":[]}"#
                .utf8)
        let decoded = try JSONDecoder().decode(MeetingScribeDiarization.self, from: data)
        XCTAssertThrowsError(try decoded.validate())
    }
}
