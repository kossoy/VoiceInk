import XCTest
@testable import MeetingCore

final class MeetingDetectionTests: XCTestCase {
    private let call = MeetingAppActivity(inputActive: true, outputActive: true)
    private let idle = MeetingAppActivity(inputActive: false, outputActive: false)

    func testNeedsBothDirectionsAndSustainedActivity() {
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe(.init(inputActive: true, outputActive: false), at: 0))
        XCTAssertNil(policy.observe(.init(inputActive: false, outputActive: true), at: 2))
        XCTAssertNil(policy.observe(call, at: 4))
        XCTAssertNil(policy.observe(call, at: 6))
        XCTAssertEqual(policy.observe(call, at: 8), .detected)
        XCTAssertTrue(policy.isMeetingActive)
        XCTAssertNil(policy.observe(call, at: 10))
    }

    func testShortMicTestOrPollingGapDoesNotTrigger() {
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe(call, at: 0))
        XCTAssertNil(policy.observe(idle, at: 2))
        XCTAssertNil(policy.observe(call, at: 4))
        XCTAssertNil(policy.observe(call, at: 20))
        XCTAssertNil(policy.observe(call, at: 22))
        XCTAssertEqual(policy.observe(call, at: 24), .detected)
    }

    func testMuteGapDoesNotReNotifyAndNewMeetingDoes() {
        var policy = MeetingDetectionPolicy()
        for time in [0.0, 2, 4] { _ = policy.observe(call, at: time) }
        XCTAssertNil(policy.observe(idle, at: 6))
        XCTAssertNil(policy.observe(idle, at: 20))
        XCTAssertNil(policy.observe(call, at: 22))
        XCTAssertNil(policy.observe(call, at: 26))
        XCTAssertEqual(policy.observe(idle, at: 56), .ended)
        XCTAssertFalse(policy.isMeetingActive)
        XCTAssertNil(policy.observe(call, at: 60))
        XCTAssertNil(policy.observe(call, at: 62))
        XCTAssertEqual(policy.observe(call, at: 64), .detected)
    }

    func testUnavailableSnapshotDoesNotInventAnEnd() {
        var policy = MeetingDetectionPolicy()
        for time in [0.0, 2, 4] { _ = policy.observe(call, at: time) }
        XCTAssertNil(policy.observe(nil, at: 100))
        XCTAssertTrue(policy.isMeetingActive)
        XCTAssertNil(policy.observe(call, at: 102))
    }

    func testExistingRecordingSuppressesTheReminderForThatCall() {
        var policy = MeetingDetectionPolicy()
        for time in [0.0, 2, 4, 6] {
            XCTAssertNil(policy.observe(call, at: time, recording: true))
        }
        XCTAssertTrue(policy.isMeetingActive)
        XCTAssertNil(policy.observe(call, at: 8, recording: false))
    }

    func testDisableStopsAndReenableStartsFresh() {
        var policy = MeetingDetectionPolicy()
        for time in [0.0, 2, 4] { _ = policy.observe(call, at: time) }
        XCTAssertEqual(policy.observe(call, at: 6, enabled: false), .ended)
        XCTAssertFalse(policy.isMeetingActive)
        XCTAssertNil(policy.observe(call, at: 8, enabled: false))
        XCTAssertNil(policy.observe(call, at: 10))
        XCTAssertNil(policy.observe(call, at: 12))
        XCTAssertEqual(policy.observe(call, at: 14), .detected)
    }

    func testInvalidObservationCannotModifyState() {
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe(call, at: .nan))
        XCTAssertNil(policy.observe(call, at: -1))
        XCTAssertNil(policy.observe(call, at: 4))
        XCTAssertNil(policy.observe(idle, at: 2))
        XCTAssertNil(policy.observe(call, at: 6))
        XCTAssertEqual(policy.observe(call, at: 8), .detected)
    }

    func testBothPermissionsAreRequiredAndDeniedHasSettingsAction() {
        for microphone in [MeetingPermissionState.notRequested, .allowed, .denied, .restricted] {
            for system in [MeetingPermissionState.notRequested, .allowed, .denied, .restricted] {
                let permissions = MeetingPermissionSnapshot(microphone: microphone, systemAudio: system)
                XCTAssertEqual(permissions.isReady, microphone == .allowed && system == .allowed)
            }
        }
        XCTAssertEqual(MeetingPermissionState.notRequested.actionTitle, "Allow")
        XCTAssertEqual(MeetingPermissionState.denied.actionTitle, "Open Settings")
        XCTAssertEqual(MeetingPermissionState.restricted.actionTitle, "Restricted")
    }
}
