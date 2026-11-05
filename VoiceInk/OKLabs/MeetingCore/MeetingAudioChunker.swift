import Foundation

public struct MeetingAudioChunk: Sendable {
    public let source: MeetingAudioSource
    public let range: MeetingTimeRange
    public let samples: [Int16]
}

/// A bounded energy gate, not speaker diarization. One instance per audio source.
/// Input is mono PCM at 16 kHz, with timestamps from the capture host clock.
public struct MeetingAudioChunker {
    public static let sampleRate = 16_000
    private let source: MeetingAudioSource
    private let maximumSamples: Int
    private var samples: [Int16] = []
    private var start: TimeInterval = 0
    private var lastEnd: TimeInterval?
    private var voicedSamples = 0
    private var silentSamples = 0

    public init(source: MeetingAudioSource, maximumSeconds: TimeInterval = 12) {
        self.source = source
        self.maximumSamples = Int(max(1, min(60, maximumSeconds)) * Double(Self.sampleRate))
    }

    public mutating func append(_ input: [Int16], at timestamp: TimeInterval) throws -> [MeetingAudioChunk] {
        guard timestamp.isFinite, timestamp >= 0 else { throw MeetingSessionError.invalidTime }
        guard !input.isEmpty else { return [] }
        var output: [MeetingAudioChunk] = []
        // Never join audio across a pause, dropped packets or device format change.
        if let lastEnd, abs(timestamp - lastEnd) > 0.1 {
            if let chunk = try flush() { output.append(chunk) }
        }
        let rate = Double(Self.sampleRate)
        var offset = 0
        while offset < input.count {
            let end = min(input.count, offset + 320, offset + maximumSamples - samples.count)
            let frame = input[offset..<end]
            if samples.isEmpty { start = timestamp + Double(offset) / rate }
            samples.append(contentsOf: frame)
            let energy = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count)
            if energy > 180 * 180 {
                voicedSamples += frame.count
                silentSamples = 0
            } else {
                silentSamples += frame.count
            }
            offset = end
            if samples.count >= maximumSamples || (voicedSamples > 0 && silentSamples >= 11_200) {
                if let chunk = try flush() { output.append(chunk) }
            } else if voicedSamples == 0 && samples.count > 3_200 {
                // Keep 200 ms of pre-roll without retaining an unbounded silent call.
                let removed = samples.count - 3_200
                samples.removeFirst(removed)
                start += Double(removed) / rate
            }
        }
        lastEnd = timestamp + Double(input.count) / rate
        return output
    }

    public mutating func flush() throws -> MeetingAudioChunk? {
        defer {
            samples.removeAll(keepingCapacity: true)
            voicedSamples = 0
            silentSamples = 0
            lastEnd = nil
        }
        guard voicedSamples >= 1_600, !samples.isEmpty else { return nil }
        return MeetingAudioChunk(
            source: source,
            range: try MeetingTimeRange(start: start, end: start + Double(samples.count) / Double(Self.sampleRate)),
            samples: samples)
    }
}

public enum MeetingWAV {
    /// Canonical 44-byte PCM header, compatible with the app's local Whisper reader.
    public static func encode(_ samples: [Int16]) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        integer(UInt32(36 + samples.count * 2))
        ascii("WAVEfmt ")
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(MeetingAudioChunker.sampleRate))
        integer(UInt32(MeetingAudioChunker.sampleRate * 2))
        integer(UInt16(2))
        integer(UInt16(16))
        ascii("data")
        integer(UInt32(samples.count * 2))
        for sample in samples { integer(sample) }
        return data
    }
}
