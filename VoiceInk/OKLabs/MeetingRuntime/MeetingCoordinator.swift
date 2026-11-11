import AppKit
import Combine
import Foundation
import LLMkit
import Network
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
    @Published var showSetup = false
    /// Voice clusters of the current session's system audio, once diarization ran.
    @Published private(set) var diarization: MeetingDiarization?
    @Published private(set) var isDiarizing = false
    let permissions = MeetingPermissions()
    let detector = MeetingDetector()

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
    /// Transient failures (timeouts, dropped connections, 408/429/5xx) keep the chunk pending
    /// and schedule this retry instead of suspending the queue. See `MeetingRetryBackoff`.
    private var backoff = MeetingRetryBackoff()
    private var retryTask: Task<Void, Never>?
    /// The status line currently shown for a retry wait; cleared only if still ours.
    private var retryMessage: String?
    private var retrySurfaced = false
    private let networkMonitor = NWPathMonitor()
    private var networkIsAvailable = true
    /// Waiting for the network to come back (offline failure), in place of a timed retry.
    @Published private(set) var isWaitingToRetry = false
    private let diarizer = MeetingDiarizer()
    /// Sessions whose automatic diarization already ran or failed in this app run; a manual
    /// "Detect Speakers" still works for them.
    private var diarizationAttempted = Set<UUID>()

    /// On by default; `defaults write com.prakashjoshipax.VoiceInk OKLabsMeetingSpeakerDiarization -bool NO` turns it off.
    static let diarizationDefaultsKey = "OKLabsMeetingSpeakerDiarization"
    private var automaticDiarizationEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.diarizationDefaultsKey) as? Bool ?? true
    }

    init(engine: VoiceInkEngine, models: TranscriptionModelManager, registry: TranscriptionServiceRegistry) {
        self.engine = engine
        self.models = models
        self.registry = registry
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Meetings", isDirectory: true)
        store = MeetingTranscriptStore(root: root)
        selectedModelKey = models.currentTranscriptionModel?.selectionKey ?? ""
        refreshSavedMeetings()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkDidChange(available: available) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "MeetingCoordinator.network"))
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
        permissions.refresh()
        guard permissions.snapshot.isReady else {
            showSetup = true
            message = "Allow microphone and system audio access below, then start your meeting."
            return
        }
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
            diarization = nil
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
            detector.recordingDidStart()
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
        guard worker == nil, retryTask == nil, pendingCount > 0, !queueIsSuspended else { return }
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
                    self.transientStreakEnded()
                } catch is CancellationError {
                    break
                } catch {
                    let kind = MeetingFailureClassifier.classify(MeetingFailureSignal(error: error))
                    job.error = error.localizedDescription
                    if kind == .permanent {
                        job.state = .failed
                        self.message = "Transcription failed. Audio is saved locally. Use Retry after resolving the error."
                        self.queueIsSuspended = true
                    } else {
                        // The chunk stays pending and first in line, so segment order is kept.
                        if kind == .transient && self.networkIsAvailable { job.attempts += 1 }
                    }
                    do { try jobStore.save(job) } catch { self.message = "Could not save queue status: \(error.localizedDescription)" }
                    self.jobs[index] = job
                    if kind != .permanent { self.scheduleRetry(kind: kind) }
                    break
                }
                self.jobs[index] = job
            }
            self.refreshSavedMeetings()
        }
    }

    func retry() {
        guard !isTranscribing, engine.recordingState == .idle else { return }
        cancelScheduledRetry()
        backoff.reset()
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
            do { diarization = try store.loadDiarization(id: recovered.id) } catch {
                diarization = nil
                message = "Speaker data of this meeting is unreadable; use Detect Speakers to rebuild it."
            }
            jobStore = audioStore
            cancelScheduledRetry()
            backoff.reset()
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

    // MARK: - Transient failure retry

    private func scheduleRetry(kind: MeetingFailureKind) {
        let offline = kind == .offline || !networkIsAvailable
        let delay: TimeInterval
        if offline {
            backoff.recordOffline(at: Date())
            delay = 60
        } else {
            delay = backoff.recordFailure(at: Date())
        }
        let surfaced = backoff.shouldSurface(at: Date())
        let line = MeetingRetryBackoff.statusLine(
            kind: offline ? .offline : .transient, retryIn: delay, pending: pendingCount, surfaced: surfaced)
        if message == nil || message == retryMessage {
            message = line
            retryMessage = line
            retrySurfaced = surfaced
        }
        isWaitingToRetry = true
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            // Offline: wake as soon as the network path is back (checked every second), at the
            // latest after a minute, so a stale path status cannot stall the queue.
            let deadline = Date().addingTimeInterval(delay)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if offline && self.networkIsAvailable { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.isWaitingToRetry = false
            self.processQueue()
        }
    }

    /// The message is the calm auto-retry status (shown in secondary style, not as a failure).
    var messageIsCalmRetryStatus: Bool { message != nil && message == retryMessage && !retrySurfaced }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
        isWaitingToRetry = false
        if message != nil && message == retryMessage { message = nil }
        retryMessage = nil
    }

    private func transientStreakEnded() {
        guard backoff.isFailing else { return }
        backoff.reset()
        if message != nil && message == retryMessage { message = nil }
        retryMessage = nil
    }

    private func networkDidChange(available: Bool) {
        let cameBack = available && !networkIsAvailable
        networkIsAvailable = available
        guard cameBack, retryTask != nil else { return }
        // Network is back: try now instead of waiting out the backoff.
        retryTask?.cancel()
        retryTask = nil
        isWaitingToRetry = false
        processQueue()
    }

    private func releaseDictationIfFinished() {
        if !hasOpenCapture && !isTranscribing { engine.isMeetingActive = false }
        diarizeAutomaticallyIfReady()
    }

    // MARK: - Speakers

    var speakerLabeler: MeetingSpeakerLabeler? {
        session.map { MeetingSpeakerLabeler(session: $0, diarization: diarization) }
    }

    /// Whether "Detect Speakers" makes sense now: finished, fully transcribed, has system audio.
    var canDetectSpeakers: Bool {
        guard let session, session.state == .finished, !isDiarizing, !isTranscribing, pendingCount == 0 else {
            return false
        }
        return systemAudioSeconds >= MeetingDiarizer.minimumAudioSeconds
    }

    private var systemAudioSeconds: TimeInterval {
        jobs.filter { $0.source == .system }.reduce(0) { $0 + $1.range.end - $1.range.start }
    }

    /// Runs after Stop once the transcription queue has drained; never blocks Stop or the queue.
    private func diarizeAutomaticallyIfReady() {
        guard automaticDiarizationEnabled, diarization == nil, let id = session?.id,
            !diarizationAttempted.contains(id), canDetectSpeakers
        else { return }
        detectSpeakers()
    }

    /// Separates the voices in "Others". On failure lines keep their current labels.
    func detectSpeakers() {
        guard canDetectSpeakers, let session, let jobStore else { return }
        let sessionID = session.id
        diarizationAttempted.insert(sessionID)
        let chunks = jobs.filter { $0.source == .system }.map {
            MeetingDiarizer.Chunk(range: $0.range, url: jobStore.audioURL(for: $0.id))
        }
        isDiarizing = true
        Task { [weak self, diarizer] in
            let result: Result<MeetingDiarization, Error>
            do { result = .success(try await diarizer.diarize(chunks)) } catch { result = .failure(error) }
            guard let self else { return }
            self.isDiarizing = false
            switch result {
            case .success(let found):
                do {
                    // The user may have opened another meeting meanwhile: save into the right one.
                    let owner = self.session?.id == sessionID ? self.session! : try self.store.load(id: sessionID)
                    try self.store.saveDiarization(found, for: owner)
                    if self.session?.id == sessionID { self.diarization = found }
                } catch {
                    self.message = "Could not save speaker data: \(error.localizedDescription)"
                }
            case .failure(let error):
                if self.session?.id == sessionID {
                    self.message = "Speaker separation did not run: \(error.localizedDescription) Lines stay labelled Others."
                }
            }
        }
    }

    /// Names every line of a voice cluster. nil or blank restores the automatic name.
    func renameSpeakerCluster(_ clusterID: String, to name: String?) {
        session?.nameSpeakerCluster(clusterID, as: name)
        checkpoint()
    }

    /// Names one line only. nil or blank restores the cluster's name.
    func renameLine(_ segmentID: UUID, to name: String?) {
        do { try session?.nameSegment(segmentID, as: name) } catch { message = error.localizedDescription; return }
        checkpoint()
    }

    func showFiles() {
        guard let sessionDirectory else { return }
        NSWorkspace.shared.open(sessionDirectory)
    }

    func copyTranscript() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingTranscriptExport.text(session, diarization: diarization), forType: .string)
    }

    func export() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting-\(session.startedAt.formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MeetingTranscriptExport.text(session, diarization: diarization).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
}

// MARK: - Failure classification input

extension MeetingFailureSignal {
    /// Maps the app's transcription errors to the provider-neutral signal `MeetingFailureClassifier` reads.
    init(error: Error) {
        self.init(message: error.localizedDescription)
        switch error {
        case let cloud as CloudTranscriptionError:
            switch cloud {
            case .apiRequestFailed(let status, _):
                httpStatus = status
            case .networkError(let inner):
                self = MeetingFailureSignal(error: inner)
                if urlErrorCode == nil && httpStatus == nil { isGenericNetwork = true }
            case .missingAPIKey, .invalidAPIKey, .audioFileNotFound, .unsupportedProvider, .unsupportedModel,
                .dataEncodingError, .noTranscriptionReturned:
                isKnownPermanent = true
            }
        case let kit as LLMKitError:
            switch kit {
            case .timeout: isTimeout = true
            case .networkError: isGenericNetwork = true
            case .httpError(let status, _): httpStatus = status
            default: isKnownPermanent = true
            }
        case let url as URLError:
            urlErrorCode = url.errorCode
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                urlErrorCode = ns.code
            } else if ns.domain == "LLMkit" {
                isGenericNetwork = true
            } else if ns.domain == "Meeting" {
                isKnownPermanent = true
            }
        }
    }
}
