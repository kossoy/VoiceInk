import Foundation

/// How a failed meeting chunk transcription should be treated.
public enum MeetingFailureKind: String, Equatable, Sendable {
    /// Worth retrying soon: timeout, dropped connection, HTTP 408/429/5xx, provider overload.
    case transient
    /// The Mac has no network path. Wait for it instead of spending attempts.
    case offline
    /// Retrying will not help (missing model or file, bad key, bad request): stop the queue.
    case permanent
}

/// What is known about a failure, independent of the provider SDK that produced it.
/// The app builds this from `CloudTranscriptionError`, `LLMKitError`, `URLError` or `NSError`.
public struct MeetingFailureSignal: Equatable, Sendable {
    /// `NSURLErrorDomain` code when the failure came from URL loading.
    public var urlErrorCode: Int?
    /// HTTP status when the server answered.
    public var httpStatus: Int?
    /// A request or polling timeout reported without a URL error code.
    public var isTimeout: Bool
    /// A network failure reported without a URL error code or HTTP status (SDK wrapper).
    public var isGenericNetwork: Bool
    /// Known not to be retryable (missing model, audio file or API key; rejected key).
    public var isKnownPermanent: Bool
    /// Error text, used only to recognise provider overload wording.
    public var message: String

    public init(
        urlErrorCode: Int? = nil, httpStatus: Int? = nil, isTimeout: Bool = false,
        isGenericNetwork: Bool = false, isKnownPermanent: Bool = false, message: String = ""
    ) {
        self.urlErrorCode = urlErrorCode
        self.httpStatus = httpStatus
        self.isTimeout = isTimeout
        self.isGenericNetwork = isGenericNetwork
        self.isKnownPermanent = isKnownPermanent
        self.message = message
    }
}

public enum MeetingFailureClassifier {
    /// `NSURLError` codes that mean "no usable network path right now".
    static let offlineURLCodes: Set<Int> = [
        -1009,  // notConnectedToInternet
        -1018,  // internationalRoamingOff
        -1020,  // dataNotAllowed
    ]
    /// `NSURLError` codes worth retrying.
    static let transientURLCodes: Set<Int> = [
        -1001,  // timedOut
        -1003,  // cannotFindHost
        -1004,  // cannotConnectToHost
        -1005,  // networkConnectionLost
        -1006,  // dnsLookupFailed
        -1011,  // badServerResponse
        -1017,  // cannotParseResponse
        -1200,  // secureConnectionFailed
        -2102,  // internal timeout (CFNetwork)
    ]

    public static func classify(_ signal: MeetingFailureSignal) -> MeetingFailureKind {
        if signal.isKnownPermanent { return .permanent }
        if let status = signal.httpStatus {
            if status == 408 || status == 429 || (500...599).contains(status) { return .transient }
            return .permanent
        }
        if let code = signal.urlErrorCode {
            if offlineURLCodes.contains(code) { return .offline }
            if transientURLCodes.contains(code) { return .transient }
            return .permanent
        }
        if signal.isTimeout || signal.isGenericNetwork { return .transient }
        let text = signal.message.lowercased()
        let overloadWords = ["rate limit", "rate-limit", "too many requests", "overloaded", "temporarily unavailable",
                             "try again later", "timed out"]
        if overloadWords.contains(where: text.contains) { return .transient }
        return .permanent
    }
}

/// Backoff for a streak of transient failures of the meeting queue.
/// Delays 2, 5, 15, 30, 60 s, then every 60 s. Any successful chunk or a manual Retry resets it.
public struct MeetingRetryBackoff: Equatable, Sendable {
    public static let delays: [TimeInterval] = [2, 5, 15, 30, 60]
    /// After this much continuous failure the UI shows the failure text (retries continue).
    public static let surfaceAfter: TimeInterval = 600

    public private(set) var attempts = 0
    public private(set) var streakStart: Date?

    public init() {}

    public var isFailing: Bool { streakStart != nil }

    /// Records one transient failure at `now` and returns the wait before the next attempt.
    public mutating func recordFailure(at now: Date) -> TimeInterval {
        if streakStart == nil { streakStart = now }
        let delay = Self.delays[min(attempts, Self.delays.count - 1)]
        attempts += 1
        return delay
    }

    /// Records an offline failure: starts the streak (for surfacing) without advancing the
    /// backoff, so waiting for the network does not spend attempts.
    public mutating func recordOffline(at now: Date) {
        if streakStart == nil { streakStart = now }
    }

    /// Whether the streak has lasted long enough to surface the failure text.
    public func shouldSurface(at now: Date) -> Bool {
        guard let streakStart else { return false }
        return now.timeIntervalSince(streakStart) >= Self.surfaceAfter
    }

    /// A chunk succeeded or the user pressed Retry: start over.
    public mutating func reset() {
        attempts = 0
        streakStart = nil
    }

    /// Status line while waiting for the next attempt.
    public static func statusLine(kind: MeetingFailureKind, retryIn seconds: TimeInterval, pending: Int, surfaced: Bool) -> String {
        let wait = max(1, Int(seconds.rounded(.up)))
        let base: String
        switch kind {
        case .offline: base = "Offline, transcription resumes when the network is back"
        default: base = "Network issue, retrying in \(wait) s"
        }
        let line = "\(base) · \(pending) pending"
        return surfaced
            ? "Transcription keeps failing (\(line)). Audio is saved locally; retrying automatically."
            : line
    }
}
