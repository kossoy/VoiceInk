import Foundation

// OKLabs fork: ElevenLabs Scribe Realtime engine (v3 Live by default), ported 1:1 from voxtype
// (`src/transcribe/elevenlabs.rs`). Foundation only, so the same files build in
// the app target and in the root SwiftPM package (`swift test`).

/// Protocol constants. Values and names follow voxtype.
public enum ScribeLimits {
    public static let sampleRate = 16_000
    public static let audioFormat = "pcm_16000"
    /// Default realtime model. `ScribeModels` maps the selected Scribe model to its live twin.
    public static let realtimeModel = ScribeModels.realtimeV3
    public static let defaultEndpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!

    /// Realtime keyterm limits, the same for v2 Realtime and v3 Live (batch allows 1000 terms
    /// of 50 characters; realtime rejects more). https://elevenlabs.io/docs/overview/capabilities/speech-to-text
    public static let maxKeyterms = 50
    public static let maxKeytermChars = 20

    /// 100 ms frames while streaming live (ElevenLabs recommends 0.1-1 s).
    public static let liveFrameSamples = 1_600
    /// 0.5 s frames when uploading a recording that already exists.
    public static let uploadFrameSamples = 8_000

    /// The server ignores a commit with < 0.3 s of uncommitted audio; pad to 0.35 s.
    public static let minCommitSamples = 5_600

    /// Commit on our own at the first quiet stretch after this much audio...
    public static let segmentSoftSamples = 30 * 16_000
    /// ...and unconditionally here, before the server's ~36 s auto-commit.
    public static let segmentHardSamples = 34 * 16_000
    /// How much consecutive quiet audio makes a good commit point (0.3 s).
    public static let quietRunSamples = 4_800
    /// RMS below this (~ -40 dBFS) counts as quiet.
    public static let quietRMS = 0.01

    /// Connect plus `session_started` handshake.
    public static let connectTimeout: TimeInterval = 5
    /// Longest wait for the final transcript after stop, counted from the stop request.
    public static let liveFinalWait: TimeInterval = 8
    /// A live frame that cannot be written for this long means the connection is stalled.
    public static let sendStall: TimeInterval = 2
}

/// Scribe model ids and how the fork picks the realtime one.
///
/// v3 (released 2026-11-10) keeps the v2 Realtime feature set on the same WebSocket,
/// including manual commits and the 50 x 20 keyterm limits, so only `model_id` changes:
/// https://elevenlabs.io/docs/overview/models#scribe-v3-live
public enum ScribeModels {
    public static let batchV2 = "scribe_v2"
    public static let batchV3 = "scribe_v3"
    public static let batchV2Medical = "scribe_v2_medical"
    public static let realtimeV2 = "scribe_v2_realtime"
    public static let realtimeV3 = "scribe_v3_live"

    /// Live model for the mode's selected Scribe model. `override` (the
    /// `oklabs.scribeRealtimeModel` setting) wins when set. v2 and v2 Medical stay on
    /// v2 Realtime (ElevenLabs points live medical audio there); v3 and anything
    /// unknown get v3 Live.
    public static func realtimeModel(forSelected selected: String?, override: String? = nil) -> String {
        if let forced = override?.trimmingCharacters(in: .whitespacesAndNewlines), !forced.isEmpty {
            return forced
        }
        switch selected?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case batchV2, batchV2Medical, realtimeV2: return realtimeV2
        default: return realtimeV3
        }
    }

    /// Default batch model for a meeting when dictation runs on `selected`: plain
    /// Scribe v2 moves up to v3 (27% fewer word errors, same price); other models,
    /// Medical included, stay as they are.
    public static func meetingBatchModel(forSelected selected: String) -> String {
        selected == batchV2 ? batchV3 : selected
    }
}

/// Session failure, classified like voxtype's `SessionError`.
public enum ScribeError: Error, Equatable, LocalizedError, Sendable {
    /// Credentials, quota, terms, bad parameters: retrying cannot help.
    case fatal(String)
    /// Network trouble, timeouts, busy servers, dropped chunks.
    case retryable(String)

    public var isFatal: Bool {
        if case .fatal = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .fatal(let m), .retryable(let m): return m
        }
    }

    public var errorDescription: String? { "ElevenLabs: \(message)" }

    /// Classify a server error `message_type`. `nil` means "not an error".
    public static func classify(messageType: String, detail: String) -> ScribeError? {
        let msg = "\(messageType): \(detail)"
        switch messageType {
        case "auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request", "input_error",
            "chunk_size_exceeded":
            return .fatal(msg)
        case "error", "transcriber_error", "rate_limited", "queue_overflow", "resource_exhausted",
            "session_time_limit_exceeded", "insufficient_audio_activity":
            return .retryable(msg)
        default:
            return nil
        }
    }
}

/// One server message. Unknown fields are ignored; a missing `message_type` is "".
public struct ScribeServerMessage: Equatable, Sendable {
    public var messageType: String
    public var text: String?
    public var error: String?
    public var warning: String?

    public init(messageType: String, text: String? = nil, error: String? = nil, warning: String? = nil) {
        self.messageType = messageType
        self.text = text
        self.error = error
        self.warning = warning
    }

    public static func parse(_ raw: String) -> ScribeServerMessage? {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return ScribeServerMessage(
            messageType: object["message_type"] as? String ?? "",
            text: object["text"] as? String,
            // voxtype reads `error`; LLMkit reads `message`. Accept both.
            error: (object["error"] as? String) ?? (object["message"] as? String),
            warning: object["warning"] as? String
        )
    }
}

/// What a server message means for the UI.
public enum ScribeLedgerEvent: Equatable, Sendable {
    case none
    case partial(String)
    case committed(String)
    case warning(String)
}

/// Commit bookkeeping and collected segments for one connection (voxtype `Transcript`).
public struct CommitLedger: Equatable, Sendable {
    public init() {}

    public private(set) var segments: [String] = []
    public private(set) var commitsSent = 0
    public private(set) var commitsAnswered = 0
    public private(set) var partials = 0
    public private(set) var unsolicitedCommits = 0
    public private(set) var throttledCommits = 0

    /// Called right before a frame carrying `commit: true` goes on the wire.
    public mutating func recordCommitSent() {
        commitsSent += 1
    }

    public mutating func on(_ message: ScribeServerMessage) throws -> ScribeLedgerEvent {
        switch message.messageType {
        case "partial_transcript":
            partials += 1
            return .partial(message.text ?? "")
        case "committed_transcript":
            let text = message.text ?? ""
            if commitsAnswered < commitsSent {
                commitsAnswered += 1
            } else {
                // Unsolicited server commit: keep the text, it is not an answer.
                unsolicitedCommits += 1
            }
            segments.append(text)
            return .committed(text)
        case "commit_throttled":
            // The server ignored one of our commits (too little audio). Count it as
            // answered so we do not wait for a transcript that will never come.
            throttledCommits += 1
            if commitsAnswered < commitsSent {
                commitsAnswered += 1
            }
            return .none
        case "warning":
            return .warning(message.warning ?? message.error ?? "")
        case "session_started", "committed_transcript_with_timestamps", "committed_transcript_entities",
            "edited_transcript":
            // `_with_timestamps` repeats a committed segment; counting it would duplicate text.
            return .none
        default:
            if let error = ScribeError.classify(
                messageType: message.messageType, detail: message.error ?? "(no detail)")
            {
                throw error
            }
            return .none
        }
    }

    public var isComplete: Bool { commitsAnswered >= commitsSent }

    /// Trimmed non-empty segments joined with single spaces.
    public var text: String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Wire format of the client messages.
public enum ScribeWire {
    public static func pcmBytes(_ samples: [Int16]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for (i, sample) in samples.enumerated() {
                let bits = UInt16(bitPattern: sample)
                out[2 * i] = UInt8(truncatingIfNeeded: bits)
                out[2 * i + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        return data
    }

    public static func chunkMessage(samples: [Int16], commit: Bool, previousText: String? = nil) -> String {
        let audio = pcmBytes(samples).base64EncodedString()
        // Base64 needs no JSON escaping; the key order matches voxtype's wire format.
        var json =
            "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\(audio)\",\"commit\":\(commit ? "true" : "false"),\"sample_rate\":\(ScribeLimits.sampleRate)"
        if let previousText, let encoded = jsonString(previousText) {
            json += ",\"previous_text\":\(encoded)"
        }
        json += "}"
        return json
    }

    private static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Builds the WebSocket URL (query string only; the key travels in the `xi-api-key` header).
public enum ScribeURL {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func build(
        endpoint: URL,
        model: String = ScribeLimits.realtimeModel,
        noVerbatim: Bool = true,
        language: String?,
        keyterms: [String]
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss"
        else {
            throw ScribeError.fatal("endpoint must be ws:// or wss://: \(endpoint.absoluteString)")
        }
        var params: [(String, String)] = [
            ("model_id", model),
            ("audio_format", ScribeLimits.audioFormat),
            ("commit_strategy", "manual"),
            ("no_verbatim", noVerbatim ? "true" : "false"),
        ]
        if let language = normalizedLanguage(language) {
            params.append(("language_code", language))
        }
        for term in keyterms {
            params.append(("keyterms", term))
        }
        var query = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        query += params.map { "\(encode($0.0))=\(encode($0.1))" }
        components.percentEncodedQuery = query.joined(separator: "&")
        guard let url = components.url else {
            throw ScribeError.fatal("endpoint invalid: \(endpoint.absoluteString)")
        }
        return url
    }

    /// `nil`, empty and `auto` mean "detect the language": no `language_code`.
    public static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            trimmed.lowercased() != "auto"
        else {
            return nil
        }
        return trimmed
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
