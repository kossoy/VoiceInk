import AVFoundation
import FluidAudio
import Foundation

// Stitches the session's system-audio chunks like MeetingDiarizer (0.5 s gaps), diarizes them
// and prints speed, per-speaker time and the first system lines with their dominant voice.
guard CommandLine.arguments.count > 1 else {
    print("usage: diarization-bench <meeting-session-dir> [maxSpeakers]"); exit(64)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
struct Job: Decodable { let id: UUID; let source: String; let range: R }
struct R: Decodable { let start: Double; let end: Double }
struct Session: Decodable { let segments: [Seg] }
struct Seg: Decodable { let source: String; let range: R; let text: String }

func read(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url)
    guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
    try f.read(into: b)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}

let audio = dir.appendingPathComponent("audio")
let jobs = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .map { try JSONDecoder().decode(Job.self, from: Data(contentsOf: $0)) }
    .filter { $0.source == "system" }.sorted { $0.range.start < $1.range.start }
var samples: [Float] = []
var map: [(stitched: Double, session: Double, duration: Double)] = []
let gap = [Float](repeating: 0, count: 8_000)
for job in jobs {
    let s = try read(audio.appendingPathComponent("\(job.id.uuidString).wav"))
    map.append((Double(samples.count) / 16_000, job.range.start, Double(s.count) / 16_000))
    samples += s
    samples += gap
}
print(String(format: "system chunks %d, stitched %.1f s", jobs.count, Double(samples.count) / 16_000))
var config = OfflineDiarizerConfig.default
if CommandLine.arguments.count > 2 { config.clustering.maxSpeakers = Int(CommandLine.arguments[2]) }
let manager = OfflineDiarizerManager(config: config)
var t = Date()
try await manager.prepareModels()
print(String(format: "models ready in %.1f s", Date().timeIntervalSince(t)))
t = Date()
let result = try await manager.process(audio: samples)
let elapsed = Date().timeIntervalSince(t)
print(String(format: "diarized in %.1f s (%.0fx realtime), %d turns", elapsed, Double(samples.count) / 16_000 / elapsed, result.segments.count))
var perSpeaker: [String: Double] = [:]
var turns: [(id: String, start: Double, end: Double)] = []
for s in result.segments {
    perSpeaker[s.speakerId, default: 0] += Double(s.durationSeconds)
    for p in map {
        let a = max(Double(s.startTimeSeconds), p.stitched), b = min(Double(s.endTimeSeconds), p.stitched + p.duration)
        if b > a { turns.append((s.speakerId, p.session + a - p.stitched, p.session + b - p.stitched)) }
    }
}
for (k, v) in perSpeaker.sorted(by: { $0.value > $1.value }) { print(String(format: "  %@: %.1f s", k, v)) }
let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
var unassigned = 0, lines = 0
for seg in session.segments where seg.source == "system" {
    lines += 1
    var overlap: [String: Double] = [:]
    for turn in turns {
        let o = min(seg.range.end, turn.end) - max(seg.range.start, turn.start)
        if o > 0 { overlap[turn.id, default: 0] += o }
    }
    let best = overlap.max { $0.value < $1.value }
    let label = best.map { $0.value >= 0.25 * (seg.range.end - seg.range.start) ? $0.key : "-" } ?? "-"
    if label == "-" { unassigned += 1 }
    if lines <= 40 {
        print(String(format: "%02d:%02d %@ %@", Int(seg.range.start) / 60, Int(seg.range.start) % 60, label,
            String(seg.text.prefix(90))))
    }
}
print("system lines \(lines), without a dominant voice \(unassigned)")
