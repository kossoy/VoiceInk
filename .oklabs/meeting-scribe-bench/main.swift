import AVFoundation
import Foundation
import MeetingCore
import ScribeCore

// Measures the optional ElevenLabs Scribe v3 refinement on a saved meeting, outside the app,
// with the same MeetingCore/ScribeCore code the app runs:
//   swift run meeting-scribe-bench <meeting-session-dir> <fluid-turns.json>
// <fluid-turns.json>: the local result on the stitched timeline, from
//   DIARIZATION_BENCH_TURNS=<file> swift run --package-path .oklabs/diarization-bench diarization-bench <dir>
// Stitches the system chunks like MeetingDiarizer (0.5 s gaps, session order), sends them once
// to scribe_v3 (diarize=true), and prints aggregate counts only: no names, no transcript text.
// Needs ELEVENLABS_API_KEY. Reads the session; writes nothing into it.
struct Job: Decodable {
    let id: UUID
    let source: String
    let range: Range

    struct Range: Decodable {
        let start: Double
        let end: Double
    }
}

struct FluidTurn: Decodable {
    let speaker: String
    let start: Double
    let end: Double
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] else {
    print("usage: ELEVENLABS_API_KEY=… meeting-scribe-bench <meeting-session-dir> <fluid-turns.json>")
    exit(64)
}
let dir = URL(fileURLWithPath: arguments[1])
let audio = dir.appendingPathComponent("audio")
let decoder = JSONDecoder()
let session = try decoder.decode(MeetingSession.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
let jobs = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .map { try decoder.decode(Job.self, from: Data(contentsOf: $0)) }
    .filter { $0.source == "system" }.sorted { $0.range.start < $1.range.start }

// Stitch exactly like MeetingDiarizer.stitch.
let stitched = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-scribe-bench-\(UUID().uuidString).wav")
defer { try? FileManager.default.removeItem(at: stitched) }
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let file = try AVAudioFile(
    forWriting: stitched,
    settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
silence.frameLength = 8_000
var map = MeetingStitchMap()
for job in jobs {
    let input = try AVAudioFile(forReading: audio.appendingPathComponent("\(job.id.uuidString).wav"))
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
    try input.read(into: buffer)
    guard input.processingFormat.sampleRate == 16_000, buffer.frameLength > 0 else { continue }
    try file.write(from: buffer)
    try file.write(from: silence)
    map.append(sessionStart: job.range.start, duration: Double(buffer.frameLength) / 16_000, gap: 0.5)
}

let fluid = try decoder.decode([FluidTurn].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
var localTurns: [MeetingSpeakerTurn] = []
for turn in fluid {
    for range in map.sessionRanges(stitchedStart: turn.start, stitchedEnd: turn.end) {
        localTurns.append(MeetingSpeakerTurn(clusterID: turn.speaker, range: range))
    }
}
let local = MeetingDiarization(
    engine: "fluidaudio-offline-vbx", audioSeconds: map.pieces.reduce(0) { $0 + $1.duration }, processingSeconds: 0,
    turns: localTurns)

let started = Date()
let words = try await ScribeDiarizationRequest(apiKey: apiKey).run(audio: stitched)
let elapsed = Date().timeIntervalSince(started)
var mapped: [MeetingSpeakerWord] = []
for word in words {
    guard let range = map.sessionRanges(stitchedStart: word.start, stitchedEnd: max(word.end, word.start + 0.01)).first
    else { continue }
    mapped.append(MeetingSpeakerWord(speakerID: word.speakerID, range: range, text: word.text))
}
let scribe = MeetingScribeDiarization(audioSecondsSent: map.stitchedDuration, processingSeconds: elapsed, words: mapped)

let before = MeetingSpeakerLabeler(session: session, diarization: local)
let after = MeetingSpeakerLabeler(session: session, diarization: local, scribe: scribe)
let lines = session.finalSegments.filter { $0.source == .system }
let labelledBefore = lines.filter { before.clusterID(for: $0) != nil }.count
let labelledAfter = lines.filter { after.clusterID(for: $0) != nil }.count
let changed = lines.filter { before.clusterID(for: $0) != nil && before.clusterID(for: $0) != after.clusterID(for: $0) }.count
let split = lines.filter { after.parts(for: $0) != nil }
let partCount = split.reduce(0) { $0 + (after.parts(for: $1)?.count ?? 0) }
let speakerMap = after.refiner?.speakerMap ?? [:]
print(String(format: "stitched %.1f s (%.1f min billed), %d chunks; scribe_v3 diarization %.1f s, %d words, %d speakers",
    map.stitchedDuration, map.stitchedDuration / 60, map.pieces.count, elapsed, mapped.count,
    Set(mapped.map(\.speakerID)).count))
print("local clusters \(Set(localTurns.map(\.clusterID)).count); cloud speakers mapped \(speakerMap.count) of \(Set(mapped.map(\.speakerID)).count)")
print("system lines \(lines.count): with a voice before \(labelledBefore), after \(labelledAfter); local voice changed \(changed)")
print("lines split between two voices \(split.count) (\(partCount) parts)")
for line in split {
    let parts = after.parts(for: line) ?? []
    let shape = parts.map { "\($0.clusterID ?? "-"):\($0.text.split(separator: " ").count)w" }.joined(separator: " | ")
    print(String(format: "  split at %.0f s (%.1f s line, local voice %@): %@", line.range.start,
        line.range.end - line.range.start, before.clusterID(for: line) ?? "none", shape))
}
