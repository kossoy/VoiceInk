import XCTest
@testable import MeetingSystem
#if SWIFT_PACKAGE
import MeetingCore
#endif

// Fixtures come from a live Teams 2 call captured with `.oklabs/meeting-probe` on 2026-11-11
// (3+ participants). Real names are replaced ("Doe, Jane", "Roe, Sam", "Morgan", "Kay, Lee");
// every other word of the labels is verbatim.
final class TeamsSpeakerObserverTests: XCTestCase {
    // Main call window tiles (AXMenuItem, first AXDescription), verbatim apart from names.
    static let tileVideoOn = "Doe, Jane, video is on, Has control of production tools, Context menu is available"
    static let tileMuted = "Roe, Sam, Has control of production tools, muted, Context menu is available"
    static let tileUnmuted = "Kay, Lee, Has control of production tools, Context menu is available"
    static let tileSelf = "Myself video, Kossoy, Oleg, Has control of production tools, Muted, Has context menu"
    static let compactTitle = "Meeting compact view | Weekly sync"

    func testSpeakingLabels() {
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Doe, Jane is speaking"), "Doe, Jane")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Morgan is speaking"), "Morgan")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Alex Smith (Guest) is speaking"), "Alex Smith")
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "is speaking"))
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: Self.tileMuted))
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "Unmute mic"))
    }

    func testTileLabels() {
        XCTAssertEqual(TeamsSpeakerParser.tileName(fromLabel: Self.tileVideoOn), "Doe, Jane")
        XCTAssertEqual(TeamsSpeakerParser.tileName(fromLabel: Self.tileMuted), "Roe, Sam")
        XCTAssertEqual(TeamsSpeakerParser.tileName(fromLabel: Self.tileUnmuted), "Kay, Lee")
        XCTAssertNil(TeamsSpeakerParser.tileName(fromLabel: Self.tileSelf))
        XCTAssertNil(TeamsSpeakerParser.tileName(fromLabel: "Meeting controls"))
        XCTAssertNil(TeamsSpeakerParser.tileName(fromLabel: "Chat"))
        XCTAssertTrue(TeamsSpeakerParser.tileIsMuted(Self.tileMuted))
        XCTAssertFalse(TeamsSpeakerParser.tileIsMuted(Self.tileVideoOn))
    }

    func testNameNormalisation() {
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Alex Smith (Unverified), Meeting guest, Unmuted"), "Alex Smith")
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Doe, Jane"), "Doe, Jane")
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Alex\u{00A0}Smith  (Sales)"), "Alex Smith (Sales)")
        XCTAssertEqual(TeamsSpeakerParser.participantID(for: "Doe,  JANE"), "teams:doe, jane")
        XCTAssertNil(TeamsSpeakerParser.rosterName(fromLabel: "In this meeting (3)"))
    }

    func testCompactViewSnapshot() {
        let nodes = [
            TeamsAXNode(role: "AXWindow", labels: [Self.compactTitle], windowTitle: Self.compactTitle),
            TeamsAXNode(role: "AXGroup", labels: ["Doe, Jane is speaking"], windowTitle: Self.compactTitle),
            TeamsAXNode(role: "AXMenuItem", labels: [Self.tileMuted], windowTitle: "Weekly sync"),
            TeamsAXNode(role: "AXMenuItem", labels: [Self.tileVideoOn], windowTitle: "Weekly sync"),
            TeamsAXNode(role: "AXMenuItem", labels: [Self.tileSelf], windowTitle: "Weekly sync"),
        ]
        let snapshot = TeamsSpeakerSnapshot.from(nodes: nodes)
        XCTAssertEqual(snapshot.speaking, ["Doe, Jane"])
        XCTAssertTrue(snapshot.compactView)
        XCTAssertEqual(snapshot.unmuted, ["Doe, Jane"])
    }

    func testMainWindowFrameNeedsOwningTile() {
        // As captured: the frame group has no tile ancestor, so it names nobody.
        let loose = TeamsAXNode(role: "AXGroup", subrole: "AXEmptyGroup", domClasses: ["fui-Flex", "vdi-frame-occlusion"])
        XCTAssertEqual(TeamsSpeakerSnapshot.from(nodes: [loose]).speaking, [])
        let owned = TeamsAXNode(role: "AXGroup", domClasses: ["vdi-frame-occlusion"], tileLabel: Self.tileMuted)
        XCTAssertEqual(TeamsSpeakerSnapshot.from(nodes: [owned]).speaking, ["Roe, Sam"])
        let ownTile = TeamsAXNode(role: "AXGroup", domClasses: ["vdi-frame-occlusion"], tileLabel: Self.tileSelf)
        XCTAssertEqual(TeamsSpeakerSnapshot.from(nodes: [ownTile]).speaking, [])
    }

    func testTrackerHoldsAcrossFlickerAndClosesAfterHold() {
        var tracker = TeamsSpeakerTracker(hold: 2.5)
        func snap(_ names: Set<String>, _ fp: Int) -> TeamsSpeakerSnapshot { .init(speaking: names, fingerprint: fp) }
        XCTAssertEqual(tracker.observe(snap(["Doe, Jane"], 1), at: 10), [])
        XCTAssertEqual(tracker.observe(snap([], 2), at: 11), [])
        XCTAssertEqual(tracker.observe(snap(["Doe, Jane"], 3), at: 12), [])
        XCTAssertEqual(tracker.observe(snap(["Morgan"], 4), at: 13), [])
        let closed = tracker.observe(snap(["Morgan"], 5), at: 15)
        XCTAssertEqual(closed.map(\.displayName), ["Doe, Jane"])
        XCTAssertEqual(closed.first?.range, try MeetingTimeRange(start: 10, end: 12))
        let rest = tracker.finish(at: 16)
        XCTAssertEqual(rest.map(\.displayName), ["Morgan"])
        XCTAssertEqual(rest.first?.range, try MeetingTimeRange(start: 13, end: 16))
        XCTAssertEqual(rest.first?.participantID, "teams:morgan")
    }

    func testLongMonologueIsNotStaleByDefault() {
        var tracker = TeamsSpeakerTracker()
        let same = TeamsSpeakerSnapshot(speaking: ["Doe, Jane"], fingerprint: 7)
        for t in stride(from: 0.0, through: 60, by: 0.25) { XCTAssertEqual(tracker.observe(same, at: t), []) }
        XCTAssertEqual(tracker.finish(at: 61).first?.range, try MeetingTimeRange(start: 0, end: 61))
    }

    func testOptionalFrozenTreeDetectionAndMissingSnapshot() {
        var tracker = TeamsSpeakerTracker(hold: 2.5, staleAfter: 5)
        let frozen = TeamsSpeakerSnapshot(speaking: ["Doe, Jane"], fingerprint: 7)
        XCTAssertEqual(tracker.observe(frozen, at: 0), [])
        XCTAssertEqual(tracker.observe(frozen, at: 3), [])
        XCTAssertEqual(tracker.observe(frozen, at: 9).first?.range.end, 3)
        var gone = TeamsSpeakerTracker()
        _ = gone.observe(frozen, at: 0)
        XCTAssertEqual(gone.observe(nil, at: 0.25).map(\.displayName), ["Doe, Jane"])
    }

    /// Replays the speaking-set changes of the live capture (600 s watch, 4 Hz polls).
    func testLiveCaptureReplay() {
        let changes: [(TimeInterval, Set<String>)] = [
            (331.419, ["Morgan"]), (331.673, []), (331.935, ["Doe, Jane"]), (338.557, []),
            (587.884, ["Morgan"]), (588.131, ["Roe, Sam"]), (589.666, ["Morgan"]), (591.176, []),
            (591.433, ["Doe, Jane"]), (594.731, ["Morgan"]), (596.023, []),
        ]
        var tracker = TeamsSpeakerTracker()
        var cues: [MeetingSpeakerCue] = []
        var current: Set<String> = []
        var next = 0
        for tick in 0...2_400 {
            let t = Double(tick) * 0.25
            while next < changes.count, changes[next].0 <= t { current = changes[next].1; next += 1 }
            cues += tracker.observe(TeamsSpeakerSnapshot(speaking: current, fingerprint: tick), at: t)
        }
        cues += tracker.finish(at: 600)
        XCTAssertEqual(Set(cues.map(\.displayName)), ["Morgan", "Doe, Jane", "Roe, Sam"])
        let covered = cues.reduce(0) { $0 + $1.range.end - $1.range.start }
        XCTAssertGreaterThan(covered, 10)
        XCTAssertLessThan(covered, 20)  // ~2-3% of the call: the label exists only in compact view
        XCTAssertTrue(cues.allSatisfy { (331...597).contains($0.range.start) })
    }

    func testBundleMatchingAndCompactTitle() {
        XCTAssertTrue(TeamsSpeakerParser.isTeamsBundle("com.microsoft.teams2.modulehost"))
        XCTAssertFalse(TeamsSpeakerParser.isTeamsBundle("com.microsoft.teams20"))
        XCTAssertTrue(TeamsSpeakerParser.isCompactView(Self.compactTitle))
        XCTAssertFalse(TeamsSpeakerParser.isCompactView("Shared content | Weekly sync"))
    }

    /// Observer cues feed the merged diarization naming: one confident compact-view stretch
    /// names the whole voice cluster.
    func testCuesNameDiarizationClusters() throws {
        var tracker = TeamsSpeakerTracker()
        var cues: [MeetingSpeakerCue] = []
        for tick in 0...40 {
            let t = 100 + Double(tick) * 0.25          // "Doe, Jane is speaking" for 10 s
            cues += tracker.observe(TeamsSpeakerSnapshot(speaking: ["Doe, Jane"], fingerprint: tick), at: t)
        }
        cues += tracker.finish(at: 111)
        let diarization = MeetingDiarization(engine: "test", audioSeconds: 600, processingSeconds: 1, turns: [
            MeetingSpeakerTurn(clusterID: "A", range: try MeetingTimeRange(start: 20, end: 60)),
            MeetingSpeakerTurn(clusterID: "A", range: try MeetingTimeRange(start: 98, end: 112)),
            MeetingSpeakerTurn(clusterID: "B", range: try MeetingTimeRange(start: 200, end: 260)),
        ])
        XCTAssertEqual(MeetingSpeakerNaming.clusterNames(diarization: diarization, cues: cues), ["A": "Doe, Jane"])
    }
}
