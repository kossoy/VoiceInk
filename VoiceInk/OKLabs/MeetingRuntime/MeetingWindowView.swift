import AppKit
import SwiftUI

struct MeetingWindowView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var models: TranscriptionModelManager
    @State private var search = ""
    @StateObject private var windowDelegate = MeetingWindowDelegate()

    private var isCloud: Bool {
        guard let model = models.usableModels.first(where: { $0.selectionKey == meeting.selectedModelKey }) else { return false }
        return ![ModelProvider.whisper, .fluidAudio, .transcribeCpp, .nativeApple].contains(model.provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            transcript
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(WindowAccessor { window in
            windowDelegate.meeting = meeting
            window.delegate = windowDelegate
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Meeting Transcript", systemImage: "waveform")
                    .font(.title2.bold())
                Spacer()
                if meeting.isChangingCapture { ProgressView().controlSize(.small) }
                Text(meeting.session?.state.rawValue.capitalized ?? "Ready")
                    .foregroundStyle(meeting.session?.state == .recording ? .red : .secondary)
            }
            if meeting.canStart {
                TextField("Meeting title", text: $meeting.title)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Model", selection: $meeting.selectedModelKey) {
                        Text("Select a model").tag("")
                        ForEach(models.usableModels, id: \.selectionKey) { model in
                            Text("\(model.displayName) · \(model.provider.rawValue)").tag(model.selectionKey)
                        }
                    }
                    Button("Start Meeting") { Task { await meeting.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(meeting.selectedModelKey.isEmpty)
                }
                Text(isCloud
                    ? "Audio chunks will be sent to the selected provider for transcription. Provider charges may apply."
                    : "Transcription runs on this Mac with the selected local model.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(meeting.session?.title ?? "Meeting").font(.headline)
                HStack(spacing: 16) {
                    meter("Me · Microphone", level: meeting.microphoneLevel, seconds: meeting.microphoneSeconds)
                    meter("Others · System Audio", level: meeting.systemLevel, seconds: meeting.systemSeconds)
                    Spacer()
                    Button(meeting.session?.state == .paused ? "Resume" : "Pause") {
                        Task { await meeting.pauseOrResume() }
                    }.disabled(!meeting.hasOpenCapture || meeting.isChangingCapture)
                    Button("Stop", role: .destructive) { Task { await meeting.stop() } }
                        .disabled(!meeting.hasOpenCapture || meeting.isChangingCapture)
                }
            }
            Text("Captures the default microphone and audio from all other apps. Use headphones to keep voices separate. Audio and raw transcript are saved locally.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = meeting.message {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private func meter(_ title: String, level: Float, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            ProgressView(value: min(1, Double(level) * 8)).frame(width: 135)
            Text(seconds > 0 ? "Last audio at \(Int(seconds))s" : "Waiting for audio")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            TextField("Search transcript", text: $search)
                .textFieldStyle(.roundedBorder).padding(12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if meeting.session?.finalSegments.isEmpty != false {
                            ContentUnavailableView("Your meeting transcript appears here", systemImage: "text.bubble",
                                description: Text("Utterances appear after a short silence or approximately 12 seconds of speech. Microphone speech is labelled Me; audio from other apps is labelled Others."))
                                .padding(.top, 40)
                        }
                        ForEach((meeting.session?.finalSegments ?? []).filter {
                            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                        }) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(MeetingSpeakerResolver.label(for: segment, cues: meeting.session?.speakerCues ?? []))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(segment.source == .microphone ? .blue : .primary)
                                    Text(timestamp(segment.range.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            .id(segment.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: meeting.session?.finalSegments.count) { _, _ in
                    if search.isEmpty { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if meeting.isTranscribing { ProgressView().controlSize(.small) }
                Text("\(meeting.pendingCount) pending · \(meeting.failedCount) failed").font(.caption)
                Spacer()
                if meeting.failedCount + meeting.pendingCount > 0 && !meeting.isTranscribing {
                    Button("Retry") { meeting.retry() }.disabled(meeting.isChangingCapture)
                }
                Button("Copy") { meeting.copyTranscript() }.disabled(meeting.session == nil)
                Button("Export…") { meeting.export() }.disabled(meeting.session == nil)
                Button("Files") { meeting.showFiles() }.disabled(meeting.session == nil)
            }
            if let failure = meeting.jobs.first(where: { $0.state == .failed })?.error {
                Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Menu("Saved Meetings (\(meeting.savedMeetings.count))") {
                ForEach(meeting.savedMeetings) { session in
                    Button("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.title)") {
                        meeting.load(session)
                    }
                }
            }.disabled(!meeting.canStart)
        }
    }

    private func timestamp(_ value: TimeInterval) -> String {
        let seconds = Int(value)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct MeetingWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Meeting Transcript…") {
                AppPresentationPolicy.activateForUserFacingWindow()
                openWindow(id: AppWindowID.meeting)
            }
        }
    }
}

@MainActor
private final class MeetingWindowDelegate: NSObject, ObservableObject, NSWindowDelegate {
    weak var meeting: MeetingCoordinator?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let meeting, meeting.hasOpenCapture || meeting.isChangingCapture else { return true }
        guard !meeting.isChangingCapture else { return false }
        let alert = NSAlert()
        alert.messageText = "Stop this meeting before closing?"
        alert.informativeText = "The saved audio queue will finish transcribing in the background."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop and Close")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        Task { await meeting.stop(); sender.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed()
    }
}
