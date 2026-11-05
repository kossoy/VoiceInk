import AppKit
import CoreAudio
#if SWIFT_PACKAGE
import MeetingCore
#endif

enum MeetingAudioActivityError: Error {
    case coreAudio(OSStatus)
    case malformedProcessList
}

/// Reads audio IO metadata only. Does not create a tap, open a device, read Teams
/// text, record sound, or request microphone/Screen Recording/Accessibility access.
@available(macOS 14.2, *)
public struct TeamsAudioActivityReader {
    public init() {}

    public static func isTeamsBundle(_ id: String) -> Bool {
        ["com.microsoft.teams2", "com.microsoft.teams"].contains {
            id == $0 || id.hasPrefix($0 + ".")
        }
    }

    public func read() throws -> MeetingAppActivity {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw MeetingAudioActivityError.coreAudio(status) }
        guard size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else {
            throw MeetingAudioActivityError.malformedProcessList
        }
        guard size > 0 else { return MeetingAppActivity(inputActive: false, outputActive: false, processCount: 0) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        status = objects.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw MeetingAudioActivityError.coreAudio(status) }
        // Processes can disappear between listing and reading. Ignore disappearing objects.
        var input = false
        var output = false
        var count = 0
        for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride) {
            let bundle = bundleID(for: object) ?? ""
            let pid: pid_t? = scalar(object, kAudioProcessPropertyPID, initial: pid_t(0))
            let runningBundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? ""
            guard Self.isTeamsBundle(bundle) || Self.isTeamsBundle(runningBundle) else { continue }
            let runningInput: UInt32? = scalar(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))
            let runningOutput: UInt32? = scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))
            guard let runningInput, let runningOutput else { continue }
            count += 1
            input = input || runningInput != 0
            output = output || runningOutput != 0
        }
        return MeetingAppActivity(inputActive: input, outputActive: output, processCount: count)
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = property(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    private func bundleID(for object: AudioObjectID) -> String? {
        var address = property(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
