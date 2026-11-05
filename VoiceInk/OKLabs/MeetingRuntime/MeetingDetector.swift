import AppKit
import Combine
import SwiftUI

@MainActor
final class MeetingDetector: ObservableObject {
    private static let enabledKey = "oklabs.meeting.detectTeams"
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                _ = policy.observe(nil, at: ProcessInfo.processInfo.systemUptime, enabled: false)
                dismissBanner()
            }
        }
    }
    @Published private(set) var status = "Waiting for Teams audio"
    private let defaults: UserDefaults
    private var policy = MeetingDetectionPolicy()
    private var timer: Timer?
    private var dismissalTimer: Timer?
    private var panel: NSPanel?
    private var sampleInFlight = false
    private var onOpen: (() -> Void)?
    private var isBusy: (() -> Bool)?
    private var settingsHandler: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start(onOpen: @escaping () -> Void, onSettings: @escaping () -> Void, isBusy: @escaping () -> Bool) {
        self.onOpen = onOpen
        self.settingsHandler = onSettings
        self.isBusy = isBusy
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func recordingDidStart() { dismissBanner() }

    private func sample() {
        guard isEnabled, !sampleInFlight else { return }
        if isBusy?() == true { dismissBanner() }
        sampleInFlight = true
        Task { [weak self] in
            let activity = await Task.detached(priority: .utility) { () -> MeetingAppActivity? in
                try? TeamsAudioActivityReader().read()
            }.value
            guard let self else { return }
            self.sampleInFlight = false
            guard self.isEnabled else { return }
            if let activity {
                self.status = activity.hasCallAudio ? "Teams call audio active" : "Waiting for Teams audio"
            } else {
                self.status = "Teams audio detection unavailable"
            }
            let event = self.policy.observe(activity, at: ProcessInfo.processInfo.systemUptime,
                                           recording: self.isBusy?() == true)
            switch event {
            case .detected: self.showBanner()
            case .ended: self.dismissBanner()
            case nil: break
            }
        }
    }

    private func showBanner() {
        guard panel == nil, isBusy?() != true, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 82),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let content = MeetingDetectedBanner(
            onTakeNotes: { [weak self] in
                self?.dismissBanner()
                self?.onOpen?()
            },
            onDismiss: { [weak self] in self?.dismissBanner() },
            onDisable: { [weak self] in self?.isEnabled = false },
            onSettings: { [weak self] in
                self?.dismissBanner()
                self?.settingsHandler?()
            })
        panel.contentView = NSHostingView(rootView: content)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - 456, y: frame.maxY - 98))
        self.panel = panel
        panel.orderFrontRegardless()
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissBanner() }
        }
    }

    private func dismissBanner() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        panel?.close()
        panel = nil
    }
}

private struct MeetingDetectedBanner: View {
    let onTakeNotes: () -> Void
    let onDismiss: () -> Void
    let onDisable: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.fill").font(.title2).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting detected").font(.headline)
                Text("Microsoft Teams").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button(action: onTakeNotes) { Label("Take notes", systemImage: "waveform") }
                    .buttonStyle(.borderedProminent)
                    .help("Open Meeting Transcript")
                Menu {
                    Button("Turn off notifications for Microsoft Teams", action: onDisable)
                    Divider()
                    Button("Meeting Detection Settings…", action: onSettings)
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize().padding(.leading, 8)
            }
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss meeting notification")
        }
        .padding(16)
        .frame(width: 440, height: 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
}

struct MeetingDetectionBridge: View {
    @Environment(\.openWindow) private var openWindow
    let meeting: MeetingCoordinator

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            meeting.detector.start(onOpen: openMeeting, onSettings: {
                meeting.showSetup = true
                openMeeting()
            }, isBusy: { meeting.hasOpenCapture || meeting.isChangingCapture || meeting.isTranscribing })
        }
    }

    private func openMeeting() {
        AppPresentationPolicy.activateForUserFacingWindow()
        openWindow(id: AppWindowID.meeting)
    }
}

struct MeetingDetectionSettingsView: View {
    @ObservedObject var detector: MeetingDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Detect Microsoft Teams meetings", isOn: $detector.isEnabled)
            Text("Show a Take notes reminder when Teams uses call audio.")
                .font(.caption).foregroundStyle(.secondary)
            if detector.isEnabled { Text(detector.status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
