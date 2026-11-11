import Foundation
import ScribeBenchKit
import ScribeCore

/// Real-voice check of the VoiceInk OKLabs Scribe engine on the user's own Mac.
/// Prints aggregate numbers only (see `BenchOptions.usage`).
@main
struct ScribeBench {
    static func main() async {
        do {
            let options = try BenchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch BenchOptions.ParseError.help {
            print(BenchOptions.usage)
        } catch {
            FileHandle.standardError.write(Data("scribe-bench: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func progress(_ text: String) {
        FileHandle.standardError.write(Data("\r\(text)".utf8))
    }

    static func run(_ options: BenchOptions) async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty
        else {
            throw ScribeError.fatal("set ELEVENLABS_API_KEY")
        }

        let folder = URL(fileURLWithPath: expand(options.recordings), isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let audioExtensions: Set<String> = ["wav", "m4a", "caf", "aif", "aiff", "mp3"]
        var files = entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }

        var refs: [String: String] = [:]
        if let refsPath = options.refs {
            refs = BenchReferences.parse(try String(contentsOfFile: expand(refsPath), encoding: .utf8))
            files = files.filter { refs[$0.deletingPathExtension().lastPathComponent] != nil }
        }
        if let limit = options.limit { files = Array(files.prefix(limit)) }
        guard !files.isEmpty else { throw ScribeError.fatal("no .wav recordings to score in \(folder.path)") }

        var keyterms: [String] = []
        let keytermsPath = options.keyterms ?? BenchOptions.defaultKeyterms
        if FileManager.default.fileExists(atPath: expand(keytermsPath)) {
            keyterms = Keyterms.limit(try Keyterms.load(path: keytermsPath)).terms
        } else if options.keyterms != nil {
            throw ScribeError.fatal("keyterms file not found")
        }

        var live = LiveScribe(apiKey: apiKey, keyterms: keyterms)
        live.language = options.language
        live.model = options.model
        var batch = BatchScribe(apiKey: apiKey, keyterms: keyterms)
        batch.model = options.batchModel

        var upload = BenchTally()
        var realtime = BenchTally()
        var abControl = BenchTally()
        var abLinear = BenchTally()
        var abConverter = BenchTally()
        var audioSeconds = 0.0
        var skipped = 0
        var abSkippedLowRate = 0

        for (index, file) in files.enumerated() {
            progress("scribe-bench: \(index + 1)/\(files.count)")
            let loaded: (samples: [Float], sampleRate: Double)
            do {
                loaded = try BenchAudio.loadMono(file)
            } catch {
                skipped += 1
                continue
            }
            let mono16k = try BenchAudio.resample(loaded.samples, from: loaded.sampleRate, to: 16_000)
            let pcm = BenchAudio.pcm16(mono16k)
            guard !pcm.isEmpty else {
                skipped += 1
                continue
            }

            let reference: String
            if let known = refs[file.deletingPathExtension().lastPathComponent] {
                reference = known
            } else {
                do {
                    reference = try await batch.transcribe(pcm)
                } catch let error as ScribeError where error.isFatal {
                    throw error
                } catch {
                    skipped += 1
                    continue
                }
            }
            audioSeconds += Double(pcm.count) / 16_000

            let result = try await checked { try await live.run(pcm, realtime: false) }
            upload.add(reference: reference, outcome: result.outcome, latency: result.stopToResult)

            if abLinear.attempted < options.abCount && loaded.sampleRate < 32_000 {
                abSkippedLowRate += 1
            } else if abLinear.attempted < options.abCount {
                // The A/B needs content above 8 kHz, which VoiceInk's unfiltered resampler
                // folds into the speech band: build the device signal from the source at its
                // own rate, then run each 16 kHz capture path into the same engine.
                let device = try BenchAudio.resample(loaded.samples, from: loaded.sampleRate, to: options.abRate)
                let linear = BenchAudio.voiceInkCaptureResample(
                    device, inputRate: options.abRate, bufferFrames: options.abBuffer)
                let converter = BenchAudio.pcm16(try BenchAudio.resample(device, from: options.abRate, to: 16_000))
                abControl.add(reference: reference, outcome: result.outcome, latency: nil)
                let linearResult = try await checked { try await live.run(linear, realtime: false) }
                abLinear.add(reference: reference, outcome: linearResult.outcome, latency: nil)
                let converterResult = try await checked { try await live.run(converter, realtime: false) }
                abConverter.add(reference: reference, outcome: converterResult.outcome, latency: nil)
            }

            if index < options.realtimeCount {
                progress("scribe-bench: \(index + 1)/\(files.count) (1x)")
                let paced = try await checked { try await live.run(pcm, realtime: true) }
                realtime.add(reference: reference, outcome: paced.outcome, latency: paced.stopToResult)
            }
        }
        progress("")

        let referenceKind =
            options.refs == nil ? "batch \(options.batchModel) (agreement, not ground truth)" : "--refs file"
        print("")
        print(
            "scribe-bench: \(upload.attempted) recordings, \(String(format: "%.1f", audioSeconds / 60)) min audio, \(keyterms.count) keyterms, skipped \(skipped), reference = \(referenceKind)"
        )
        print("live engine, upload speed: \(upload.summary())")
        if realtime.attempted > 0 {
            print("live engine, 1x (\(realtime.attempted) files): \(realtime.summary())")
        }
        if abSkippedLowRate > 0 && abLinear.attempted == 0 {
            print(
                "resampler A/B: skipped, the recordings are below 32 kHz (\(abSkippedLowRate) files); aliasing can only be measured on recordings made at 44.1/48 kHz"
            )
        } else if abSkippedLowRate > 0 {
            print("resampler A/B: \(abSkippedLowRate) files below 32 kHz left out")
        }
        if abLinear.attempted > 0 {
            print(
                "resampler A/B (\(abLinear.attempted) files, \(Int(options.abRate)) Hz device, \(options.abBuffer)-frame buffers):"
            )
            print("  16 kHz original:        \(abControl.summary(includeLatency: false))")
            print("  VoiceInk linear (app):  \(abLinear.summary(includeLatency: false))")
            print("  AVAudioConverter:       \(abConverter.summary(includeLatency: false))")
            if let linear = abLinear.counts.wer, let converter = abConverter.counts.wer {
                let delta = linear - converter
                let verdict =
                    delta > 0.5
                    ? "VoiceInk's resampler loses more than 0.5 pp: switch the capture path to AVAudioConverter"
                    : "difference within 0.5 pp: keep VoiceInk's resampler"
                print(String(format: "  delta %+.1f pp -> %@", delta, verdict))
            }
        }
    }

    /// Fatal errors (bad key, quota) stop the run; anything else is a failed sample.
    static func checked(_ body: () async throws -> LiveScribe.Result) async throws -> LiveScribe.Result {
        do {
            let result = try await body()
            if case .failed(let error) = result.outcome, error.isFatal { throw error }
            return result
        } catch let error as ScribeError where !error.isFatal {
            return LiveScribe.Result(outcome: .failed(error), stopToResult: 0, stats: ScribeSessionStats())
        }
    }
}
