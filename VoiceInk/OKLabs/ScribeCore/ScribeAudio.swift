import Foundation

/// Collects variable-size PCM16 LE render chunks into fixed-size frames.
public struct PCMFramer: Sendable {
    public let frameSamples: Int
    private var pending: [Int16] = []
    private var oddByte: UInt8?
    public private(set) var receivedSamples = 0

    public init(frameSamples: Int = ScribeLimits.liveFrameSamples) {
        precondition(frameSamples > 0)
        self.frameSamples = frameSamples
    }

    /// Samples waiting for a full frame.
    public var pendingCount: Int { pending.count }

    /// Appends raw little-endian PCM16 bytes and returns every complete frame.
    public mutating func append(_ data: Data) -> [[Int16]] {
        guard !data.isEmpty else { return [] }
        var bytes = [UInt8](data)
        if let odd = oddByte {
            bytes.insert(odd, at: 0)
            oddByte = nil
        }
        if bytes.count % 2 == 1 {
            oddByte = bytes.removeLast()
        }
        let count = bytes.count / 2
        pending.reserveCapacity(pending.count + count)
        var i = 0
        while i + 1 < bytes.count {
            pending.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)))
            i += 2
        }
        receivedSamples += count
        return drainFrames()
    }

    /// Appends samples directly (tests, uploads) and returns every complete frame.
    public mutating func append(samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        receivedSamples += samples.count
        return drainFrames()
    }

    /// The samples that never filled a frame. The framer is empty afterwards.
    public mutating func takeRemainder() -> [Int16] {
        let rest = pending
        pending = []
        oddByte = nil
        return rest
    }

    private mutating func drainFrames() -> [[Int16]] {
        guard pending.count >= frameSamples else { return [] }
        var frames: [[Int16]] = []
        var offset = 0
        while pending.count - offset >= frameSamples {
            frames.append(Array(pending[offset..<(offset + frameSamples)]))
            offset += frameSamples
        }
        pending.removeFirst(offset)
        return frames
    }
}

/// Root mean square of a PCM16 frame, normalised to [0, 1] like voxtype (`/ i16::MAX`).
public func scribeRMS(_ frame: [Int16]) -> Double {
    guard !frame.isEmpty else { return 0 }
    var sum = 0.0
    for sample in frame {
        let v = Double(sample) / Double(Int16.max)
        sum += v * v
    }
    return (sum / Double(frame.count)).squareRoot()
}

/// Decides where to commit mid-stream so no segment reaches the server's automatic commit.
public struct Segmenter: Equatable, Sendable {
    public init() {}

    public private(set) var uncommitted = 0
    public private(set) var quietRun = 0

    /// Account for a frame about to be sent; true if it should carry a commit.
    public mutating func push(_ frame: [Int16]) -> Bool {
        uncommitted += frame.count
        if scribeRMS(frame) < ScribeLimits.quietRMS {
            quietRun += frame.count
        } else {
            quietRun = 0
        }
        let quietPoint =
            uncommitted >= ScribeLimits.segmentSoftSamples && quietRun >= ScribeLimits.quietRunSamples
        if quietPoint || uncommitted >= ScribeLimits.segmentHardSamples {
            reset()
            return true
        }
        return false
    }

    public mutating func reset() {
        uncommitted = 0
        quietRun = 0
    }
}
