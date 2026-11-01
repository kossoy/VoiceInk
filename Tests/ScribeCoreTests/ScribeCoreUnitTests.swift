import Foundation
import XCTest

@testable import ScribeCore

func tone(_ seconds: Double, amplitude: Double = 0.5) -> [Int16] {
    let count = Int((seconds * 16_000).rounded())
    return (0..<count).map { i in
        Int16((sin(2 * Double.pi * 440 * Double(i) / 16_000) * amplitude * 32_767).rounded())
    }
}

func silence(_ seconds: Double) -> [Int16] {
    Array(repeating: 0, count: Int((seconds * 16_000).rounded()))
}

/// Neutral sample keyterms (the real list lives only on the user's machine).
let sampleKeyterms: [String] = (1...50).map { "Term\($0)" }

final class SegmenterTests: XCTestCase {
    private func commits(for audio: [Int16], frame: Int = ScribeLimits.liveFrameSamples) -> [Int] {
        var segmenter = Segmenter()
        var at: [Int] = []
        var offset = 0
        while offset < audio.count {
            let end = min(offset + frame, audio.count)
            if segmenter.push(Array(audio[offset..<end])) { at.append(end) }
            offset = end
        }
        return at
    }

    func testNoCommitUnderThirtySeconds() {
        XCTAssertEqual(commits(for: tone(29.9)), [])
        // Pauses before 30 s never split a recording.
        XCTAssertEqual(commits(for: tone(10) + silence(2) + tone(10) + silence(2) + tone(5)), [])
    }

    func testCommitsAtFirstQuietStretchAfterThirtySeconds() {
        // Quiet frames start at 31.0 s; three silent 0.1 s frames make the 0.3 s run.
        let audio = tone(31) + silence(0.5) + tone(2)
        XCTAssertEqual(commits(for: audio), [31 * 16_000 + 3 * 1_600])
    }

    func testForcesCommitAtThirtyFourSecondsOfSpeech() {
        XCTAssertEqual(commits(for: tone(70)), [544_000, 1_088_000])
    }

    func testResetsAfterACommit() {
        var segmenter = Segmenter()
        for frame in stride(from: 0, to: 544_000, by: 1_600) {
            let committed = segmenter.push(Array(repeating: 8_000, count: 1_600))
            XCTAssertEqual(committed, frame + 1_600 == 544_000)
        }
        XCTAssertEqual(segmenter.uncommitted, 0)
        XCTAssertEqual(segmenter.quietRun, 0)
        // A quiet stretch right after a commit does not commit again before 30 s.
        XCTAssertFalse(segmenter.push(Array(repeating: 0, count: 8_000)))
        XCTAssertEqual(segmenter.uncommitted, 8_000)
    }

    func testLimitsStayBelowTheServerAutoCommit() {
        XCTAssertLessThan(ScribeLimits.segmentHardSamples, 36 * 16_000)
        XCTAssertEqual(ScribeLimits.segmentSoftSamples, 480_000)
        XCTAssertEqual(ScribeLimits.quietRunSamples, 4_800)
        XCTAssertEqual(ScribeLimits.minCommitSamples, 5_600)
    }
}

final class FramerTests: XCTestCase {
    private func run(chunk: Int, total: Int) -> (frames: [[Int16]], rest: [Int16]) {
        var framer = PCMFramer()
        let audio = (0..<total).map { Int16(truncatingIfNeeded: $0 &* 7) }
        var frames: [[Int16]] = []
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunk, audio.count)
            frames += framer.append(ScribeWire.pcmBytes(Array(audio[offset..<end])))
            offset = end
        }
        return (frames, framer.takeRemainder())
    }

    func testFramesFromRenderSizedChunks() {
        for chunk in [170, 185, 512] {
            let total = 10_000
            let (frames, rest) = run(chunk: chunk, total: total)
            XCTAssertEqual(frames.count, total / 1_600, "chunk \(chunk)")
            XCTAssertTrue(frames.allSatisfy { $0.count == 1_600 })
            XCTAssertEqual(rest.count, total % 1_600)
            let joined = frames.flatMap { $0 } + rest
            XCTAssertEqual(joined, (0..<total).map { Int16(truncatingIfNeeded: $0 &* 7) }, "chunk \(chunk)")
        }
    }

    func testOddByteChunksReassemble() {
        var framer = PCMFramer(frameSamples: 4)
        let bytes = ScribeWire.pcmBytes([1, -2, 300, -32_768, 32_767])
        var frames: [[Int16]] = []
        for i in 0..<bytes.count {
            frames += framer.append(bytes.subdata(in: i..<(i + 1)))
        }
        XCTAssertEqual(frames, [[1, -2, 300, -32_768]])
        XCTAssertEqual(framer.takeRemainder(), [32_767])
        XCTAssertEqual(framer.receivedSamples, 5)
    }
}

final class LedgerTests: XCTestCase {
    func testJoinsNonEmptySegments() throws {
        var ledger = CommitLedger()
        ledger.recordCommitSent()
        ledger.recordCommitSent()
        ledger.recordCommitSent()
        _ = try ledger.on(.init(messageType: "committed_transcript", text: " first "))
        _ = try ledger.on(.init(messageType: "committed_transcript", text: ""))
        _ = try ledger.on(.init(messageType: "committed_transcript", text: "second"))
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.text, "first second")
    }

    func testThrottledCommitCountsAsAnswered() throws {
        var ledger = CommitLedger()
        ledger.recordCommitSent()
        XCTAssertFalse(ledger.isComplete)
        _ = try ledger.on(.init(messageType: "commit_throttled", error: "too little audio"))
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.throttledCommits, 1)
        XCTAssertEqual(ledger.text, "")
    }

    func testUnsolicitedCommitIsKeptButNotCounted() throws {
        var ledger = CommitLedger()
        _ = try ledger.on(.init(messageType: "committed_transcript", text: "auto"))
        XCTAssertEqual(ledger.unsolicitedCommits, 1)
        ledger.recordCommitSent()
        XCTAssertFalse(ledger.isComplete)
        _ = try ledger.on(.init(messageType: "committed_transcript", text: "tail"))
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.text, "auto tail")
    }

    func testTimestampsVariantAndPartialsAreNotSegments() throws {
        var ledger = CommitLedger()
        ledger.recordCommitSent()
        XCTAssertEqual(try ledger.on(.init(messageType: "partial_transcript", text: "p")), .partial("p"))
        XCTAssertEqual(try ledger.on(.init(messageType: "committed_transcript_with_timestamps", text: "dup")), .none)
        XCTAssertFalse(ledger.isComplete)
        XCTAssertEqual(ledger.segments, [])
        XCTAssertEqual(ledger.partials, 1)
    }

    func testServerErrorsAreClassified() {
        for type in ["auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request", "input_error",
            "chunk_size_exceeded"]
        {
            XCTAssertEqual(ScribeError.classify(messageType: type, detail: "x")?.isFatal, true, type)
        }
        for type in ["error", "transcriber_error", "rate_limited", "queue_overflow", "resource_exhausted",
            "session_time_limit_exceeded", "insufficient_audio_activity"]
        {
            XCTAssertEqual(ScribeError.classify(messageType: type, detail: "x")?.isFatal, false, type)
        }
        XCTAssertNil(ScribeError.classify(messageType: "partial_transcript", detail: ""))
        var ledger = CommitLedger()
        XCTAssertThrowsError(try ledger.on(.init(messageType: "quota_exceeded", error: "no credits"))) { error in
            XCTAssertEqual(error as? ScribeError, .fatal("quota_exceeded: no credits"))
        }
    }

    func testParsesErrorFromErrorOrMessageField() {
        XCTAssertEqual(
            ScribeServerMessage.parse(#"{"message_type":"auth_error","message":"bad key"}"#)?.error, "bad key")
        XCTAssertEqual(
            ScribeServerMessage.parse(#"{"message_type":"auth_error","error":"bad key"}"#)?.error, "bad key")
        XCTAssertNil(ScribeServerMessage.parse("not json"))
    }
}

final class KeytermTests: XCTestCase {
    func testFileListKeepsOrderAndAllFifty() throws {
        let file = "# sample list\n" + sampleKeyterms.joined(separator: "\n") + "\n\n"
        let parsed = try Keyterms.parse(file)
        let selection = Keyterms.limit(parsed)
        XCTAssertEqual(selection.terms, sampleKeyterms)
        XCTAssertEqual(selection.droppedCount, 0)
        XCTAssertEqual(selection.dropSummary, "")
    }

    func testSkipsLongTermsBadCharactersAndDuplicates() {
        let selection = Keyterms.limit([
            "Alpha", "alpha", "ABCDEFGHIJKLMNOPQRSTU", "ABCDEFGHIJKLMNOPQRST", "Ca[t]", "<b>", "back\\slash", " ",
            "Beta",
        ])
        XCTAssertEqual(selection.terms, ["Alpha", "ABCDEFGHIJKLMNOPQRST", "Beta"])
        XCTAssertEqual(selection.tooLong, ["ABCDEFGHIJKLMNOPQRSTU"])
        XCTAssertEqual(selection.unsupported, ["Ca[t]", "<b>", "back\\slash"])
        XCTAssertEqual(selection.duplicates, ["alpha"])
    }

    func testCharacterLimitCountsUnicodeScalars() {
        let cyrillic = String(repeating: "я", count: 20)
        XCTAssertEqual(Keyterms.limit([cyrillic]).terms, [cyrillic])
        XCTAssertEqual(Keyterms.limit([cyrillic + "я"]).tooLong.count, 1)
    }

    func testKeepsTheFirstFifty() {
        let selection = Keyterms.limit(sampleKeyterms + ["Extra1", "Extra2"])
        XCTAssertEqual(selection.terms, sampleKeyterms)
        XCTAssertEqual(selection.overLimit, ["Extra1", "Extra2"])
    }

    func testFileTermsComeFirst() {
        let selection = Keyterms.merge(fileTerms: ["Zeta", "Alpha"], otherTerms: ["alpha", "Beta"])
        XCTAssertEqual(selection.terms, ["Zeta", "Alpha", "Beta"])
    }

    func testJSONArrayFile() throws {
        XCTAssertEqual(try Keyterms.parse(#" ["T3 Code", "Hyprland"] "#), ["T3 Code", "Hyprland"])
        XCTAssertThrowsError(try Keyterms.parse("[1, 2]"))
    }

    func testLoadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyterms-\(UUID().uuidString).txt")
        try "One\n# comment\nTwo words\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Keyterms.load(path: url.path), ["One", "Two words"])
    }
}

final class URLTests: XCTestCase {
    private func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    func testAutoLanguageIsLeftOut() throws {
        for language in [nil, "", "auto", "AUTO"] {
            let url = try ScribeURL.build(endpoint: ScribeLimits.defaultEndpoint, language: language, keyterms: [])
            XCTAssertFalse(query(url).contains { $0.0 == "language_code" }, "\(String(describing: language))")
        }
    }

    func testCarriesSettingsLanguageAndFiftyKeyterms() throws {
        let url = try ScribeURL.build(
            endpoint: ScribeLimits.defaultEndpoint, language: "he", keyterms: ["T3 Code", "a+b"] + sampleKeyterms.dropLast(2))
        let items = query(url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
        XCTAssertTrue(items.contains { $0 == ("model_id", "scribe_v2_realtime") })
        XCTAssertTrue(items.contains { $0 == ("audio_format", "pcm_16000") })
        XCTAssertTrue(items.contains { $0 == ("commit_strategy", "manual") })
        XCTAssertTrue(items.contains { $0 == ("no_verbatim", "true") })
        XCTAssertTrue(items.contains { $0 == ("language_code", "he") })
        let keyterms = items.filter { $0.0 == "keyterms" }.map(\.1)
        XCTAssertEqual(keyterms.count, 50)
        XCTAssertEqual(Array(keyterms.prefix(2)), ["T3 Code", "a+b"])
        // Spaces and plus signs are percent-encoded, so the server cannot read "+" as a space.
        XCTAssertTrue(url.absoluteString.contains("keyterms=T3%20Code"))
        XCTAssertTrue(url.absoluteString.contains("keyterms=a%2Bb"))
        XCTAssertFalse(url.absoluteString.contains("xi-api-key"))
    }

    func testRejectsNonWebSocketEndpoints() {
        XCTAssertThrowsError(
            try ScribeURL.build(endpoint: URL(string: "https://api.elevenlabs.io/x")!, language: nil, keyterms: []))
    }
}

final class WireTests: XCTestCase {
    func testChunkMessageMatchesTheWireFormat() throws {
        let text = ScribeWire.chunkMessage(samples: [1, -1, 256], commit: true, previousText: "dictation \"q\"")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["commit"] as? Bool, true)
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(object["previous_text"] as? String, "dictation \"q\"")
        let audio = try XCTUnwrap(Data(base64Encoded: object["audio_base_64"] as? String ?? ""))
        XCTAssertEqual([UInt8](audio), [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x01])
        let plain = ScribeWire.chunkMessage(samples: [], commit: false)
        XCTAssertFalse(plain.contains("previous_text"))
        XCTAssertTrue(plain.contains(#""commit":false"#))
    }

    func testRMSOfSilenceAndTone() {
        XCTAssertEqual(scribeRMS(silence(0.1)), 0)
        XCTAssertGreaterThan(scribeRMS(tone(0.1)), ScribeLimits.quietRMS)
        XCTAssertEqual(scribeRMS([]), 0)
    }
}
