import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit
#if SWIFT_PACKAGE
import MeetingCore
#endif

enum MeetingCaptureError: LocalizedError {
    case microphonePermission
    case systemAudioPermission
    case noDisplay
    case invalidAudio
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "Allow microphone access in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermission: return "Allow Screen & System Audio Recording access in Meeting settings, then reopen this app if macOS asks."
        case .noDisplay: return "No display is available for system audio capture."
        case .invalidAudio: return "The audio device returned an unsupported audio buffer."
        case .conversion(let message): return "Audio conversion failed: \(message)"
        }
    }
}

/// SCStream supplies independent microphone and system buffers on the host clock.
/// All sample state is owned by sampleQueue. No video output is registered or saved.
@available(macOS 15.0, *)
final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onChunk: (@MainActor @Sendable (MeetingAudioChunk) -> Void)?
    var onLevel: (@Sendable (MeetingAudioSource, Float, TimeInterval) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.oklabs.voiceink.meeting.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var origin: TimeInterval = 0
    private var accepting = false
    private var minimumTime: TimeInterval = 0
    private var lastEnd: TimeInterval = 0
    private var lastMeterTimes: [MeetingAudioSource: TimeInterval] = [:]
    private var chunkers: [MeetingAudioSource: MeetingAudioChunker] = [:]
    private var converters: [MeetingAudioSource: AVAudioConverter] = [:]
    private var delivery: Task<Void, Never>?

    static var hostTime: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    @MainActor
    func prepare() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw MeetingCaptureError.microphonePermission }
        guard CGPreflightScreenCaptureAccess() else { throw MeetingCaptureError.systemAudioPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = MeetingAudioChunker.sampleRate
        configuration.channelCount = 1
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        self.stream = stream
    }

    @MainActor
    func start(origin: TimeInterval, from minimumTime: TimeInterval) async throws {
        guard let stream else { throw MeetingCaptureError.noDisplay }
        sampleQueue.sync {
            self.origin = origin
            self.minimumTime = minimumTime
            self.lastEnd = minimumTime
            self.accepting = true
            self.chunkers = [.microphone: MeetingAudioChunker(source: .microphone), .system: MeetingAudioChunker(source: .system)]
            self.converters.removeAll()
            self.lastMeterTimes.removeAll()
        }
        do {
            try await stream.startCapture()
        } catch {
            sampleQueue.sync { accepting = false }
            throw error
        }
    }

    /// Stop both devices, drain queued samples, then flush the trailing utterance.
    /// Return the final audio boundary so a late ASR result stays inside recorded time.
    @MainActor
    func stop() async -> (end: TimeInterval, error: String?) {
        var failure: String?
        do { try await stream?.stopCapture() } catch { failure = error.localizedDescription }
        let now = Self.hostTime
        let drained = await withCheckedContinuation { (continuation: CheckedContinuation<(TimeInterval, Task<Void, Never>?), Never>) in
            sampleQueue.async {
                self.accepting = false
                for source in [MeetingAudioSource.microphone, .system] {
                    do {
                        if let chunk = try self.chunkers[source]?.flush() { self.deliver(chunk) }
                    } catch { self.onFailure?(error.localizedDescription) }
                }
                self.converters.removeAll()
                continuation.resume(returning: (max(self.lastEnd, now - self.origin), self.delivery))
            }
        }
        await drained.1?.value
        return (max(0, drained.0), failure)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let source: MeetingAudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        do {
            let timestamp = sampleBuffer.presentationTimeStamp.seconds - origin
            guard timestamp.isFinite else { throw MeetingCaptureError.invalidAudio }
            var pcm = try convert(sampleBuffer, source: source)
            let trim = max(0, Int(ceil((minimumTime - timestamp) * Double(MeetingAudioChunker.sampleRate))))
            guard trim < pcm.count else { return }
            if trim > 0 { pcm.removeFirst(trim) }
            let start = max(minimumTime, timestamp + Double(trim) / Double(MeetingAudioChunker.sampleRate))
            lastEnd = max(lastEnd, start + Double(pcm.count) / Double(MeetingAudioChunker.sampleRate))
            if start - (lastMeterTimes[source] ?? -.infinity) > 0.15 {
                lastMeterTimes[source] = start
                let energy = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
                onLevel?(source, Float(sqrt(energy / Double(pcm.count)) / 32768), lastEnd)
            }
            for chunk in try chunkers[source]?.append(pcm, at: start) ?? [] { deliver(chunk) }
        } catch {
            accepting = false
            onFailure?(error.localizedDescription)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    private func deliver(_ chunk: MeetingAudioChunk) {
        lastEnd = max(lastEnd, chunk.range.end)
        let previous = delivery
        let callback = onChunk
        delivery = Task { @MainActor in
            await previous?.value
            callback?(chunk)
        }
    }

    // Internal to allow format conversion tests without accessing any audio device.
    func convert(_ sample: CMSampleBuffer, source: MeetingAudioSource) throws -> [Int16] {
        guard let description = sample.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw MeetingCaptureError.invalidAudio }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList)
        guard status == noErr else { throw MeetingCaptureError.invalidAudio }
        if converters[source]?.inputFormat != format {
            converters[source] = AVAudioConverter(from: format, to: target)
            converters[source]?.primeMethod = .none
        }
        guard let converter = converters[source],
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
        else { throw MeetingCaptureError.invalidAudio }
        var cursor: AVAudioFrameCount = 0
        var pcm: [Int16] = []
        while true {
            let previousCursor = cursor
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { requested, status in
                guard cursor < input.frameLength else { status.pointee = .noDataNow; return nil }
                // Supplying more than requested silently discards frames in AVAudioConverter.
                let count = min(AVAudioFrameCount(requested), input.frameLength - cursor)
                guard count > 0, let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    status.pointee = .noDataNow
                    return nil
                }
                slice.frameLength = count
                let original = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                for index in 0..<original.count {
                    guard let from = original[index].mData, let to = destination[index].mData else { continue }
                    memcpy(to, from.advanced(by: Int(cursor) * bytesPerFrame), Int(count) * bytesPerFrame)
                }
                cursor += count
                status.pointee = .haveData
                return slice
            }
            guard result != .error, error == nil, let channel = output.floatChannelData?[0] else {
                throw MeetingCaptureError.conversion(error?.localizedDescription ?? "Unknown format")
            }
            pcm.append(contentsOf: (0..<Int(output.frameLength)).map {
                let value = channel[$0].isFinite ? channel[$0] : 0
                return Int16(max(-32768, min(32767, value * 32767)))
            })
            if result == .inputRanDry || result == .endOfStream { break }
            guard output.frameLength > 0 || cursor > previousCursor else {
                throw MeetingCaptureError.conversion("The audio converter made no progress.")
            }
        }
        return pcm
    }
}
