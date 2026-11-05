import AVFoundation
import XCTest
@testable import MeetingSystem

@MainActor
final class MeetingPermissionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var mic: AVAuthorizationStatus = .notDetermined
    private var system = false
    private var microphoneRequests = 0
    private var systemRequests = 0
    private var openedURLs: [URL] = []

    override func setUp() async throws {
        suite = "MeetingPermissionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func controller() -> MeetingPermissions {
        MeetingPermissions(defaults: defaults, client: MeetingPermissionClient(
            microphoneStatus: { self.mic }, systemAudioAllowed: { self.system },
            requestMicrophone: { self.microphoneRequests += 1; self.mic = .authorized; return true },
            requestSystemAudio: { self.systemRequests += 1; return self.system },
            openURL: { self.openedURLs.append($0) }))
    }

    func testOpeningOrRefreshingNeverRequestsAccess() {
        let permissions = controller()
        permissions.refresh()
        XCTAssertFalse(permissions.snapshot.isReady)
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertEqual(systemRequests, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testAllowMicrophoneUpdatesStateAndDoesNotRepeatPrompt() async {
        let permissions = controller()
        await permissions.allow(.microphone)
        XCTAssertEqual(permissions.snapshot.microphone, .allowed)
        await permissions.allow(.microphone)
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertNil(permissions.requesting)
    }

    func testDeniedMicrophoneOpensSettingsInsteadOfRequestingAgain() async {
        mic = .denied
        let permissions = controller()
        await permissions.allow(.microphone)
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertEqual(openedURLs.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        mic = .authorized
        permissions.refresh()
        XCTAssertEqual(permissions.snapshot.microphone, .allowed)
    }

    func testRestrictedMicrophoneDoesNotOfferAnUnfulfillablePrompt() async {
        mic = .restricted
        let permissions = controller()
        await permissions.allow(.microphone)
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testSystemAudioRequestIsExplicitAndRememberedAcrossRestarts() async {
        let permissions = controller()
        await permissions.allow(.systemAudio)
        XCTAssertEqual(systemRequests, 1)
        XCTAssertEqual(permissions.snapshot.systemAudio, .denied)
        let restarted = controller()
        await restarted.allow(.systemAudio)
        XCTAssertEqual(systemRequests, 1)
        XCTAssertEqual(openedURLs.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        system = true
        mic = .authorized
        restarted.refresh()
        XCTAssertTrue(restarted.snapshot.isReady)
    }

    func testAlreadyGrantedAccessNeedsNoFurtherAllow() async {
        mic = .authorized
        system = true
        let permissions = controller()
        await permissions.allow(.microphone)
        await permissions.allow(.systemAudio)
        XCTAssertTrue(permissions.snapshot.isReady)
        XCTAssertEqual(systemRequests + microphoneRequests, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }
}
