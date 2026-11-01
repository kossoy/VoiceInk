import Foundation
import XCTest

@testable import ScribeBenchKit
@testable import ScribeCore

final class ScoringTests: XCTestCase {
    func testNormalisationMatchesTheBenchmark() {
        XCTAssertEqual(Scoring.normalize("Ёлка, user-cab-bank-2!  OK"), "елка user cab bank 2 ok")
        XCTAssertEqual(Scoring.words("oleg@kossoy.com"), ["oleg", "kossoy", "com"])
        XCTAssertEqual(Scoring.words("T3 Code — «запусти» deploy."), ["t3", "code", "запусти", "deploy"])
        XCTAssertEqual(Scoring.words("שלום עולם"), ["שלום", "עולם"])
    }

    func testLatinTokens() {
        XCTAssertTrue(Scoring.isLatin("deploy"))
        XCTAssertTrue(Scoring.isLatin("t3"))
        XCTAssertFalse(Scoring.isLatin("2026"))
        XCTAssertFalse(Scoring.isLatin("деплой"))
    }

    func testWordErrorRateAndLatinKept() {
        let counts = Scoring.score(reference: "запусти deploy на staging сейчас", hypothesis: "запусти деплой на staging")
        XCTAssertEqual(counts.referenceWords, 5)
        XCTAssertEqual(counts.wordErrors, 2)
        XCTAssertEqual(counts.referenceLatin, 2)
        XCTAssertEqual(counts.latinKept, 1)
        XCTAssertEqual(counts.wer ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(counts.latinKeptPercent ?? -1, 50, accuracy: 0.001)
        let exact = Scoring.score(reference: "Привет, мир.", hypothesis: "привет мир")
        XCTAssertEqual(exact.exact, 1)
        XCTAssertEqual(exact.wordErrors, 0)
    }

    func testEditDistanceEdges() {
        XCTAssertEqual(Scoring.editDistance([String](), ["a"]), 1)
        XCTAssertEqual(Scoring.editDistance(["a", "b"], [String]()), 2)
        XCTAssertEqual(Scoring.editDistance(["a", "b", "c"], ["a", "x", "c", "d"]), 2)
    }

    func testPercentile() {
        XCTAssertNil(Scoring.percentile([], 0.5))
        XCTAssertEqual(Scoring.percentile([1, 2, 3, 4], 0.5) ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(Scoring.percentile([0.2, 0.1, 0.3], 0.95) ?? 0, 0.29, accuracy: 1e-9)
    }
}

final class AudioTests: XCTestCase {
    func testVoiceInkResamplerDropsTheFractionalFramePerBuffer() {
        let input = [Float](repeating: 0.25, count: 512 * 30)
        let output = BenchAudio.voiceInkCaptureResample(input, inputRate: 48_000, bufferFrames: 512)
        // 512 * 16 000 / 48 000 = 170.67 -> 170 per buffer: ~0.4% of the audio is lost.
        XCTAssertEqual(output.count, 170 * 30)
        XCTAssertTrue(output.allSatisfy { $0 == Int16(0.25 * 32_767.0) })
    }

    func testVoiceInkResamplerPassesSixteenKilohertzThrough() {
        let input: [Float] = [0, 0.5, -0.5, 1.5, -1.5]
        XCTAssertEqual(
            BenchAudio.voiceInkCaptureResample(input, inputRate: 16_000, bufferFrames: 2),
            [0, 16_383, -16_383, 32_767, -32_768])
    }

    func testConverterRoundTripKeepsLengthAndTone() throws {
        let tone16k = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000) * 0.5) }
        let up = try BenchAudio.resample(tone16k, from: 16_000, to: 48_000)
        XCTAssertEqual(Double(up.count), 48_000, accuracy: 512)
        let down = try BenchAudio.resample(up, from: 48_000, to: 16_000)
        XCTAssertEqual(Double(down.count), 16_000, accuracy: 256)
        let rms = (down.map { Double($0 * $0) }.reduce(0, +) / Double(down.count)).squareRoot()
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.03)
    }

    func testWavHeaderRoundTripsThroughAVAudioFile() throws {
        let samples: [Int16] = (0..<1_600).map { Int16(truncatingIfNeeded: $0 * 20) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).wav")
        try BenchAudio.wav16k(samples).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try BenchAudio.loadMono(url)
        XCTAssertEqual(loaded.sampleRate, 16_000)
        XCTAssertEqual(BenchAudio.pcm16(loaded.samples).count, samples.count)
        XCTAssertEqual(Array(BenchAudio.pcm16(loaded.samples).prefix(4)), Array(samples.prefix(4)))
    }
}

final class OptionsTests: XCTestCase {
    func testDefaultsAndFlags() throws {
        XCTAssertEqual(try BenchOptions.parse([]), BenchOptions())
        let options = try BenchOptions.parse([
            "--recordings", "/tmp/r", "--refs", "/tmp/refs.jsonl", "--limit", "5", "--ab", "0", "--ab-rate", "44100",
            "--ab-buffer", "256", "--realtime", "1", "--language", "he",
        ])
        XCTAssertEqual(options.recordings, "/tmp/r")
        XCTAssertEqual(options.refs, "/tmp/refs.jsonl")
        XCTAssertEqual(options.limit, 5)
        XCTAssertEqual(options.abCount, 0)
        XCTAssertEqual(options.abRate, 44_100)
        XCTAssertEqual(options.abBuffer, 256)
        XCTAssertEqual(options.realtimeCount, 1)
        XCTAssertEqual(options.language, "he")
        XCTAssertThrowsError(try BenchOptions.parse(["--bogus"]))
        XCTAssertThrowsError(try BenchOptions.parse(["--limit"]))
        XCTAssertThrowsError(try BenchOptions.parse(["--ab-buffer", "0"]))
    }

    func testReferencesFromConsensusAndRaycastRows() {
        let refs = BenchReferences.parse(
            """
            {"id":"A","text":"one","uncertain_spans":[]}
            {"id":"B","value":"two","rawValue":"raw"}
            {"id":"C","rawValue":"three"}
            not json
            {"text":"no id"}
            """)
        XCTAssertEqual(refs, ["A": "one", "B": "two", "C": "three"])
    }

    func testTallyCountsFailuresAndLatency() {
        var tally = BenchTally()
        tally.add(reference: "a b c d", outcome: .text("a b c"), latency: 0.2)
        tally.add(reference: "x", outcome: .failed(.retryable("boom")), latency: 1)
        XCTAssertEqual(tally.attempted, 2)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(tally.latencies, [0.2])
        XCTAssertEqual(tally.counts.wer ?? -1, 25, accuracy: 0.001)
        XCTAssertTrue(tally.summary().contains("failed 1/2"))
    }
}
