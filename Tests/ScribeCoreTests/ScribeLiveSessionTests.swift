import Foundation
import XCTest

@testable import ScribeCore

/// End-to-end scenarios against `MockScribeServer` over a real URLSession WebSocket
/// (plan B.5.2). Each test checks the joined text, the commits the server saw,
/// whether the outcome would send the recording to batch, and the stop-to-result time.
final class ScribeLiveSessionTests: XCTestCase {
    private var server: MockScribeServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func makeServer(_ scripts: [MockScribeServer.Script], receiveBufferBytes: Int32? = nil) throws
        -> MockScribeServer
    {
        let server = try MockScribeServer(scripts, receiveBufferBytes: receiveBufferBytes)
        self.server = server
        return server
    }

    private func makeSession(
        _ server: MockScribeServer,
        finalWait: TimeInterval = 4,
        connectTimeout: TimeInterval = 2,
        previousText: String? = nil,
        language: String? = nil
    ) throws -> ScribeLiveSession {
        let url = try ScribeURL.build(endpoint: server.endpoint, language: language, keyterms: ["T3 Code", "Hyprland"])
        return ScribeLiveSession(
            config: ScribeSessionConfig(
                url: url, apiKey: "test-key", previousText: previousText, connectTimeout: connectTimeout,
                finalWait: finalWait))
    }

    /// Feeds audio the way the recorder does: small PCM16 LE render chunks.
    private func feed(_ session: ScribeLiveSession, _ samples: [Int16], chunk: Int = 160) async {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            await session.append(ScribeWire.pcmBytes(Array(samples[offset..<end])))
            offset = end
        }
    }

    private func finishTimed(_ session: ScribeLiveSession) async -> (ScribeOutcome, TimeInterval) {
        let start = Date()
        let outcome = await session.finish()
        return (outcome, Date().timeIntervalSince(start))
    }

    private func waitForFailure(_ session: ScribeLiveSession, timeout: TimeInterval) async -> ScribeError? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let failure = session.status.failure { return failure }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return session.status.failure
    }

    // MARK: - Normal dictations

    func testShortDictationStreamsAndCommitsOnceAtStop() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(5))
        let (outcome, waited) = await finishTimed(session)

        XCTAssertEqual(outcome, .text("seg1"))
        XCTAssertLessThan(waited, 1.0, "stop to text")
        let log = try XCTUnwrap(server.connections.first)
        XCTAssertEqual(log.commits, 1)
        XCTAssertEqual(log.segments, [80_000])
        XCTAssertEqual(log.apiKey, "test-key")
        XCTAssertTrue(log.path.contains("model_id=scribe_v2_realtime"))
        XCTAssertTrue(log.path.contains("commit_strategy=manual"))
        XCTAssertTrue(log.path.contains("no_verbatim=true"))
        XCTAssertTrue(log.path.contains("keyterms=T3%20Code"))
        XCTAssertFalse(log.path.contains("language_code"))
        // 100 ms frames while streaming, the 0.0 s tail goes out as no extra frame.
        XCTAssertTrue(log.chunks.dropLast().allSatisfy { $0.samples == 1_600 })
        let stats = await session.snapshot()
        XCTAssertEqual(stats.receivedSamples, 80_000)
        XCTAssertEqual(stats.sentSamples, 80_000)
        XCTAssertEqual(stats.commitsAnswered, 1)
        XCTAssertEqual(stats.unsolicitedCommits, 0)
    }

    func testLongDictationWithAPauseCommitsAtThePauseAndByThirtyFourSeconds() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(31) + silence(0.5) + tone(38.5))
        let (outcome, waited) = await finishTimed(session)

        XCTAssertEqual(outcome, .text("seg1 seg2 seg3"))
        XCTAssertLessThan(waited, 2.0)
        let log = try XCTUnwrap(server.connections.first)
        XCTAssertEqual(log.segments, [500_800, 544_000, 75_200])
        XCTAssertEqual(log.samples, 70 * 16_000)
    }

    func testLongDictationWithoutPauseNeverReachesTheServerAutoCommit() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(70))
        let (outcome, _) = await finishTimed(session)

        // The mock commits on its own after 36 s of uncommitted audio, like the real
        // server; the client's 34 s limit keeps that from ever happening.
        XCTAssertEqual(outcome, .text("seg1 seg2 seg3"))
        let log = try XCTUnwrap(server.connections.first)
        XCTAssertEqual(log.segments, [544_000, 544_000, 32_000])
        let stats = await session.snapshot()
        XCTAssertEqual(stats.unsolicitedCommits, 0)
        XCTAssertEqual(stats.commitsSent, 3)
    }

    func testUnsolicitedServerCommitIsJoinedNotCountedAsTheAnswer() async throws {
        let server = try makeServer([.autoCommitAfter(16_000)])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(3))
        // The server's commit must arrive before the final commit is on the wire;
        // otherwise it is (correctly, per voxtype) taken as the answer.
        let end = Date().addingTimeInterval(3)
        while await session.snapshot().unsolicitedCommits == 0, Date() < end {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let (outcome, _) = await finishTimed(session)

        XCTAssertEqual(outcome, .text("auto1 seg1"))
        let stats = await session.snapshot()
        XCTAssertEqual(stats.unsolicitedCommits, 1)
        XCTAssertEqual(stats.commitsSent, 1)
        XCTAssertEqual(stats.commitsAnswered, 1)
    }

    // MARK: - Final segment padding

    func testShortTailRightAfterACommitIsPaddedSoItIsNotThrottled() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        // 34 s commits on its own; 0.1 s (one full frame) is left uncommitted.
        await feed(session, tone(34.1))
        let (outcome, _) = await finishTimed(session)

        XCTAssertEqual(outcome, .text("seg1 seg2"))
        let log = try XCTUnwrap(server.connections.first)
        XCTAssertEqual(log.segments, [544_000, 5_600])
        let stats = await session.snapshot()
        XCTAssertEqual(stats.paddedSamples, 4_000)
        XCTAssertEqual(stats.sentSamples, 545_600)
        XCTAssertEqual(stats.throttledCommits, 0)
    }

    func testSubFrameTailIsSentAndPadded() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(34.05))
        let (outcome, _) = await finishTimed(session)

        XCTAssertEqual(outcome, .text("seg1 seg2"))
        XCTAssertEqual(server.connections.first?.segments, [544_000, 5_600])
    }

    func testVeryShortRecordingIsPaddedToo() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(0.1))
        let (outcome, _) = await finishTimed(session)
        XCTAssertEqual(outcome, .text("seg1"))
        XCTAssertEqual(server.connections.first?.segments, [5_600])
    }

    func testEmptyRecordingCompletesWithoutACommit() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        let (outcome, waited) = await finishTimed(session)
        XCTAssertEqual(outcome, .text(""))
        XCTAssertLessThan(waited, 0.5)
        XCTAssertEqual(server.connections.first?.commits, 0)
    }

    func testThrottledCommitCountsAsAnsweredInsteadOfWaiting() async throws {
        let server = try makeServer([.throttleAll])
        let session = try makeSession(server, finalWait: 4)
        try await session.connect()
        await feed(session, tone(2))
        let (outcome, waited) = await finishTimed(session)
        XCTAssertEqual(outcome, .text(""))
        XCTAssertLessThan(waited, 1.0)
        let stats = await session.snapshot()
        XCTAssertEqual(stats.throttledCommits, 1)
    }

    func testPreviousTextGoesOnlyWithTheFirstChunk() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server, previousText: "dictation")
        try await session.connect()
        await feed(session, tone(1))
        _ = await session.finish()
        let chunks = try XCTUnwrap(server.connections.first?.chunks)
        XCTAssertEqual(chunks.first?.hasPreviousText, true)
        XCTAssertTrue(chunks.dropFirst().allSatisfy { !$0.hasPreviousText })
    }

    func testLanguageCodeIsSentWhenSet() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server, language: "he")
        try await session.connect()
        await feed(session, tone(1))
        _ = await session.finish()
        XCTAssertEqual(server.connections.first?.path.contains("language_code=he"), true)
    }

    // MARK: - Failures (each one must send the recording to batch)

    func testServerClosingMidStreamFailsTheSessionBeforeStop() async throws {
        let server = try makeServer([.closeAfter(20 * 16_000)])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(25))
        let failure = await waitForFailure(session, timeout: 3)
        XCTAssertEqual(failure?.isFatal, false, "closed connection is retryable")
        let (outcome, waited) = await finishTimed(session)
        guard case .failed(let error) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(error.isFatal)
        XCTAssertLessThan(waited, 0.5, "a failed stream goes to batch without a final wait")
    }

    func testTranscriberErrorIsRetryable() async throws {
        let server = try makeServer([.failAfterFirstChunk])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(1))
        let failure = await waitForFailure(session, timeout: 3)
        XCTAssertEqual(failure, .retryable("transcriber_error: boom"))
        let (outcome, _) = await finishTimed(session)
        XCTAssertEqual(outcome, .failed(.retryable("transcriber_error: boom")))
    }

    func testBlackHoledConnectionIsDetectedByTheStallLimit() async throws {
        let server = try makeServer([.blackhole], receiveBufferBytes: 4_096)
        let session = try makeSession(server, finalWait: 6)
        try await session.connect()
        // A minute of audio is far more than the socket buffers hold.
        await feed(session, tone(60), chunk: 1_600)
        try await Task.sleep(nanoseconds: 300_000_000)
        let (outcome, waited) = await finishTimed(session)
        guard case .failed(let error) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(error.isFatal)
        XCTAssertTrue(error.message.contains("stalled"), error.message)
        XCTAssertLessThan(waited, 3.0, "stop must not wait for a stalled socket")
    }

    func testSilentServerHitsTheFinalDeadlineCountedFromStop() async throws {
        let server = try makeServer([.silent])
        let session = try makeSession(server, finalWait: 1.5)
        try await session.connect()
        await feed(session, tone(1))
        let (outcome, waited) = await finishTimed(session)
        guard case .failed(let error) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(error.isFatal)
        XCTAssertTrue(error.message.contains("deadline"), error.message)
        XCTAssertGreaterThanOrEqual(waited, 1.4)
        XCTAssertLessThan(waited, 2.5)
    }

    func testAuthErrorIsFatal() async throws {
        let server = try makeServer([.authError])
        let session = try makeSession(server)
        do {
            try await session.connect()
            XCTFail("connect should fail")
        } catch let error as ScribeError {
            XCTAssertEqual(error, .fatal("auth_error: Invalid API key"))
        }
        XCTAssertEqual(session.status.failure?.isFatal, true)
        let outcome = await session.finish()
        XCTAssertEqual(outcome, .failed(.fatal("auth_error: Invalid API key")))
    }

    func testHungHandshakeTimesOut() async throws {
        let server = try makeServer([.hang])
        let session = try makeSession(server, connectTimeout: 1)
        let start = Date()
        do {
            try await session.connect()
            XCTFail("connect should time out")
        } catch let error as ScribeError {
            XCTAssertFalse(error.isFatal)
            XCTAssertTrue(error.message.contains("timed out"), error.message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.8)
    }

    func testUnreachableServerIsRetryable() async throws {
        // Grab a free port, then close it so nothing listens there.
        let probe = try MockScribeServer([.normal])
        let endpoint = probe.endpoint
        probe.stop()
        let url = try ScribeURL.build(endpoint: endpoint, language: nil, keyterms: [])
        let session = ScribeLiveSession(config: ScribeSessionConfig(url: url, apiKey: "k", connectTimeout: 2))
        do {
            try await session.connect()
            XCTFail("connect should fail")
        } catch let error as ScribeError {
            XCTAssertFalse(error.isFatal)
        }
    }

    // MARK: - Cancel

    func testFinishAfterCloseReturnsAtOnce() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server, finalWait: 4)
        try await session.connect()
        await feed(session, tone(1.05))
        // A cancel that reaches the session before the stop path calls finish().
        await session.close()
        let (outcome, waited) = await finishTimed(session)
        XCTAssertEqual(outcome, .failed(.retryable("cancelled")))
        XCTAssertLessThan(waited, 0.5)
        XCTAssertTrue(server.waitFor { $0.first?.closed == true })
        XCTAssertEqual(server.connections.first?.commits, 0)
    }

    func testCloseDuringFinishResolvesTheWaiter() async throws {
        let server = try makeServer([.silent])
        let session = try makeSession(server, finalWait: 6)
        try await session.connect()
        await feed(session, tone(1))
        let finishing = Task { await session.finish() }
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.close()
        let outcome = await finishing.value
        XCTAssertEqual(outcome, .failed(.retryable("cancelled")))
    }

    func testConnectAfterCloseIsRefused() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        await session.close()
        do {
            try await session.connect()
            XCTFail("connect after close must fail")
        } catch let error as ScribeError {
            XCTAssertEqual(error, .retryable("cancelled"))
        }
        XCTAssertTrue(server.connections.isEmpty, "no socket may be opened after close")
    }

    func testCloseDuringHandshakeLeavesNoOpenSocket() async throws {
        let server = try makeServer([.hang])
        let session = try makeSession(server, connectTimeout: 3)
        let connecting = Task { try await session.connect() }
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.close()
        let start = Date()
        do {
            try await connecting.value
            XCTFail("connect must fail once closed")
        } catch let error as ScribeError {
            XCTAssertFalse(error.isFatal)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "close() must cut the handshake short")
        XCTAssertTrue(server.waitFor { $0.first?.closed == true }, "socket still open after close during handshake")
    }

    func testClosingWithoutFinishNeverCommits() async throws {
        let server = try makeServer([.normal])
        let session = try makeSession(server)
        try await session.connect()
        await feed(session, tone(0.5))
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.close()
        XCTAssertTrue(server.waitFor { $0.first?.closed == true }, "connection still open after close()")
        XCTAssertEqual(server.connections.first?.commits, 0, "a cancelled recording is never committed")
    }
}
