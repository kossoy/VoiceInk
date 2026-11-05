import AppKit
import AVFoundation
import Combine
import CoreGraphics
#if SWIFT_PACKAGE
import MeetingCore
#endif

@MainActor
struct MeetingPermissionClient {
    var microphoneStatus: () -> AVAuthorizationStatus
    var systemAudioAllowed: () -> Bool
    var requestMicrophone: () async -> Bool
    var requestSystemAudio: () -> Bool
    var openURL: (URL) -> Void

    static var live: MeetingPermissionClient {
        MeetingPermissionClient(
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            systemAudioAllowed: { CGPreflightScreenCaptureAccess() },
            requestMicrophone: { await AVCaptureDevice.requestAccess(for: .audio) },
            requestSystemAudio: { CGRequestScreenCaptureAccess() },
            openURL: { NSWorkspace.shared.open($0) })
    }
}

@MainActor
final class MeetingPermissions: ObservableObject {
    enum Kind { case microphone, systemAudio }
    @Published private(set) var snapshot: MeetingPermissionSnapshot
    @Published private(set) var requesting: Kind?
    private let defaults: UserDefaults
    private let client: MeetingPermissionClient
    private static let requestedSystemAudioKey = "oklabs.meeting.requestedSystemAudio"

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VoiceInk"
    }

    init(defaults: UserDefaults = .standard, client: MeetingPermissionClient? = nil) {
        self.defaults = defaults
        let client = client ?? .live
        self.client = client
        snapshot = Self.readSnapshot(defaults: defaults, client: client)
    }

    func refresh() {
        let current = Self.readSnapshot(defaults: defaults, client: client)
        if current != snapshot { snapshot = current }
    }

    func allow(_ kind: Kind) async {
        guard requesting == nil else { return }
        requesting = kind
        defer { requesting = nil; refresh() }
        refresh()
        switch kind {
        case .microphone:
            switch snapshot.microphone {
            case .notRequested: _ = await client.requestMicrophone()
            case .denied: openSettings(kind)
            case .restricted, .allowed: break
            }
        case .systemAudio:
            if snapshot.systemAudio == .notRequested {
                defaults.set(true, forKey: Self.requestedSystemAudioKey)
                // User initiated. Never request recording access from the meeting detector.
                _ = client.requestSystemAudio()
            } else if !snapshot.systemAudio.isAllowed {
                openSettings(kind)
            }
        }
    }

    func openSettings(_ kind: Kind) {
        let pane = kind == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        client.openURL(url)
    }

    private static func readSnapshot(defaults: UserDefaults, client: MeetingPermissionClient) -> MeetingPermissionSnapshot {
        let mic: MeetingPermissionState
        switch client.microphoneStatus() {
        case .authorized: mic = .allowed
        case .notDetermined: mic = .notRequested
        case .denied: mic = .denied
        case .restricted: mic = .restricted
        @unknown default: mic = .denied
        }
        let system: MeetingPermissionState = client.systemAudioAllowed() ? .allowed
            : (defaults.bool(forKey: requestedSystemAudioKey) ? .denied : .notRequested)
        return MeetingPermissionSnapshot(microphone: mic, systemAudio: system)
    }
}
