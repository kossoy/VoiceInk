import XCTest
@testable import MeetingSystem
#if SWIFT_PACKAGE
import MeetingCore
#endif

// Fixtures come from a live Teams 2 call captured with `.oklabs/meeting-probe` on 2026-11-11
// (3+ participants). Real names are replaced ("Doe, Jane", "Roe, Sam", "Kay, Lee", "Poe, Pat");
// every other word of the labels is verbatim.
final class TeamsSpeakerObserverTests: XCTestCase {
    // Main call window tiles (AXMenuItem, first AXDescription), verbatim apart from names.
    static let tileVideoOn = "Doe, Jane, video is on, Has control of production tools, Context menu is available"
    static let tileMuted = "Roe, Sam, Has control of production tools, muted, Context menu is available"
    static let tileUnmuted = "Kay, Lee, Has control of production tools, Context menu is available"
    static let tileSelf = "Myself video, Poe, Pat, Has control of production tools, Muted, Has context menu"
    static let compactTitle = "Meeting compact view | Weekly sync"

    func testSpeakingLabels() {
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Doe, Jane is speaking"), "Doe, Jane")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Morgan is speaking"), "Morgan")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Alex Smith (Guest) is speaking"), "Alex Smith")
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "is speaking"))
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "Nobody is speaking"))  // compact view, silence
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
            (331.419, ["Nobody is speaking"]), (331.673, []), (331.935, ["Doe, Jane is speaking"]), (338.557, []),
            (587.884, ["Nobody is speaking"]), (588.131, ["Roe, Sam is speaking"]),
            (589.666, ["Nobody is speaking"]), (591.176, []), (591.433, ["Doe, Jane is speaking"]),
            (594.731, ["Nobody is speaking"]), (596.023, []),
        ]
        var tracker = TeamsSpeakerTracker()
        var cues: [MeetingSpeakerCue] = []
        var labels: Set<String> = []
        var next = 0
        for tick in 0...2_400 {
            let t = Double(tick) * 0.25
            while next < changes.count, changes[next].0 <= t { labels = changes[next].1; next += 1 }
            let nodes = labels.map {
                TeamsAXNode(role: "AXGroup", labels: [$0], windowTitle: Self.compactTitle)
            }
            let snapshot = TeamsSpeakerSnapshot.from(nodes: nodes)
            cues += tracker.observe(TeamsSpeakerSnapshot(speaking: snapshot.speaking, fingerprint: tick), at: t)
        }
        cues += tracker.finish(at: 600)
        XCTAssertEqual(Set(cues.map(\.displayName)), ["Doe, Jane", "Roe, Sam"])
        let covered = cues.reduce(0) { $0 + $1.range.end - $1.range.start }
        XCTAssertGreaterThan(covered, 8)
        XCTAssertLessThan(covered, 16)  // ~2% of the call: the label exists only in compact view
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

    // Second capture (main call window in front, 3 participants incl. the user), verbatim tile
    // templates with placeholder names.
    static let tileJane = "Doe, Jane, video is on, Has control of production tools, Context menu is available"
    static let tileSam = "Roe, Sam, video is on, Has control of production tools, Context menu is available"
    static let tileSelfUnmuted =
        "Myself video, Poe, Pat, Has control of production tools, Unmuted, video is on, Fit to frame, Has context menu"

    /// Main window as captured: the border is an AXEmptyGroup with vdi-frame-occlusion one
    /// level below the speaker's AXMenuItem tile.
    static func mainWindow(framed: Set<String>, selfFramed: Bool = false) -> [TeamsAXNode] {
        var nodes = [
            TeamsAXNode(role: "AXMenuItem", labels: [tileJane], domClasses: ["fui-Flex"], windowTitle: "Weekly sync", depth: 21),
            TeamsAXNode(role: "AXMenuItem", labels: [tileSam], domClasses: ["fui-Flex"], windowTitle: "Weekly sync", depth: 21),
            TeamsAXNode(role: "AXMenuItem", labels: [tileSelfUnmuted], domClasses: ["fui-Primitive"],
                        windowTitle: "Weekly sync", depth: 22),
        ]
        for (name, tile) in [("Doe, Jane", tileJane), ("Roe, Sam", tileSam)] where framed.contains(name) {
            nodes.append(TeamsAXNode(role: "AXGroup", subrole: "AXEmptyGroup", domClasses: ["fui-Flex", "vdi-frame-occlusion"],
                                     windowTitle: "Weekly sync", tileLabel: tile, depth: 22))
        }
        if selfFramed {
            nodes.append(TeamsAXNode(role: "AXGroup", subrole: "AXEmptyGroup", domClasses: ["vdi-frame-occlusion"],
                                     windowTitle: "Weekly sync", tileLabel: tileSelfUnmuted, depth: 23))
        }
        return nodes
    }

    func testMainWindowBorderIsTheSpeakerSignal() {
        let one = TeamsSpeakerSnapshot.from(nodes: Self.mainWindow(framed: ["Roe, Sam"]))
        XCTAssertEqual(one.speaking, ["Roe, Sam"])
        XCTAssertEqual(one.framed, ["Roe, Sam"])
        XCTAssertEqual(one.labelled, [])
        XCTAssertFalse(one.compactView)
        let both = TeamsSpeakerSnapshot.from(nodes: Self.mainWindow(framed: ["Doe, Jane", "Roe, Sam"]))
        XCTAssertEqual(both.speaking, ["Doe, Jane", "Roe, Sam"])
        let silence = TeamsSpeakerSnapshot.from(nodes: Self.mainWindow(framed: []))
        XCTAssertEqual(silence.speaking, [])
        XCTAssertEqual(silence.unmuted, ["Doe, Jane", "Roe, Sam"])  // unmuted is not speaking
        let me = TeamsSpeakerSnapshot.from(nodes: Self.mainWindow(framed: [], selfFramed: true))
        XCTAssertEqual(me.speaking, [])
        XCTAssertTrue(me.selfFramed)
        XCTAssertNil(TeamsSpeakerParser.tileName(fromLabel: Self.tileSelfUnmuted))
    }

    /// Replays the 73 border changes of the second capture (600.2 s, 4 Hz polls).
    func testMainWindowCaptureReplay() {
        let changes: [(TimeInterval, Set<String>)] = [
        (0.10, ["Doe, Jane"]), (4.88, ["Roe, Sam"]), (8.96, ["Doe, Jane", "Roe, Sam"]), (9.96, ["Roe, Sam"]),
        (115.03, ["Doe, Jane", "Roe, Sam"]), (116.82, ["Doe, Jane"]), (118.86, ["Roe, Sam"]),
        (122.94, ["Doe, Jane", "Roe, Sam"]), (125.98, ["Doe, Jane"]), (137.95, ["Doe, Jane", "Roe, Sam"]),
        (142.02, ["Doe, Jane"]), (143.05, ["Roe, Sam"]), (143.87, []), (144.05, ["Roe, Sam"]),
        (145.06, ["Doe, Jane", "Roe, Sam"]), (146.84, ["Doe, Jane"]), (148.87, ["Doe, Jane", "Roe, Sam"]),
        (152.92, ["Roe, Sam"]), (156.00, ["Doe, Jane", "Roe, Sam"]), (158.00, ["Roe, Sam"]),
        (166.91, ["Doe, Jane", "Roe, Sam"]), (168.94, ["Doe, Jane"]), (174.03, ["Doe, Jane", "Roe, Sam"]),
        (175.05, ["Roe, Sam"]), (180.90, []), (187.00, ["Roe, Sam"]), (198.96, ["Doe, Jane"]),
        (203.01, ["Doe, Jane", "Roe, Sam"]), (205.05, ["Roe, Sam"]), (215.98, []), (218.02, ["Roe, Sam"]),
        (228.98, ["Doe, Jane", "Roe, Sam"]), (231.00, ["Roe, Sam"]), (236.11, []), (238.90, ["Roe, Sam"]),
        (255.19, ["Doe, Jane", "Roe, Sam"]), (258.25, ["Roe, Sam"]), (274.26, []), (275.28, ["Roe, Sam"]),
        (294.12, ["Doe, Jane", "Roe, Sam"]), (298.20, ["Roe, Sam"]), (302.27, []), (303.29, ["Roe, Sam"]),
        (306.07, []), (308.12, ["Roe, Sam"]), (313.20, []), (314.22, ["Roe, Sam"]), (316.26, []),
        (320.09, ["Roe, Sam"]), (332.25, []), (333.27, ["Roe, Sam"]), (346.18, []), (346.32, ["Roe, Sam"]),
        (350.07, []), (353.13, ["Roe, Sam"]), (449.16, ["Doe, Jane", "Roe, Sam"]), (450.17, ["Roe, Sam"]),
        (501.18, ["Doe, Jane", "Roe, Sam"]), (503.22, ["Roe, Sam"]), (519.24, ["Doe, Jane", "Roe, Sam"]),
        (521.27, ["Roe, Sam"]), (527.38, ["Doe, Jane", "Roe, Sam"]), (528.38, ["Roe, Sam"]), (536.26, []),
        (538.29, ["Roe, Sam"]), (540.33, []), (541.36, ["Roe, Sam"]), (544.39, []), (545.41, ["Roe, Sam"]),
        (554.30, []), (555.32, ["Roe, Sam"]), (591.38, ["Doe, Jane", "Roe, Sam"]), (593.41, ["Roe, Sam"])
        ]
        var tracker = TeamsSpeakerTracker()
        var cues: [MeetingSpeakerCue] = []
        var framed: Set<String> = []
        var next = 0
        var namedPolls = 0
        let polls = 2_401
        for tick in 0..<polls {
            let t = Double(tick) * 0.25
            while next < changes.count, changes[next].0 <= t { framed = changes[next].1; next += 1 }
            let snapshot = TeamsSpeakerSnapshot.from(nodes: Self.mainWindow(framed: framed))
            if !snapshot.speaking.isEmpty { namedPolls += 1 }
            cues += tracker.observe(snapshot, at: t)
        }
        cues += tracker.finish(at: 600.25)
        XCTAssertEqual(Set(cues.map(\.displayName)), ["Doe, Jane", "Roe, Sam"])
        XCTAssertGreaterThan(Double(namedPolls) / Double(polls), 0.93)   // 95% of the call named
        var union: [(TimeInterval, TimeInterval)] = []
        for cue in cues.sorted(by: { $0.range.start < $1.range.start }) {
            if let last = union.last, cue.range.start <= last.1 {
                union[union.count - 1].1 = max(last.1, cue.range.end)
            } else {
                union.append((cue.range.start, cue.range.end))
            }
        }
        let covered = union.reduce(0) { $0 + $1.1 - $1.0 }
        XCTAssertGreaterThan(covered, 560)   // probe at 4c67596: 582.9 s cue union, 97%
        XCTAssertTrue((15...40).contains(cues.count), "\(cues.count) cues")
    }

    func testObserverIsOnByDefaultAndUserFalseWins() {
        let suite = "TeamsSpeakerObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TeamsSpeakerObserver.isEnabled(defaults))
        TeamsSpeakerObserver.registerDefault(in: defaults)
        XCTAssertTrue(TeamsSpeakerObserver.isEnabled(defaults))
        defaults.set(false, forKey: TeamsSpeakerObserver.enabledKey)
        XCTAssertFalse(TeamsSpeakerObserver.isEnabled(defaults))
        defaults.set(true, forKey: TeamsSpeakerObserver.enabledKey)
        XCTAssertTrue(TeamsSpeakerObserver.isEnabled(defaults))
    }
}
