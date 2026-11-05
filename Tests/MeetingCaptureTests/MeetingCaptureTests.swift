import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingCapture
import MeetingCore

@available(macOS 15, *)
final class MeetingCaptureTests: XCTestCase {
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
}
