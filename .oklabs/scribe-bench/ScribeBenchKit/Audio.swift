import AVFoundation
import Foundation

public enum BenchAudioError: Error, LocalizedError {
    case unreadable(String)
    case converter(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "audio unreadable: \(detail)"
        case .converter(let detail): return "audio conversion failed: \(detail)"
        }
    }
}

/// Audio helpers for the harness: load a recording, resample it, and reproduce
/// VoiceInk's capture resampler (`CoreAudioRecorder.convertAndWriteToFile`) for the A/B.
public enum BenchAudio {
    /// Mono Float32 samples at the file's own rate.
    public static func loadMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw BenchAudioError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        let count = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { throw BenchAudioError.unreadable("no float data") }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let pointer = data[channel]
            for i in 0..<count { mono[i] += pointer[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<count { mono[i] *= scale }
        }
        return (mono, format.sampleRate)
    }

    /// High-quality AVAudioConverter resampling of a whole signal.
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        if inputRate == outputRate || samples.isEmpty { return samples }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw BenchAudioError.converter("cannot create converter \(inputRate) -> \(outputRate)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * outputRate / inputRate) + 4_096
        var result: [Float] = []
        result.reserveCapacity(Int(capacity))
        var supplied = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw BenchAudioError.converter("cannot allocate output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw BenchAudioError.converter(conversionError?.localizedDescription ?? "unknown")
            }
            if output.frameLength > 0, let data = output.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { break }
        }
        return result
    }

    /// Float [-1, 1] → Int16 with rounding and clipping.
    public static func pcm16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(max(-32_768, min(32_767, ($0 * 32_767).rounded()))) }
    }

    /// Exact copy of VoiceInk's capture path for a non-16 kHz device: per render
    /// buffer, linear interpolation without an anti-alias filter, fractional output
    /// frames truncated, `Int16(clipped)` truncating toward zero
    /// (`CoreAudioRecorder.swift` `convertAndWriteToFile`, upstream 19546d2a).
    public static func voiceInkCaptureResample(
        _ input: [Float], inputRate: Double, outputRate: Double = 16_000, bufferFrames: Int = 512
    ) -> [Int16] {
        let ratio = outputRate / inputRate
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(input.count) * ratio) + 1)
        var offset = 0
        while offset < input.count {
            let frameCount = min(bufferFrames, input.count - offset)
            let outputFrameCount = Int(UInt32(Double(frameCount) * ratio))
            if inputRate == outputRate {
                for i in 0..<frameCount {
                    let scaled = input[offset + i] * 32_767.0
                    output.append(Int16(max(-32_768.0, min(32_767.0, scaled))))
                }
            } else if outputFrameCount > 0 {
                for i in 0..<outputFrameCount {
                    let inputIndex = Double(i) / ratio
                    let inputIndexInt = Int(inputIndex)
                    let frac = Float(inputIndex - Double(inputIndexInt))
                    let idx1 = min(inputIndexInt, frameCount - 1)
                    let idx2 = min(inputIndexInt + 1, frameCount - 1)
                    let s1 = input[offset + idx1]
                    let s2 = input[offset + idx2]
                    let sample = s1 + frac * (s2 - s1)
                    let scaled = sample * 32_767.0
                    output.append(Int16(max(-32_768.0, min(32_767.0, scaled))))
                }
            }
            offset += frameCount
        }
        return output
    }

    /// 16 kHz mono PCM16 WAV bytes (for the batch upload).
    public static func wav16k(_ samples: [Int16]) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(16_000)
        append32(32_000)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(payload)
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
