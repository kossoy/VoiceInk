import AppKit
import SwiftUI

struct MeetingWindowView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var models: TranscriptionModelManager
    @State private var search = ""
    @State private var rename: RenameTarget?
    @State private var renameText = ""

    /// What the rename alert edits: every line of a voice, or one line.
    private enum RenameTarget: Equatable {
        case cluster(String, current: String)
        case line(UUID, current: String)
    }
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
        .onAppear { meeting.permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            meeting.permissions.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            meeting.permissions.refresh()
        }
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
                Button { meeting.showSetup.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Recording Access & Meeting Detection")
            }
            MeetingPermissionView(permissions: meeting.permissions, expanded: meeting.showSetup)
            if meeting.showSetup {
                MeetingDetectionSettingsView(detector: meeting.detector)
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
                    MeetingStartButton(permissions: meeting.permissions, hasModel: !meeting.selectedModelKey.isEmpty) {
                        Task { await meeting.start() }
                    }
                }
                Text(isCloud
                    ? "Cloud transcription · Audio is sent to the selected provider."
                    : "Local transcription · Audio stays on this Mac.")
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
            Text("Microphone + audio from other apps · Saved on this Mac · Headphones recommended")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = meeting.message {
                Text(message).font(.callout)
                    .foregroundStyle(meeting.messageIsCalmRetryStatus ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
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
                                description: Text("Utterances appear after a short silence or approximately 12 seconds of speech. Microphone speech is labelled Me; audio from other apps is labelled Others until the voices are separated after Stop. Click a speaker to name them."))
                                .padding(.top, 40)
                        }
                        let labeler = meeting.speakerLabeler
                        ForEach((meeting.session?.finalSegments ?? []).filter {
                            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                                || (labeler?.label(for: $0).localizedCaseInsensitiveContains(search) ?? false)
                        }) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    speakerLabel(for: segment, labeler: labeler)
                                    Text(timestamp(segment.range.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let parts = labeler?.parts(for: segment) {
                                    // Two voices in one line (ElevenLabs refinement): one run per voice.
                                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(labeler?.label(for: part) ?? "Others").font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                            Text(part.text).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                } else {
                                    Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
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
        .alert(renameTitle, isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { applyRename(renameText) }.keyboardShortcut(.defaultAction)
            Button("Use Automatic Name") { applyRename(nil) }
            Button("Cancel", role: .cancel) { rename = nil }
        } message: {
            Text(renameMessage)
        }
    }

    /// "Me" is plain text; a line from other apps opens a menu to name its voice or just this line.
    @ViewBuilder
    private func speakerLabel(for segment: MeetingTranscriptSegment, labeler: MeetingSpeakerLabeler?) -> some View {
        let label = labeler?.label(for: segment) ?? (segment.source == .microphone ? "Me" : "Others")
        let text = Text(label).font(.subheadline.bold())
            .foregroundStyle(segment.source == .microphone ? .blue : .primary)
        if segment.source == .system, let labeler {
            let cluster = labeler.clusterID(for: segment)
            Menu {
                if let cluster {
                    let voice = labeler.name(ofCluster: cluster) ?? label
                    Button("Rename \(voice) Everywhere…") {
                        renameText = meeting.session?.speakerAssignments.clusterNames[cluster] ?? ""
                        rename = .cluster(cluster, current: voice)
                    }
                    let others = labeler.knownNames.filter { $0 != voice }
                    if !others.isEmpty {
                        Menu("This Voice Is…") {
                            ForEach(others, id: \.self) { name in
                                Button(name) { meeting.renameSpeakerCluster(cluster, to: name) }
                            }
                        }
                    }
                }
                Button("Name Only This Line…") {
                    renameText = meeting.session?.speakerAssignments.segmentNames[segment.id] ?? ""
                    rename = .line(segment.id, current: label)
                }
                if meeting.session?.speakerAssignments.segmentNames[segment.id] != nil {
                    Button("Reset This Line") { meeting.renameLine(segment.id, to: nil) }
                }
                if cluster == nil {
                    Text(meeting.diarization == nil
                        ? "Use Detect Speakers below to separate the voices."
                        : "No single voice dominates this line.")
                }
            } label: { text }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Name this speaker")
        } else {
            text
        }
    }

    private var renameTitle: String {
        switch rename {
        case .cluster(_, let current): return "Rename \(current)"
        case .line: return "Name This Line"
        case nil: return ""
        }
    }

    private var renameMessage: String {
        switch rename {
        case .cluster: return "Every line of this voice gets the name, in the window and in exports."
        case .line: return "Only this line changes; the rest of the voice keeps its name."
        case nil: return ""
        }
    }

    private func applyRename(_ name: String?) {
        switch rename {
        case .cluster(let id, _): meeting.renameSpeakerCluster(id, to: name)
        case .line(let id, _): meeting.renameLine(id, to: name)
        case nil: break
        }
        rename = nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if meeting.isTranscribing || meeting.isDiarizing || meeting.isRefiningSpeakers {
                    ProgressView().controlSize(.small)
                }
                Text("\(meeting.pendingCount) pending · \(meeting.failedCount) failed").font(.caption)
                if meeting.isDiarizing { Text("· Separating voices…").font(.caption).foregroundStyle(.secondary) }
                if meeting.isRefiningSpeakers {
                    Text("· Refining speakers with ElevenLabs…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Refine with ElevenLabs", isOn: $meeting.scribeDiarizationEnabled)
                    .toggleStyle(.checkbox).font(.caption)
                    .disabled(!MeetingScribeDiarizer.hasAPIKey)
                    .help(MeetingScribeDiarizer.hasAPIKey
                        ? "After the voices are separated on this Mac, send the audio from other apps once more to ElevenLabs Scribe v3 (billed as batch audio) to label short lines and split lines with two voices."
                        : "Needs an ElevenLabs API key.")
                if meeting.canDetectSpeakers {
                    Button(meeting.diarization == nil ? "Detect Speakers" : "Detect Speakers Again") {
                        meeting.detectSpeakers()
                    }
                    .help("Separate the voices from other apps on this Mac. Names you gave are kept.")
                }
                if meeting.failedCount + meeting.pendingCount > 0 && !meeting.isTranscribing {
                    Button(meeting.isWaitingToRetry ? "Retry Now" : "Retry") { meeting.retry() }
                        .disabled(meeting.isChangingCapture)
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
