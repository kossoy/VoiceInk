import AppKit
import SwiftUI

struct MeetingPermissionView: View {
    @ObservedObject var permissions: MeetingPermissions
    let expanded: Bool

    var body: some View {
        if !permissions.snapshot.isReady || expanded {
            VStack(alignment: .leading, spacing: 10) {
                Text(permissions.snapshot.isReady ? "Recording access is ready" : "Allow access before your first meeting")
                    .font(.headline)
                row("Microphone", subtitle: "Your voice", state: permissions.snapshot.microphone, kind: .microphone)
                row("Screen & System Audio Recording", subtitle: "Voices from Teams and other apps",
                    state: permissions.snapshot.systemAudio, kind: .systemAudio)
                if !permissions.snapshot.isReady {
                    Text("Choose Allow in the macOS prompt, or enable \(MeetingPermissions.appName) in System Settings. If macOS asks you to quit and reopen, reopen this same app.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Check Again") { permissions.refresh() }.font(.caption)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(_ title: String, subtitle: String, state: MeetingPermissionState, kind: MeetingPermissions.Kind) -> some View {
        HStack {
            Image(systemName: state.isAllowed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(state.isAllowed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if permissions.requesting == kind {
                ProgressView().controlSize(.small)
            } else if state.isAllowed {
                Text("Allowed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(state.actionTitle) { Task { await permissions.allow(kind) } }
                    .disabled(state == .restricted || permissions.requesting != nil)
            }
        }
    }
}

struct MeetingStartButton: View {
    @ObservedObject var permissions: MeetingPermissions
    let hasModel: Bool
    let action: () -> Void

    var body: some View {
        Button("Start Meeting", action: action)
            .buttonStyle(.borderedProminent)
            .disabled(!hasModel || !permissions.snapshot.isReady || permissions.requesting != nil)
            .help(permissions.snapshot.isReady ? "Record microphone and system audio" : "Allow recording access above first")
    }
}
