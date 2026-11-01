import Foundation
import os

/// Thrown from `commit()` when the live stream failed with an error that a batch
/// re-upload cannot fix (bad key, quota, terms). The session then reports the
/// failure instead of uploading the recording again.
struct OKLabsFatalStreamingError: LocalizedError {
    let underlying: ScribeError
    var errorDescription: String? { underlying.errorDescription }
}

/// OKLabs fork: ElevenLabs Scribe v2 Realtime with voxtype's engine semantics.
///
/// - Audio is re-framed into 100 ms frames; the client commits by itself at the
///   first pause after 30 s and always by 34 s, so the server never auto-commits.
/// - Every commit is counted and answered; the final segment is padded so its
///   commit is never throttled; all segments are joined.
/// - A failed stream (send error, 2 s write stall, server error, closed socket,
///   no final answer within 8 s of stop) makes the shared streaming layer
///   re-upload the whole recording to batch `scribe_v2` instead of pasting partial text.
final class ScribeRealtimeProvider: StreamingTranscriptionProvider {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OKLabsScribe")
    private let vocabularyTerms: [String]
    /// `connect()` and `disconnect()` can run on different threads (a quick
    /// start-then-cancel), so the mutable state sits behind a lock.
    private let lock = NSLock()
    private var storedSession: ScribeLiveSession?
    private var storedForwardingTask: Task<Void, Never>?
    private var session: ScribeLiveSession? {
        lock.lock()
        defer { lock.unlock() }
        return storedSession
    }
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let finalContinuation: AsyncStream<String>.Continuation

    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    let finalizationEvents: AsyncStream<String>?

    init(keyterms: [String]) {
        vocabularyTerms = keyterms
        let (events, eventsContinuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = events
        self.eventsContinuation = eventsContinuation
        let (finals, finalContinuation) = AsyncStream.makeStream(of: String.self)
        finalizationEvents = finals
        self.finalContinuation = finalContinuation
    }

    deinit {
        storedForwardingTask?.cancel()
        eventsContinuation.finish()
        finalContinuation.finish()
    }

    /// A retryable failure goes straight to batch at stop, with no final wait.
    /// A fatal one goes through `commit()`, which reports it without a retry.
    var stopDisposition: StreamingStopDisposition {
        guard let failure = session?.status.failure else { return .finalizeStreaming }
        return failure.isFatal ? .finalizeStreaming : .useBatchFallback
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        let selection = Keyterms.limit(vocabularyTerms)
        if !selection.dropSummary.isEmpty {
            logger.warning("Scribe keyterms dropped: \(selection.dropSummary, privacy: .public)")
        }
        let endpoint = OKLabsSettings.scribeEndpoint ?? ScribeLimits.defaultEndpoint
        let url: URL
        do {
            url = try ScribeURL.build(endpoint: endpoint, language: language, keyterms: selection.terms)
        } catch {
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        }

        let session = ScribeLiveSession(config: ScribeSessionConfig(url: url, apiKey: apiKey))
        let forwarding = makeForwardingTask(from: session)
        lock.lock()
        storedForwardingTask?.cancel()
        storedSession = session
        storedForwardingTask = forwarding
        lock.unlock()

        let start = Date()
        do {
            try await session.connect()
        } catch let error as ScribeError {
            logger.error("Scribe connect failed fatal=\(error.isFatal, privacy: .public): \(error.message, privacy: .public)")
            forwarding.cancel()
            // A bad key or exhausted quota is reported as is; the session then skips
            // the batch re-upload, which would fail the same way.
            if error.isFatal { throw OKLabsFatalStreamingError(underlying: error) }
            throw StreamingTranscriptionError.connectionFailed(error.message)
        }
        logger.notice(
            "Scribe connected language=\(ScribeURL.normalizedLanguage(language) ?? "auto", privacy: .public) keyterms=\(selection.terms.count, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
        )
        eventsContinuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {
        await session?.append(data)
    }

    /// Sends the tail and the final commit, then waits for every answer (at most
    /// 8 s after stop). The joined text goes to `finalizationEvents`; on failure
    /// the stream finishes empty, which sends the recording to batch.
    func commit() async throws {
        guard let session else {
            finalContinuation.finish()
            throw StreamingTranscriptionError.notConnected
        }
        let start = Date()
        let outcome = await session.finish()
        let stats = await session.snapshot()
        let elapsed = Date().timeIntervalSince(start)
        let summary =
            "commits=\(stats.commitsSent) answered=\(stats.commitsAnswered) segments=\(stats.segments) unsolicited=\(stats.unsolicitedCommits) throttled=\(stats.throttledCommits) receivedSamples=\(stats.receivedSamples) sentSamples=\(stats.sentSamples) padded=\(stats.paddedSamples)"
        switch outcome {
        case .text(let text):
            logger.notice(
                "Scribe final elapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public) \(summary, privacy: .public)"
            )
            finalContinuation.yield(text)
            finalContinuation.finish()
        case .failed(let error):
            logger.warning(
                "Scribe stream failed fatal=\(error.isFatal, privacy: .public) reason=\(error.message, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s \(summary, privacy: .public)"
            )
            finalContinuation.finish()
            if error.isFatal {
                throw OKLabsFatalStreamingError(underlying: error)
            }
        }
    }

    func disconnect() async {
        lock.lock()
        let task = storedForwardingTask
        let session = storedSession
        storedForwardingTask = nil
        lock.unlock()
        task?.cancel()
        await session?.close()
        eventsContinuation.finish()
        finalContinuation.finish()
    }

    private func makeForwardingTask(from session: ScribeLiveSession) -> Task<Void, Never> {
        let events = session.events
        let continuation = eventsContinuation
        let logger = logger
        return Task.detached {
            for await event in events {
                switch event {
                case .partial(let text):
                    continuation.yield(.partial(text: text))
                case .committed(let text):
                    continuation.yield(.committed(text: text))
                case .warning(let text):
                    logger.warning("Scribe warning: \(text, privacy: .public)")
                case .failed(let error):
                    logger.warning("Scribe stream marked failed: \(error.message, privacy: .public)")
                    continuation.yield(.error(error))
                }
            }
        }
    }
}

enum OKLabsStreamingPolicy {
    /// Errors for which the batch re-upload is skipped (it would fail the same way).
    static func skipsBatchFallback(_ error: Error) -> Bool {
        error is OKLabsFatalStreamingError
    }
}
