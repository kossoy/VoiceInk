import Foundation
import ScribeCore

/// `scribe-bench` options. Every run prints aggregate numbers only: no file
/// names, ids or transcript text, so the output is safe to paste anywhere.
public struct BenchOptions: Equatable, Sendable {
    public static let raycastRecordings = "~/Library/Application Support/com.raycast.macos/dictation-recordings"
    public static let defaultKeyterms = "~/.config/voiceink/keyterms.txt"

    public var recordings: String = raycastRecordings
    public var refs: String?
    public var keyterms: String?
    public var limit: Int?
    public var abCount = 10
    public var abRate = 48_000.0
    public var abBuffer = 512
    public var realtimeCount = 3
    public var language: String?
    /// Live model under test (`scribe_v3_live` by default) and the batch reference model.
    public var model = ScribeLimits.realtimeModel
    public var batchModel = ScribeModels.batchV2

    public init() {}

    public static let usage = """
        usage: scribe-bench [--recordings DIR] [--refs FILE] [--keyterms FILE] [--limit N]
                            [--ab N] [--ab-rate HZ] [--ab-buffer FRAMES] [--realtime N] [--language CODE]
                            [--model LIVE_ID] [--batch-model BATCH_ID]

        Streams every .wav/.m4a/.caf/.aiff/.mp3 in DIR (default: Raycast's dictation-recordings) through the
        VoiceInk OKLabs Scribe engine and prints aggregate WER, Latin-term retention,
        failures and stop-to-text latency. Needs ELEVENLABS_API_KEY in the environment.

          --refs FILE      JSONL with {"id": <file name without .wav>, "text"|"value"|"rawValue": ...};
                           without it the reference is batch scribe_v2 (agreement, not ground truth)
          --keyterms FILE  keyterms file (default ~/.config/voiceink/keyterms.txt when present)
          --ab N           resampler A/B on the first N recordings made at >= 32 kHz (default 10, 0 = off):
                           VoiceInk's capture resampler vs AVAudioConverter on a --ab-rate device
                           signal. Raycast's recordings are 16 kHz and cannot show aliasing; use
                           44.1/48 kHz recordings (e.g. QuickTime Player audio) in a separate --recordings run
          --realtime N     stream the first N files at 1x to measure live stop-to-text latency (default 3)
          --model ID       live model under test (default scribe_v3_live; scribe_v2_realtime for the old one)
          --batch-model ID batch model used as the reference without --refs (default scribe_v2)
        """

    public enum ParseError: Error, LocalizedError, Equatable {
        case unknown(String)
        case missingValue(String)
        case badValue(String, String)
        case help

        public var errorDescription: String? {
            switch self {
            case .unknown(let flag): return "unknown option \(flag)\n\(BenchOptions.usage)"
            case .missingValue(let flag): return "\(flag) needs a value"
            case .badValue(let flag, let value): return "\(flag): bad value \(value)"
            case .help: return BenchOptions.usage
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> BenchOptions {
        var options = BenchOptions()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw ParseError.missingValue(flag) }
            return next
        }
        func int(_ flag: String) throws -> Int {
            let raw = try value(flag)
            guard let parsed = Int(raw), parsed >= 0 else { throw ParseError.badValue(flag, raw) }
            return parsed
        }
        while let argument = iterator.next() {
            switch argument {
            case "--recordings": options.recordings = try value(argument)
            case "--refs": options.refs = try value(argument)
            case "--keyterms": options.keyterms = try value(argument)
            case "--limit": options.limit = try int(argument)
            case "--ab": options.abCount = try int(argument)
            case "--ab-rate":
                let raw = try value(argument)
                guard let rate = Double(raw), rate >= 8_000 else { throw ParseError.badValue(argument, raw) }
                options.abRate = rate
            case "--ab-buffer":
                let frames = try int(argument)
                guard frames > 0 else { throw ParseError.badValue(argument, String(frames)) }
                options.abBuffer = frames
            case "--realtime": options.realtimeCount = try int(argument)
            case "--language": options.language = try value(argument)
            case "--model": options.model = try value(argument)
            case "--batch-model": options.batchModel = try value(argument)
            case "-h", "--help": throw ParseError.help
            default: throw ParseError.unknown(argument)
            }
        }
        return options
    }
}

public enum BenchReferences {
    /// id → reference text. Accepts the benchmark's `ref_consensus.jsonl` and Raycast export rows.
    public static func parse(_ contents: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let id = object["id"] as? String
            else {
                continue
            }
            let text = (object["text"] as? String) ?? (object["value"] as? String) ?? (object["rawValue"] as? String)
            if let text { refs[id] = text }
        }
        return refs
    }
}

/// Aggregates for one engine configuration.
public struct BenchTally: Sendable {
    public var counts = Scoring.Counts()
    public var attempted = 0
    public var failed = 0
    public var latencies: [Double] = []

    public init() {}

    public mutating func add(reference: String, outcome: ScribeOutcome, latency: Double?) {
        attempted += 1
        switch outcome {
        case .text(let text):
            counts = counts + Scoring.score(reference: reference, hypothesis: text)
            if let latency { latencies.append(latency) }
        case .failed:
            failed += 1
        }
    }

    public func summary(includeLatency: Bool = true) -> String {
        var parts: [String] = []
        parts.append("WER \(Self.percent(counts.wer))")
        parts.append("Latin kept \(Self.percent(counts.latinKeptPercent))")
        parts.append("failed \(failed)/\(attempted)")
        if includeLatency, !latencies.isEmpty {
            parts.append(
                "stop->text p50 \(Self.seconds(Scoring.percentile(latencies, 0.5))) p95 \(Self.seconds(Scoring.percentile(latencies, 0.95)))"
            )
        }
        return parts.joined(separator: " | ")
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f%%", value)
    }

    public static func seconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f s", value)
    }
}
