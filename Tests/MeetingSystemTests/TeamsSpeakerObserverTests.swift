import XCTest
@testable import MeetingSystem
#if SWIFT_PACKAGE
import MeetingCore
#endif

// Fixture strings follow labels reported for Teams 2 desktop (public reverse engineering);
// replace or extend them with strings recorded by `.oklabs/meeting-probe --watch`.
final class TeamsSpeakerObserverTests: XCTestCase {
    func testSpeakingLabels() {
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Alex Smith is speaking"), "Alex Smith")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Alex Smith (Guest) is speaking"), "Alex Smith")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "  Smith, Alex (Unverified) is speaking "), "Smith, Alex")
        XCTAssertEqual(TeamsSpeakerParser.speakingName(fromLabel: "Dana Lee, speaking"), "Dana Lee")
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "is speaking"))
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "Alex Smith, Unmuted"))
        XCTAssertNil(TeamsSpeakerParser.speakingName(fromLabel: "Mute (⌘⇧M)"))
    }

    func testNameNormalisation() {
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Alex Smith (Unverified), Meeting guest, Unmuted"), "Alex Smith")
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Alex Smith (External) (Guest)"), "Alex Smith")
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Kossoy, Oleg, Organizer, Muted"), "Kossoy, Oleg")
        XCTAssertEqual(TeamsSpeakerParser.normalizeName("Alex\u{00A0}Smith  (Sales)"), "Alex Smith (Sales)")
        XCTAssertEqual(TeamsSpeakerParser.participantID(for: "Alex  SMITH"), "teams:alex smith")
    }

    func testRosterRows() {
        XCTAssertEqual(TeamsSpeakerParser.rosterName(fromLabel: "Alex Smith (Guest), Meeting guest, Muted"), "Alex Smith")
        XCTAssertNil(TeamsSpeakerParser.rosterName(fromLabel: "In this meeting (3)"))
        XCTAssertNil(TeamsSpeakerParser.rosterName(fromLabel: "Mute all"))
        XCTAssertNil(TeamsSpeakerParser.rosterName(fromLabel: ""))
    }

    func testSnapshotFromSpeakingGroupAndTile() {
        let nodes = [
            TeamsAXNode(role: "AXGroup", subrole: "AXSystemDialog", labels: ["Alex Smith is speaking"],
                        windowTitle: "Meeting compact view"),
            TeamsAXNode(role: "AXMenuItem", labels: ["Dana Lee, Unmuted"], domClasses: ["tile", "vdi-frame-occlusion"]),
            TeamsAXNode(role: "AXMenuItem", labels: ["Sam Roe, Muted"], domClasses: ["tile"]),
            TeamsAXNode(role: "AXStaticText", labels: []),
        ]
        XCTAssertEqual(TeamsSpeakerSnapshot.from(nodes: nodes).speaking, ["Alex Smith", "Dana Lee"])
    }

    func testTrackerHoldsAcrossFlickerAndClosesAfterHold() {
        var tracker = TeamsSpeakerTracker(hold: 2.5, staleAfter: 20)
        func snap(_ names: Set<String>, _ fp: Int) -> TeamsSpeakerSnapshot { .init(speaking: names, fingerprint: fp) }
        XCTAssertEqual(tracker.observe(snap(["Alex"], 1), at: 10), [])
        XCTAssertEqual(tracker.observe(snap([], 2), at: 11), [])          // flicker, within hold
        XCTAssertEqual(tracker.observe(snap(["Alex"], 3), at: 12), [])
        XCTAssertEqual(tracker.observe(snap(["Dana"], 4), at: 13), [])
        let closed = tracker.observe(snap(["Dana"], 5), at: 15)
        XCTAssertEqual(closed.map(\.displayName), ["Alex"])
        XCTAssertEqual(closed.first?.range.start, 10)
        XCTAssertEqual(closed.first?.range.end, 12)
        let rest = tracker.finish(at: 16)
        XCTAssertEqual(rest.map(\.displayName), ["Dana"])
        XCTAssertEqual(rest.first?.range.start, 13)
        XCTAssertEqual(rest.first?.range.end, 16)
        XCTAssertEqual(rest.first?.participantID, "teams:dana")
    }

    func testFrozenTreeStopsAttribution() {
        var tracker = TeamsSpeakerTracker(hold: 2.5, staleAfter: 5)
        let frozen = TeamsSpeakerSnapshot(speaking: ["Alex"], fingerprint: 7)
        XCTAssertEqual(tracker.observe(frozen, at: 0), [])
        XCTAssertEqual(tracker.observe(frozen, at: 3), [])
        let closed = tracker.observe(frozen, at: 9)
        XCTAssertEqual(closed.map(\.displayName), ["Alex"])
        XCTAssertEqual(closed.first?.range.end, 3)
        XCTAssertEqual(tracker.observe(nil, at: 10), [])
    }

    func testBundleMatching() {
        XCTAssertTrue(TeamsSpeakerParser.isTeamsBundle("com.microsoft.teams2.helper"))
        XCTAssertFalse(TeamsSpeakerParser.isTeamsBundle("com.microsoft.teams20"))
    }
}
