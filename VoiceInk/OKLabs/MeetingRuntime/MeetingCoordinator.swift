import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var session: MeetingSession?
    @Published private(set) var jobs: [MeetingAudioJob] = []
    @Published private(set) var isChangingCapture = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var microphoneSeconds: TimeInterval = 0
    @Published private(set) var systemSeconds: TimeInterval = 0
    @Published var message: String?
    @Published var selectedModelKey = ""
    @Published var title = ""
    @Published private(set) var savedMeetings: [MeetingSession] = []

    let models: TranscriptionModelManager
    private let engine: VoiceInkEngine
    private let registry: TranscriptionServiceRegistry
    private let store: MeetingTranscriptStore
    private var capture: MeetingAudioCapture?
    private var origin: TimeInterval = 0
    private var jobStore: MeetingAudioJobStore?
    private var worker: Task<Void, Never>?
    private var selectedModel: (any TranscriptionModel)?
    private var language: String?
    private var queueIsSuspended = false

    init(engine: VoiceInkEngine, models: TranscriptionModelManager, registry: TranscriptionServiceRegistry) {
        self.engine = engine
        self.models = models
        self.registry = registry
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Meetings", isDirectory: true)
        store = MeetingTranscriptStore(root: root)
        selectedModelKey = models.currentTranscriptionModel?.selectionKey ?? ""
        refreshSavedMeetings()
    }

    var hasOpenCapture: Bool { session.map { $0.state != .finished } ?? false }
    var canStart: Bool { !hasOpenCapture && !isChangingCapture && !isTranscribing }
    var pendingCount: Int { jobs.filter { $0.state == .pending }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var sessionDirectory: URL? {
        session.map { store.root.appendingPathComponent($0.id.uuidString, isDirectory: true) }
    }

    func start() async {
        guard canStart else { return }
        guard engine.recordingState == .idle else { message = "Finish dictation before starting a meeting."; return }
        guard let model = models.usableModels.first(where: { $0.selectionKey == selectedModelKey }) else {
            message = "Select an available transcription model first. Download a local model in Manage Models if needed."
            return
        }
        isChangingCapture = true
        engine.isMeetingActive = true
        message = nil
        defer { isChangingCapture = false }
        let capture = MeetingAudioCapture()
        do {
            try await capture.prepare()
            let newSession = MeetingSession(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : title)
            let directory = try store.save(newSession)
            session = newSession
            jobs = []
            queueIsSuspended = false
            jobStore = MeetingAudioJobStore(sessionDirectory: directory)
            selectedModel = model
            language = UserDefaults.standard.string(forKey: "SelectedLanguage")
            microphoneSeconds = 0
            systemSeconds = 0
            microphoneLevel = 0
            systemLevel = 0
            self.capture = capture
            installCallbacks(on: capture, sessionID: newSession.id)
            origin = MeetingAudioCapture.hostTime
            try await capture.start(origin: origin, from: 0)
        } catch {
            message = error.localizedDescription
            if session?.state == .recording {
                try? session?.finish(at: max(0, MeetingAudioCapture.hostTime - origin))
                checkpoint()
            }
            self.capture = nil
            engine.isMeetingActive = false
        }
    }

    func pauseOrResume() async {
        guard !isChangingCapture, let capture, let state = session?.state, state != .finished else { return }
        isChangingCapture = true
        defer { isChangingCapture = false }
        if state == .recording {
            let result = await capture.stop()
            do { try session?.pause(at: result.end) } catch { message = error.localizedDescription }
            if let error = result.error { message = error }
            microphoneLevel = 0
            systemLevel = 0
        } else {
            do {
                let start = max(0, MeetingAudioCapture.hostTime - origin)
                try session?.resume(at: start)
                try await capture.start(origin: origin, from: start)
            } catch {
                message = error.localizedDescription
                try? session?.pause(at: max(0, MeetingAudioCapture.hostTime - origin))
            }
        }
        checkpoint()
    }

    func stop() async {
        guard !isChangingCapture, let session, session.state != .finished else { return }
        isChangingCapture = true
        defer { isChangingCapture = false }
        var end = max(0, MeetingAudioCapture.hostTime - origin)
        if session.state == .recording, let capture {
            let result = await capture.stop()
            end = max(end, result.end)
            if let error = result.error { message = error }
        }
        do { try self.session?.finish(at: end) } catch { message = error.localizedDescription }
        capture = nil
        microphoneLevel = 0
        systemLevel = 0
        checkpoint()
        releaseDictationIfFinished()
    }

    private func installCallbacks(on capture: MeetingAudioCapture, sessionID: UUID) {
        capture.onChunk = { [weak self] chunk in
            guard let self, self.session?.id == sessionID else { return }
            self.enqueue(chunk)
        }
        capture.onLevel = { [weak self] source, level, end in
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID else { return }
                if source == .microphone { self.microphoneLevel = level; self.microphoneSeconds = end }
                else { self.systemLevel = level; self.systemSeconds = end }
            }
        }
        capture.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID else { return }
                self.message = error
                // An intentional stop can also generate a delegate callback.
                if !self.isChangingCapture { await self.stop() }
            }
        }
    }

    private func enqueue(_ chunk: MeetingAudioChunk) {
        guard let jobStore, let selectedModel else { return }
        do {
            let job = try jobStore.enqueue(chunk, modelKey: selectedModel.selectionKey, language: language)
            jobs.append(job)
            // Checkpoint recording intervals before a job is processed.
            if let session { try store.save(session) }
            processQueue()
        } catch {
            message = "Could not save meeting audio: \(error.localizedDescription). Recording will stop."
            Task { await stop() }
        }
    }

    private func processQueue() {
        guard worker == nil, pendingCount > 0, !queueIsSuspended else { return }
        isTranscribing = true
        engine.isMeetingActive = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.worker = nil
                self.isTranscribing = false
                self.releaseDictationIfFinished()
            }
            while let index = self.jobs.firstIndex(where: { $0.state == .pending }), let jobStore = self.jobStore {
                var job = self.jobs[index]
                do {
                    // A crash after committing text but before marking the job is idempotent.
                    if self.session?.finalSegments.contains(where: { $0.id == job.id }) != true {
                        guard let model = self.models.usableModels.first(where: { $0.selectionKey == job.modelKey }) else {
                            throw NSError(domain: "Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "The recorded model is unavailable. Restore it, then Retry."])
                        }
                        let text = try await self.registry.transcribe(
                            audioURL: jobStore.audioURL(for: job.id), model: model,
                            context: TranscriptionRequestContext(language: job.language, prompt: nil))
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try self.session?.upsert(MeetingTranscriptSegment(
                                id: job.id, source: job.source, range: job.range, text: text, isFinal: true))
                        }
                    }
                    if let session = self.session { try self.store.save(session) }
                    job.state = .completed
                    job.error = nil
                    try jobStore.save(job)
                } catch {
                    job.state = .failed
                    job.error = error.localizedDescription
                    self.message = "Transcription failed. Audio is saved locally. Use Retry after resolving the error."
                    do { try jobStore.save(job) } catch { self.message = "Could not save queue status: \(error.localizedDescription)" }
                    self.queueIsSuspended = true
                }
                self.jobs[index] = job
                if self.queueIsSuspended { break }
            }
            self.refreshSavedMeetings()
        }
    }

    func retry() {
        guard !isTranscribing, engine.recordingState == .idle else { return }
        do {
            for index in jobs.indices where jobs[index].state == .failed {
                jobs[index].state = .pending
                jobs[index].error = nil
                try jobStore?.save(jobs[index])
            }
            message = nil
            queueIsSuspended = false
            processQueue()
        } catch { message = error.localizedDescription }
    }

    func load(_ saved: MeetingSession) {
        guard canStart else { return }
        do {
            var recovered = try store.load(id: saved.id)
            let directory = store.root.appendingPathComponent(saved.id.uuidString)
            let audioStore = MeetingAudioJobStore(sessionDirectory: directory)
            let recoveredJobs = try audioStore.load()
            if recovered.state != .finished {
                let end = max(recovered.latestActivityTime, recoveredJobs.map(\.range.end).max() ?? 0)
                try recovered.finish(at: end)
                try store.save(recovered)
            }
            session = recovered
            jobs = recoveredJobs
            jobStore = audioStore
            queueIsSuspended = true
            message = pendingCount + failedCount > 0 ? "Recovered audio is ready. Retry to transcribe pending chunks." : nil
            microphoneLevel = 0
            systemLevel = 0
        } catch { message = "Could not restore meeting: \(error.localizedDescription)" }
    }

    func refreshSavedMeetings() {
        do {
            guard FileManager.default.fileExists(atPath: store.root.path) else { return }
            savedMeetings = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.lastPathComponent) }
                .map { try store.load(id: $0) }
                .sorted { $0.startedAt > $1.startedAt }
        } catch { message = "Could not read saved meetings: \(error.localizedDescription)" }
    }

    private func checkpoint() {
        guard let session else { return }
        do { try store.save(session); refreshSavedMeetings() }
        catch { message = "Could not save transcript: \(error.localizedDescription)" }
    }

    private func releaseDictationIfFinished() {
        if !hasOpenCapture && !isTranscribing { engine.isMeetingActive = false }
    }

    func showFiles() {
        guard let sessionDirectory else { return }
        NSWorkspace.shared.open(sessionDirectory)
    }

    func copyTranscript() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingTranscriptExport.text(session), forType: .string)
    }

    func export() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting-\(session.startedAt.formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MeetingTranscriptExport.text(session).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
}
