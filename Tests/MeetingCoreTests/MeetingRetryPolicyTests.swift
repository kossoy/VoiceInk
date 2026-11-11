import Foundation
import XCTest
@testable import MeetingCore

final class MeetingRetryPolicyTests: XCTestCase {
    private func kind(_ signal: MeetingFailureSignal) -> MeetingFailureKind {
        MeetingFailureClassifier.classify(signal)
    }

    func testURLTimeoutAndDroppedConnectionsAreTransient() {
        for code in [-1001, -1003, -1004, -1005, -1006, -1200] {
            XCTAssertEqual(kind(.init(urlErrorCode: code)), .transient, "URL error \(code)")
        }
    }

    func testNoInternetIsOffline() {
        XCTAssertEqual(kind(.init(urlErrorCode: -1009)), .offline)
    }

    func testRetryableHTTPStatusesAreTransient() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(kind(.init(httpStatus: status)), .transient, "HTTP \(status)")
        }
    }

    func testClientErrorsArePermanent() {
        for status in [400, 401, 403, 404, 422] {
            XCTAssertEqual(kind(.init(httpStatus: status)), .permanent, "HTTP \(status)")
        }
    }

    func testKnownPermanentWinsOverEverything() {
        XCTAssertEqual(kind(.init(urlErrorCode: -1001, isKnownPermanent: true)), .permanent)
        XCTAssertEqual(kind(.init(httpStatus: 503, isKnownPermanent: true)), .permanent)
    }

    func testSDKTimeoutAndGenericNetworkAreTransient() {
        XCTAssertEqual(kind(.init(isTimeout: true)), .transient)
        XCTAssertEqual(kind(.init(isGenericNetwork: true)), .transient)
    }

    func testProviderOverloadWordingIsTransient() {
        XCTAssertEqual(kind(.init(message: "Rate limit exceeded, try again later")), .transient)
        XCTAssertEqual(kind(.init(message: "Model overloaded")), .transient)
        // Today's ElevenLabs failure text, if it ever arrives without a code.
        XCTAssertEqual(kind(.init(message: "A network error occurred: The request timed out.")), .transient)
    }

    func testUnknownLocalFailureIsPermanent() {
        XCTAssertEqual(kind(.init(message: "The recorded model is unavailable. Restore it, then Retry.")), .permanent)
    }

    func testBackoffGrowsThenStaysAtOneMinute() {
        var backoff = MeetingRetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        let delays = (0..<8).map { backoff.recordFailure(at: start.addingTimeInterval(Double($0))) }
        XCTAssertEqual(delays, [2, 5, 15, 30, 60, 60, 60, 60])
        XCTAssertEqual(backoff.attempts, 8)
        XCTAssertEqual(backoff.streakStart, start)
    }

    func testFailureSurfacesOnlyAfterTenMinutesOfContinuousFailure() {
        var backoff = MeetingRetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(backoff.shouldSurface(at: start))
        _ = backoff.recordFailure(at: start)
        XCTAssertFalse(backoff.shouldSurface(at: start.addingTimeInterval(599)))
        XCTAssertTrue(backoff.shouldSurface(at: start.addingTimeInterval(600)))
    }

    func testResetStartsTheBackoffOver() {
        var backoff = MeetingRetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = backoff.recordFailure(at: start)
        _ = backoff.recordFailure(at: start)
        backoff.reset()
        XCTAssertFalse(backoff.isFailing)
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(1_000)), 2)
        XCTAssertFalse(backoff.shouldSurface(at: start.addingTimeInterval(1_000)))
    }

    func testOfflineStartsTheStreakWithoutSpendingAttempts() {
        var backoff = MeetingRetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        backoff.recordOffline(at: start)
        backoff.recordOffline(at: start.addingTimeInterval(60))
        XCTAssertEqual(backoff.attempts, 0)
        XCTAssertTrue(backoff.isFailing)
        XCTAssertTrue(backoff.shouldSurface(at: start.addingTimeInterval(600)))
        // Back online: the first network retry still waits only 2 s.
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(700)), 2)
    }

    func testStatusLineIsCalmUntilSurfaced() {
        let calm = MeetingRetryBackoff.statusLine(kind: .transient, retryIn: 4.2, pending: 235, surfaced: false)
        XCTAssertEqual(calm, "Network issue, retrying in 5 s · 235 pending")
        let offline = MeetingRetryBackoff.statusLine(kind: .offline, retryIn: 60, pending: 3, surfaced: false)
        XCTAssertTrue(offline.hasPrefix("Offline"))
        let loud = MeetingRetryBackoff.statusLine(kind: .transient, retryIn: 60, pending: 3, surfaced: true)
        XCTAssertTrue(loud.contains("keeps failing"))
        XCTAssertTrue(loud.contains("retrying automatically"))
    }

    func testJobFilesWithoutAttemptsStillDecode() throws {
        let chunk = MeetingAudioChunk(source: .system, range: try MeetingTimeRange(start: 1, end: 2), samples: [0, 1])
        var job = MeetingAudioJob(chunk: chunk, modelKey: "scribe_v2", language: nil)
        job.attempts = 3
        let encoded = try MeetingTranscriptExport.encoder().encode(job)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(legacy["attempts"] as? Int, 3)
        legacy.removeValue(forKey: "attempts")
        let decoded = try JSONDecoder().decode(MeetingAudioJob.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.attempts, 0)
        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.state, MeetingAudioJob.State.pending)
        let roundTrip = try JSONDecoder().decode(MeetingAudioJob.self, from: encoded)
        XCTAssertEqual(roundTrip, job)
    }
}
