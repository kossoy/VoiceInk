import Foundation
import XCTest
@testable import MeetingCore

final class MeetingAudioTests: XCTestCase {
    func testInterruptedResumeCanCloseBeforeReceivingTheNextAudioChunk() throws {
        var session = MeetingSession(title: "Interrupted resume")
        try session.pause(at: 10)
        try session.resume(at: 100)
        try session.finish(at: session.latestActivityTime)
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(session.recordedRanges.last?.start, 100)
        XCTAssertEqual(session.recordedRanges.last?.end, 100)
        XCTAssertNoThrow(try session.validate())
    }

    func testLongSilenceDoesNotBecomeASRWork() throws {
        var chunker = MeetingAudioChunker(source: .microphone)
        for second in 0..<120 {
            XCTAssertTrue(try chunker.append([Int16](repeating: 0, count: 16_000), at: Double(second)).isEmpty)
        }
        XCTAssertNil(try chunker.flush())
    }

    func testEndOfUtterancePreservesPrerollAndTailOnTheAudioClock() throws {
        var chunker = MeetingAudioChunker(source: .system)
        XCTAssertTrue(try chunker.append([Int16](repeating: 0, count: 16_000), at: 5).isEmpty)
        XCTAssertTrue(try chunker.append([Int16](repeating: 2000, count: 8_000), at: 6).isEmpty)
        let result = try chunker.append([Int16](repeating: 0, count: 16_000), at: 6.5)
        XCTAssertEqual(result.count, 1)
        let chunk = try XCTUnwrap(result.first)
        XCTAssertEqual(chunk.source, .system)
        XCTAssertEqual(chunk.range.start, 5.8, accuracy: 0.001)
        XCTAssertEqual(chunk.range.end, 7.2, accuracy: 0.001)
        XCTAssertEqual(chunk.samples.filter { $0 == 2000 }.count, 8_000)
        XCTAssertNil(try chunker.flush())
    }

    func testLongSpeechIsBoundedWithoutDuplicatingOrDroppingSamples() throws {
        var chunker = MeetingAudioChunker(source: .microphone, maximumSeconds: 2)
        let input = (0..<80_000).map { Int16(1000 + $0 % 1000) }
        var chunks = try chunker.append(input, at: 0)
        if let tail = try chunker.flush() { chunks.append(tail) }
        XCTAssertEqual(chunks.map(\.samples).flatMap { $0 }, input)
        XCTAssertEqual(chunks.map(\.range.start), [0, 2, 4])
        XCTAssertEqual(chunks.map(\.range.end), [2, 4, 5])
    }

    func testPauseFlushAndResumeNeverJoinAcrossTheGap() throws {
        var chunker = MeetingAudioChunker(source: .system)
        _ = try chunker.append([Int16](repeating: 2000, count: 16_000), at: 0)
        let before = try XCTUnwrap(chunker.flush())
        _ = try chunker.append([Int16](repeating: 3000, count: 16_000), at: 30)
        let after = try XCTUnwrap(chunker.flush())
        var session = MeetingSession(title: "Pause")
        try session.pause(at: 1)
        try session.resume(at: 30)
        try session.finish(at: 31)
        for chunk in [before, after] {
            try session.upsert(MeetingTranscriptSegment(source: chunk.source, range: chunk.range, text: "raw", isFinal: true))
        }
        XCTAssertEqual(session.finalSegments.map(\.range), [before.range, after.range])
    }

    func testDroppedPacketsFlushRatherThanInventingContinuousSpeech() throws {
        var chunker = MeetingAudioChunker(source: .system)
        _ = try chunker.append([Int16](repeating: 2000, count: 16_000), at: 0)
        let chunks = try chunker.append([Int16](repeating: 2000, count: 16_000), at: 10)
        XCTAssertEqual(chunks.first?.range.end, 1)
        XCTAssertEqual(try chunker.flush()?.range.start, 10)
        XCTAssertThrowsError(try chunker.append([1], at: .nan))
    }

    func testDurableQueueRecoversAudioAndFailureForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var chunker = MeetingAudioChunker(source: .microphone)
        _ = try chunker.append([Int16](repeating: -1234, count: 16_000), at: 2)
        let chunk = try XCTUnwrap(chunker.flush())
        let store = MeetingAudioJobStore(sessionDirectory: directory)
        var job = try store.enqueue(chunk, modelKey: "local-model", language: "ru")
        let audio = try Data(contentsOf: store.audioURL(for: job.id))
        XCTAssertEqual(audio.count, 44 + 32_000)
        XCTAssertEqual(String(data: audio.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: audio[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(Array(audio[44..<46]), [0x2e, 0xfb]) // -1234, little-endian
        job.state = .failed
        job.error = "Provider offline"
        try store.save(job)
        let restored = try MeetingAudioJobStore(sessionDirectory: directory).load()
        XCTAssertEqual(restored, [job])
        XCTAssertEqual(restored.first?.range, chunk.range)
        XCTAssertEqual(restored.first?.language, "ru")
    }
}
