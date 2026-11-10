import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingCapture
import MeetingCore

@available(macOS 15, *)
final class MeetingCaptureTests: XCTestCase {
    private func pcm(rate: Double = 16_000, channels: AVAudioChannelCount = 1,
                     seconds: Double = 1, value: Float = 0.25, capacityMultiplier: Int = 1) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(rate * seconds)
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames * AVAudioFrameCount(capacityMultiplier)))
        result.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { result.floatChannelData![channel][frame] = value }
        }
        return result
    }

    private func buffer(rate: Double, channels: AVAudioChannelCount, seconds: Double, value: Float) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(pcm.frameLength) { pcm.floatChannelData![channel][frame] = value }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                       presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 48_000),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }

    func testNativeStereoMicrophoneResamplesTo16KMono() throws {
        let capture = MeetingAudioCapture()
        let sample = try buffer(rate: 48_000, channels: 2, seconds: 1, value: 0.25)
        let pcm = try capture.convert(sample, source: .microphone)
        XCTAssertEqual(pcm.count, 16_000, accuracy: 64)
        XCTAssertEqual(Double(pcm.dropFirst(100).reduce(0.0) { $0 + Double($1) }) / Double(pcm.count - 100), 8192, accuracy: 10)
    }

    func testConversionStateIsSeparateForMicrophoneAndSystem() throws {
        let capture = MeetingAudioCapture()
        let microphone = try capture.convert(try buffer(rate: 44_100, channels: 1, seconds: 0.5, value: 0.4), source: .microphone)
        let system = try capture.convert(try buffer(rate: 16_000, channels: 1, seconds: 0.5, value: -0.4), source: .system)
        XCTAssertEqual(microphone.count, 8_000, accuracy: 64)
        XCTAssertEqual(system.count, 8_000, accuracy: 64)
        XCTAssertTrue(microphone.dropFirst(100).allSatisfy { $0 > 10_000 })
        XCTAssertTrue(system.allSatisfy { $0 < -10_000 })
    }

    func testSmallDevicePacketsDoNotAccumulateResamplingLoss() throws {
        let capture = MeetingAudioCapture()
        var count = 0
        for _ in 0..<100 {
            count += try capture.convert(
                buffer(rate: 48_000, channels: 1, seconds: 0.02, value: 0.2), source: .microphone).count
        }
        XCTAssertEqual(count, 32_000, accuracy: 64)
    }

    func testProcessedMicrophoneBufferRetainsDurationAtNativeDeviceRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for channels in [AVAudioChannelCount(1), 2] {
                let converted = try MeetingAudioCapture().convert(
                    pcm(rate: rate, channels: channels), source: .microphone)
                XCTAssertEqual(converted.count, 16_000, accuracy: 64)
                XCTAssertTrue(converted.dropFirst(100).allSatisfy { abs(Int($0) - 8192) < 20 })
            }
        }
    }

    func testTapCopyOwnsOnlyValidFramesBeforeBorrowedBufferIsReused() throws {
        let input = try pcm(rate: 48_000, channels: 2, seconds: 0.02, capacityMultiplier: 4)
        // Some audio producers expose the whole allocation in the buffer list.
        let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        for index in buffers.indices { buffers[index].mDataByteSize = input.frameCapacity * 4 }
        let owned = try MeetingAudioCapture.copy(input)
        input.floatChannelData![0][0] = -0.9
        XCTAssertEqual(owned.frameLength, 960)
        XCTAssertEqual(owned.frameCapacity, 960)
        XCTAssertEqual(owned.floatChannelData![0][0], 0.25)
        XCTAssertEqual(owned.floatChannelData![1][959], 0.25)
    }

    func testMicrophoneTimestampUsesHostClockAndRejectsSampleOnlyTime() throws {
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 123.25))
        XCTAssertEqual(try MeetingAudioCapture.microphoneHostTime(time), 123.25, accuracy: 0.000001)
        XCTAssertThrowsError(try MeetingAudioCapture.microphoneHostTime(AVAudioTime(sampleTime: 42, atRate: 48_000)))
    }

    @MainActor
    func testFailedSystemStartStopsBothDevicesAndAllowsRetry() async throws {
        let devices = FakeMeetingCaptureDevices()
        devices.failSystemStart = true
        let capture = MeetingAudioCapture(devices: devices)
        do {
            try await capture.start(origin: 0, from: 0)
            XCTFail("Startup should fail")
        } catch {}
        XCTAssertEqual(devices.events, ["start microphone", "start system", "stop microphone", "stop system"])
        devices.failSystemStart = false
        try await capture.start(origin: 0, from: 0)
        _ = await capture.stop()
        XCTAssertEqual(devices.events.suffix(4), ["start microphone", "start system", "stop microphone", "stop system"])
    }

    @MainActor
    func testFailedVoiceProcessingNeverStartsSystemOrFallsBackToRawMicrophone() async throws {
        let devices = FakeMeetingCaptureDevices()
        devices.failMicrophoneStart = true
        let capture = MeetingAudioCapture(devices: devices)
        do {
            try await capture.start(origin: 0, from: 0)
            XCTFail("Startup should fail")
        } catch {}
        XCTAssertEqual(devices.events, ["start microphone", "stop microphone", "stop system"])
    }

    @MainActor
    func testRouteFailureDuringSystemStartupDoesNotLeaveCaptureRunning() async throws {
        let devices = FakeMeetingCaptureDevices()
        devices.systemStartupFailureNotice = "Route changed during start"
        let capture = MeetingAudioCapture(devices: devices)
        do {
            try await capture.start(origin: 0, from: 0)
            XCTFail("Startup should fail when the microphone stops")
        } catch {}
        XCTAssertEqual(devices.events, ["start microphone", "start system", "stop microphone", "stop system"])
    }

    @MainActor
    func testSystemStopFailureStillDrainsTrailingMicrophoneSpeech() async throws {
        let devices = FakeMeetingCaptureDevices()
        devices.failSystemStop = true
        let capture = MeetingAudioCapture(devices: devices)
        var chunks: [MeetingAudioChunk] = []
        capture.onChunk = { chunks.append($0) }
        try await capture.start(origin: 0, from: 0)
        devices.receivers[0](try pcm(), AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1)))
        let result = await capture.stop()
        XCTAssertNotNil(result.error)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 16_000)
    }

    @MainActor
    func testPauseDrainsOnceAndResumeRejectsOldTapAndTrimsPreResumeSamples() async throws {
        let devices = FakeMeetingCaptureDevices()
        let capture = MeetingAudioCapture(devices: devices)
        var chunks: [MeetingAudioChunk] = []
        capture.onChunk = { chunks.append($0) }
        try await capture.start(origin: 100, from: 0)
        devices.receivers[0](try pcm(), AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 101)))
        _ = await capture.stop()
        _ = await capture.stop()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(devices.events.filter { $0 == "stop microphone" }.count, 1)
        try await capture.start(origin: 100, from: 10)
        // A late callback from the previous input tap must not enter the new recording.
        devices.receivers[0](try pcm(), AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 111)))
        devices.receivers[1](try pcm(), AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 109.5)))
        _ = await capture.stop()
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[1].source, .microphone)
        XCTAssertEqual(chunks[1].range.start, 10, accuracy: 0.0001)
        XCTAssertEqual(chunks[1].samples.count, 8_000, accuracy: 64)
    }

    @MainActor
    func testInvalidMicClockReportsFailureAndDoesNotCreateMisdatedChunk() async throws {
        let devices = FakeMeetingCaptureDevices()
        let capture = MeetingAudioCapture(devices: devices)
        let failure = expectation(description: "Invalid host clock reported")
        var chunks: [MeetingAudioChunk] = []
        capture.onChunk = { chunks.append($0) }
        capture.onFailure = { _ in failure.fulfill() }
        try await capture.start(origin: 0, from: 0)
        devices.receivers[0](try pcm(), AVAudioTime(sampleTime: 0, atRate: 16_000))
        await fulfillment(of: [failure], timeout: 1)
        _ = await capture.stop()
        XCTAssertTrue(chunks.isEmpty)
    }

    @MainActor
    func testRouteFailureIsReportedOnceAndStopsAcceptingMicrophoneAudio() async throws {
        let devices = FakeMeetingCaptureDevices()
        let capture = MeetingAudioCapture(devices: devices)
        let failure = expectation(description: "Device change reported")
        failure.assertForOverFulfill = true
        var chunks: [MeetingAudioChunk] = []
        capture.onChunk = { chunks.append($0) }
        capture.onFailure = { _ in failure.fulfill() }
        try await capture.start(origin: 0, from: 0)
        devices.failure?("Route changed")
        devices.failure?("Route changed again")
        devices.receivers[0](try pcm(), AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1)))
        await fulfillment(of: [failure], timeout: 1)
        _ = await capture.stop()
        XCTAssertTrue(chunks.isEmpty)
    }
}

@MainActor
private final class FakeMeetingCaptureDevices: MeetingCaptureDevices {
    var events: [String] = []
    var receivers: [@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void] = []
    var failure: (@Sendable (String) -> Void)?
    var failMicrophoneStart = false
    var failSystemStart = false
    var failSystemStop = false
    var systemStartupFailureNotice: String?

    func startMicrophone(_ receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                         onFailure: @escaping @Sendable (String) -> Void) throws {
        events.append("start microphone")
        if failMicrophoneStart { throw MeetingCaptureError.voiceProcessing("Unavailable") }
        receivers.append(receive)
        failure = onFailure
    }

    func stopMicrophone() { events.append("stop microphone") }
    func startSystem() async throws {
        events.append("start system")
        if let systemStartupFailureNotice { failure?(systemStartupFailureNotice) }
        if failSystemStart { throw MeetingCaptureError.noDisplay }
    }
    func stopSystem() async throws {
        events.append("stop system")
        if failSystemStop { throw MeetingCaptureError.noDisplay }
    }
}
