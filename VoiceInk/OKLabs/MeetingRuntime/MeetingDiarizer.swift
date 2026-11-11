import AVFoundation
import FluidAudio
import Foundation

/// Separates the voices in a finished meeting's system-audio track ("Others") on this Mac.
///
/// Runs FluidAudio's offline pipeline (pyannote segmentation, WeSpeaker embeddings, PLDA, VBx
/// clustering) over all saved system-audio chunks stitched into one buffer, then maps every
/// turn back to the session clock. Nothing leaves the Mac except the one-time model download
/// (Hugging Face, into FluidAudio's model cache next to the ASR models). Voice embeddings are
/// discarded; only cluster IDs and times are kept (diarization.json).
///
/// Requires the FluidAudio `Diarizer` package trait (project.pbxproj, FluidAudio `traits`).
actor MeetingDiarizer {
    static let engine = "fluidaudio-offline-vbx"
    /// Silence between stitched chunks, so the segmenter sees a boundary without long gaps.
    static let gapSeconds: TimeInterval = 0.5
    /// Below this much system speech there is nothing worth separating.
    static let minimumAudioSeconds: TimeInterval = 5

    struct Chunk: Sendable {
        let range: MeetingTimeRange
        let url: URL
    }

    enum Failure: LocalizedError {
        case notEnoughAudio(TimeInterval)
        var errorDescription: String? {
            switch self {
            case .notEnoughAudio(let seconds):
                return String(format: "Only %.1f s of audio from other apps; nothing to separate.", seconds)
            }
        }
    }

    private var manager: OfflineDiarizerManager?
    private static let sampleRate = 16_000

    /// - Parameter chunks: system-audio chunks of one session, in any order.
    func diarize(_ chunks: [Chunk]) async throws -> MeetingDiarization {
        let started = Date()
        // Stitch into a temporary 16-bit WAV instead of memory: a 3 h meeting is ~700 MB as
        // Float samples. FluidAudio reads the file memory-mapped.
        let stitched = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-diarization-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stitched) }
        let map = try Self.stitch(chunks, into: stitched)
        let audioSeconds = map.pieces.reduce(0) { $0 + $1.duration }
        guard audioSeconds >= Self.minimumAudioSeconds else { throw Failure.notEnoughAudio(audioSeconds) }

        let manager = try await preparedManager()
        let result = try await manager.process(stitched)
        var turns: [MeetingSpeakerTurn] = []
        for segment in result.segments {
            for range in map.sessionRanges(
                stitchedStart: TimeInterval(segment.startTimeSeconds),
                stitchedEnd: TimeInterval(segment.endTimeSeconds))
            {
                turns.append(MeetingSpeakerTurn(clusterID: segment.speakerId, range: range))
            }
        }
        return MeetingDiarization(
            engine: Self.engine, audioSeconds: audioSeconds,
            processingSeconds: Date().timeIntervalSince(started), turns: turns)
    }

    /// Writes the chunks in session order with `gapSeconds` of silence between them.
    /// Unreadable chunks are skipped; the map only contains what was written.
    static func stitch(_ chunks: [Chunk], into url: URL) throws -> MeetingStitchMap {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
        else { throw Failure.notEnoughAudio(0) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let gapFrames = AVAudioFrameCount(gapSeconds * Double(sampleRate))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: gapFrames) else { return MeetingStitchMap() }
        silence.frameLength = gapFrames  // zero-filled
        var map = MeetingStitchMap()
        for chunk in chunks.sorted(by: { $0.range.start < $1.range.start }) {
            guard let samples = try? readMono16k(chunk.url), !samples.isEmpty,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
            try file.write(from: silence)
            map.append(
                sessionStart: chunk.range.start, duration: Double(samples.count) / Double(sampleRate), gap: gapSeconds)
        }
        return map
    }

    private func preparedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let manager = OfflineDiarizerManager(config: .default)
        // Downloads once into FluidAudio's model cache, then loads from disk.
        try await manager.prepareModels()
        self.manager = manager
        return manager
    }

    /// Meeting chunks are 16 kHz mono PCM (MeetingWAV); convert anything else defensively.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        if input.sampleRate == Double(sampleRate), input.channelCount == 1, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output),
            let converted = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * Double(sampleRate) / input.sampleRate) + 1024)
        else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let data = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
    }
}
