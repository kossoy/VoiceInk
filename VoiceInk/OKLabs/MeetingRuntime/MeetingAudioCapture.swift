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
    case voiceProcessing(String)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "Allow microphone access in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermission: return "Allow Screen & System Audio Recording access in Meeting settings, then reopen this app if macOS asks."
        case .noDisplay: return "No display is available for system audio capture."
        case .invalidAudio: return "The audio device returned an unsupported audio buffer."
        case .conversion(let message): return "Audio conversion failed: \(message)"
        case .voiceProcessing(let message): return "Could not start echo-cancelled microphone capture: \(message)"
        case .invalidState: return "Meeting audio capture is not ready for this operation."
        }
    }
}

/// The hardware boundary also lets lifecycle tests run without opening audio devices.
@MainActor
protocol MeetingCaptureDevices: AnyObject {
    func startMicrophone(_ receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                         onFailure: @escaping @Sendable (String) -> Void) throws
    func stopMicrophone()
    func startSystem() async throws
    func stopSystem() async throws
}

@available(macOS 15.0, *)
@MainActor
private final class MeetingNativeCaptureDevices: MeetingCaptureDevices {
    private let stream: SCStream
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    init(stream: SCStream) { self.stream = stream }

    func startMicrophone(_ receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                         onFailure: @escaping @Sendable (String) -> Void) throws {
        // A fresh engine on resume avoids retaining a device format or an old input tap.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled else {
                throw MeetingCaptureError.voiceProcessing("Voice processing is unavailable on this audio route.")
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MeetingCaptureError.invalidAudio
            }
            // Both I/O nodes remain in hardware voice-processing mode. Do not connect
            // the microphone to the output or replay the system audio through this engine.
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: receive)
            self.engine = engine
            engine.prepare()
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { _ in
                // A device/format change can stop the engine without stopping SCStream.
                // Finish visibly instead of silently recording only remote participants.
                onFailure("The microphone audio route changed. Start a new recording to resume echo-cancelled capture.")
            }
        } catch {
            engine.stop()
            if self.engine != nil { input.removeTap(onBus: 0) }
            self.engine = nil
            throw MeetingCaptureError.voiceProcessing(error.localizedDescription)
        }
    }

    func stopMicrophone() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    func startSystem() async throws { try await stream.startCapture() }
    func stopSystem() async throws { try await stream.stopCapture() }
}

/// SCStream supplies system audio; AVAudioEngine supplies the processed microphone.
/// Both use the host clock. No raw-microphone fallback is permitted.
/// All sample state is owned by sampleQueue. No video output is registered or saved.
@available(macOS 15.0, *)
final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The copy is handed off once and then accessed only on sampleQueue.
    private struct OwnedMicrophoneBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

    var onChunk: (@MainActor @Sendable (MeetingAudioChunk) -> Void)?
    var onLevel: (@Sendable (MeetingAudioSource, Float, TimeInterval) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    /// Optional local probe tap, invoked on sampleQueue. The app leaves this unset.
    /// Continuous PCM is needed to measure AEC independently of the chunker's energy gate.
    var onSamples: (@Sendable (MeetingAudioSource, [Int16], TimeInterval) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.oklabs.voiceink.meeting.audio", qos: .userInitiated)
    private var devices: (any MeetingCaptureDevices)?
    private enum State { case stopped, starting, running, stopping }
    @MainActor private var state: State = .stopped
    private var generation = UUID()
    private var origin: TimeInterval = 0
    private var accepting = false
    private var captureActive = false
    private var firstFailure: String?
    private var minimumTime: TimeInterval = 0
    private var lastEnd: TimeInterval = 0
    private var lastMeterTimes: [MeetingAudioSource: TimeInterval] = [:]
    private var chunkers: [MeetingAudioSource: MeetingAudioChunker] = [:]
    private var converters: [MeetingAudioSource: AVAudioConverter] = [:]
    private var delivery: Task<Void, Never>?

    static var hostTime: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    override init() { super.init() }

    @MainActor
    init(devices: any MeetingCaptureDevices) {
        self.devices = devices
        super.init()
    }

    @MainActor
    func prepare() async throws {
        guard state == .stopped else { throw MeetingCaptureError.invalidState }
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
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = MeetingAudioChunker.sampleRate
        configuration.channelCount = 1
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.devices = MeetingNativeCaptureDevices(stream: stream)
    }

    @MainActor
    func start(origin: TimeInterval, from minimumTime: TimeInterval) async throws {
        guard let devices, state == .stopped else { throw MeetingCaptureError.invalidState }
        state = .starting
        let generation = UUID()
        sampleQueue.sync {
            self.generation = generation
            self.origin = origin
            self.minimumTime = minimumTime
            self.lastEnd = minimumTime
            self.accepting = false
            self.captureActive = true
            self.firstFailure = nil
            self.chunkers = [.microphone: MeetingAudioChunker(source: .microphone), .system: MeetingAudioChunker(source: .system)]
            self.converters.removeAll()
            self.lastMeterTimes.removeAll()
        }
        do {
            try devices.startMicrophone({ [weak self] buffer, time in
                guard let self else { return }
                // A tap's buffer is borrowed. Own the samples before handing them to
                // sampleQueue, where conversion, metering and chunking take place.
                do {
                    let timestamp = try Self.microphoneHostTime(time)
                    let owned = OwnedMicrophoneBuffer(value: try Self.copy(buffer))
                    self.sampleQueue.async {
                        guard self.accepting, self.generation == generation else { return }
                        do {
                            try self.consume(self.convert(owned.value, source: .microphone),
                                             source: .microphone, timestamp: timestamp - self.origin)
                        } catch { self.fail(error) }
                    }
                } catch {
                    self.sampleQueue.async {
                        guard self.captureActive, self.generation == generation else { return }
                        self.fail(error)
                    }
                }
            }, onFailure: { [weak self] message in
                guard let self else { return }
                self.sampleQueue.async {
                    guard self.captureActive, self.generation == generation else { return }
                    self.fail(MeetingCaptureError.voiceProcessing(message))
                }
            })
            try await devices.startSystem()
            let startupFailure = sampleQueue.sync {
                if firstFailure == nil { accepting = true }
                return firstFailure
            }
            if let startupFailure { throw MeetingCaptureError.voiceProcessing(startupFailure) }
            state = .running
        } catch {
            sampleQueue.sync { accepting = false; captureActive = false }
            devices.stopMicrophone()
            try? await devices.stopSystem()
            state = .stopped
            throw error
        }
    }

    /// Stop both devices, drain queued samples, then flush the trailing utterance.
    /// Return the final audio boundary so a late ASR result stays inside recorded time.
    @MainActor
    func stop() async -> (end: TimeInterval, error: String?) {
        guard let devices, state == .running else {
            return (sampleQueue.sync { lastEnd }, nil)
        }
        state = .stopping
        var failure: String?
        devices.stopMicrophone()
        do { try await devices.stopSystem() } catch { failure = error.localizedDescription }
        let now = Self.hostTime
        let drained = await withCheckedContinuation { (continuation: CheckedContinuation<(TimeInterval, Task<Void, Never>?), Never>) in
            sampleQueue.async {
                self.accepting = false
                self.captureActive = false
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
        state = .stopped
        return (max(0, drained.0), failure)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard type == .audio else { return }
        do {
            let timestamp = sampleBuffer.presentationTimeStamp.seconds - origin
            try consume(convert(sampleBuffer, source: .system), source: .system, timestamp: timestamp)
        } catch { fail(error) }
    }

    private func consume(_ input: [Int16], source: MeetingAudioSource, timestamp: TimeInterval) throws {
        guard timestamp.isFinite else { throw MeetingCaptureError.invalidAudio }
        var pcm = input
        let trimCount = max(0, ceil((minimumTime - timestamp) * Double(MeetingAudioChunker.sampleRate)))
        guard trimCount < Double(pcm.count) else { return }
        let trim = Int(trimCount)
        if trim > 0 { pcm.removeFirst(trim) }
        let start = max(minimumTime, timestamp + Double(trim) / Double(MeetingAudioChunker.sampleRate))
        onSamples?(source, pcm, start)
        lastEnd = max(lastEnd, start + Double(pcm.count) / Double(MeetingAudioChunker.sampleRate))
        if start - (lastMeterTimes[source] ?? -.infinity) > 0.15 {
            lastMeterTimes[source] = start
            let energy = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
            onLevel?(source, Float(sqrt(energy / Double(pcm.count)) / 32768), lastEnd)
        }
        for chunk in try chunkers[source]?.append(pcm, at: start) ?? [] { deliver(chunk) }
    }

    private func fail(_ error: Error) {
        guard captureActive, firstFailure == nil else { return }
        firstFailure = error.localizedDescription
        let shouldNotify = accepting
        accepting = false
        if shouldNotify { onFailure?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { self.fail(error) }
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

    static func microphoneHostTime(_ time: AVAudioTime) throws -> TimeInterval {
        guard time.isHostTimeValid else { throw MeetingCaptureError.invalidAudio }
        return AVAudioTime.seconds(forHostTime: time.hostTime)
    }

    static func copy(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            throw MeetingCaptureError.invalidAudio
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let bytes = Int(input.frameLength) * Int(input.format.streamDescription.pointee.mBytesPerFrame)
        guard source.count == destination.count else { throw MeetingCaptureError.invalidAudio }
        for index in source.indices {
            guard source[index].mDataByteSize >= bytes, destination[index].mDataByteSize >= bytes,
                  let from = source[index].mData, let to = destination[index].mData else {
                throw MeetingCaptureError.invalidAudio
            }
            memcpy(to, from, bytes)
        }
        return copy
    }

    // Internal to allow format conversion tests without accessing any audio device.
    func convert(_ sample: CMSampleBuffer, source: MeetingAudioSource) throws -> [Int16] {
        guard let description = sample.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { throw MeetingCaptureError.invalidAudio }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList)
        guard status == noErr else { throw MeetingCaptureError.invalidAudio }
        return try convert(input, source: source)
    }

    func convert(_ input: AVAudioPCMBuffer, source: MeetingAudioSource) throws -> [Int16] {
        let format = input.format
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw MeetingCaptureError.invalidAudio }
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
