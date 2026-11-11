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
    @Published var showSetup = false
    /// Voice clusters of the current session's system audio, once diarization ran.
    @Published private(set) var diarization: MeetingDiarization?
    @Published private(set) var isDiarizing = false
    /// The optional ElevenLabs Scribe v3 pass that refines `diarization` (diarization-scribe.json).
    @Published private(set) var scribeDiarization: MeetingScribeDiarization?
    @Published private(set) var isRefiningSpeakers = false
    /// "Refine speakers with ElevenLabs" in the meeting window. Persisted; unset means on when an
    /// ElevenLabs key is configured.
    @Published var scribeDiarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(scribeDiarizationEnabled, forKey: Self.scribeDiarizationDefaultsKey) }
    }
    static let scribeDiarizationDefaultsKey = "oklabs.meeting.scribeDiarization"
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
    private let diarizer = MeetingDiarizer()
    /// Teams Accessibility speaker names (on by default; `oklabs.meeting.teamsSpeakerObserver`
    /// = false turns it off). Its cues name the diarization clusters by majority vote (MeetingSpeakerNaming).
    private var speakerObserver: TeamsSpeakerObserver?
    private let scribeDiarizer = MeetingScribeDiarizer()
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
        TeamsSpeakerObserver.registerDefault()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Meetings", isDirectory: true)
        store = MeetingTranscriptStore(root: root)
        scribeDiarizationEnabled =
            UserDefaults.standard.object(forKey: Self.scribeDiarizationDefaultsKey) as? Bool
            ?? MeetingScribeDiarizer.hasAPIKey
        selectedModelKey = Self.defaultModelKey(models)
        refreshSavedMeetings()
    }

    /// The dictation model, except that ElevenLabs Scribe V2 is upgraded to Scribe V3 for
    /// meetings when V3 is usable. A model picked in the meeting window is kept as is.
    static func defaultModelKey(_ models: TranscriptionModelManager) -> String {
        guard let current = models.currentTranscriptionModel else { return "" }
        guard current.provider == .elevenLabs else { return current.selectionKey }
        let wanted = ScribeModels.meetingBatchModel(forSelected: current.name)
        let upgraded = models.usableModels.first { $0.provider == .elevenLabs && $0.name == wanted }
        return (upgraded ?? current).selectionKey
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
            scribeDiarization = nil
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
            startSpeakerObserver()
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
            stopSpeakerObserver()
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
                startSpeakerObserver()
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
        stopSpeakerObserver()
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
            do { diarization = try store.loadDiarization(id: recovered.id) } catch {
                diarization = nil
                message = "Speaker data of this meeting is unreadable; use Detect Speakers to rebuild it."
            }
            // The cloud refinement is optional: unreadable means "not there".
            scribeDiarization = (try? store.loadScribeDiarization(id: recovered.id)) ?? nil
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

    private func startSpeakerObserver() {
        guard TeamsSpeakerObserver.isEnabled(), session?.state == .recording else { return }
        let observer = speakerObserver ?? TeamsSpeakerObserver()
        speakerObserver = observer
        let origin = origin
        observer.start(clock: { max(0, MeetingAudioCapture.hostTime - origin) }) { [weak self] cue in
            // Cues reach disk with the next checkpoint (chunk, pause, stop).
            do { try self?.session?.recordSpeakerCue(cue) } catch {}
        }
    }

    /// Delivers the cues still open before the session pauses or finishes.
    private func stopSpeakerObserver() {
        speakerObserver?.stop()
    }

    private func checkpoint() {
        guard let session else { return }
        do { try store.save(session); refreshSavedMeetings() }
        catch { message = "Could not save transcript: \(error.localizedDescription)" }
    }

    private func releaseDictationIfFinished() {
        if !hasOpenCapture && !isTranscribing { engine.isMeetingActive = false }
        diarizeAutomaticallyIfReady()
    }

    // MARK: - Speakers

    var speakerLabeler: MeetingSpeakerLabeler? {
        session.map { MeetingSpeakerLabeler(session: $0, diarization: diarization, scribe: scribeDiarization) }
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
                    if self.session?.id == sessionID {
                        self.diarization = found
                        // A rerun's clusters differ; the old cloud mapping does not apply to them.
                        self.scribeDiarization = nil
                    }
                    if self.scribeDiarizationEnabled { self.refineSpeakers(sessionID: sessionID, chunks: chunks) }
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

    /// Optional second pass after the local one: ElevenLabs Scribe v3 diarization of the same
    /// system track. Never blocks anything; on failure the local result stays as it is.
    private func refineSpeakers(sessionID: UUID, chunks: [MeetingDiarizer.Chunk]) {
        isRefiningSpeakers = true
        Task { [weak self, scribeDiarizer] in
            let result: Result<MeetingScribeDiarization, Error>
            do { result = .success(try await scribeDiarizer.diarize(chunks)) } catch { result = .failure(error) }
            guard let self else { return }
            self.isRefiningSpeakers = false
            switch result {
            case .success(let found):
                do {
                    let owner = self.session?.id == sessionID ? self.session! : try self.store.load(id: sessionID)
                    try self.store.saveScribeDiarization(found, for: owner)
                    if self.session?.id == sessionID { self.scribeDiarization = found }
                } catch {
                    self.message = "Could not save the ElevenLabs speaker data: \(error.localizedDescription)"
                }
            case .failure(let error):
                if self.session?.id == sessionID {
                    self.message = "ElevenLabs speaker refinement did not run: \(error.localizedDescription) Local speakers are kept."
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
        NSPasteboard.general.setString(
            MeetingTranscriptExport.text(session, diarization: diarization, scribe: scribeDiarization), forType: .string)
    }

    func export() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting-\(session.startedAt.formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingTranscriptExport.text(session, diarization: diarization, scribe: scribeDiarization)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        catch { message = error.localizedDescription }
    }
}
