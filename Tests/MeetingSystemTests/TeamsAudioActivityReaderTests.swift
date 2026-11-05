import XCTest
@testable import MeetingSystem

@available(macOS 14.2, *)
final class TeamsAudioActivityReaderTests: XCTestCase {
    func testTeamsHelpersMatchButUnrelatedAppsDoNot() {
        for bundle in ["com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.teams2.helper",
                       "com.microsoft.teams2.helper.audio"] {
            XCTAssertTrue(TeamsAudioActivityReader.isTeamsBundle(bundle), bundle)
        }
        for bundle in ["", "com.microsoft.teams20", "com.microsoft.teams2fake", "org.fake.com.microsoft.teams2",
                       "com.google.Chrome", "com.prakashjoshipax.VoiceInk"] {
            XCTAssertFalse(TeamsAudioActivityReader.isTeamsBundle(bundle), bundle)
        }
    }
}
