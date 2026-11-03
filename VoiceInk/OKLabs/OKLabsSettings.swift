import Foundation

/// OKLabs fork settings. Every key is a plain UserDefaults key, so
/// `defaults write com.prakashjoshipax.VoiceInk <key> ...` configures it.
enum OKLabsSettings {
    enum Key {
        /// `oklabs` (default): the fork's Scribe engine. `upstream`: LLMkit's client.
        static let scribeEngine = "oklabs.scribeEngine"
        /// Override for the realtime endpoint (tests, regional endpoints).
        static let scribeEndpoint = "oklabs.scribeEndpoint"
        /// Keyterms file: one term per line (`#` comments) or a JSON array. Goes first, in file order.
        static let keytermsFile = "oklabs.keytermsFile"
        /// Remove `()`, `[]`, `{}` and `<tag>…</tag>` from transcripts (upstream always does). Default off.
        static let stripBracketedText = "oklabs.stripBracketedText"
        /// Apply Dictionary → Word Replacements (upstream always does). Default off.
        static let applyWordReplacements = "oklabs.applyWordReplacements"
        /// Keep the pre-sync key so explicit vocabulary-correction preferences survive. Default off.
        static let automaticVocabularyCorrection = "IsAutomaticVocabularyCorrectionEnabled"
        /// Delay before paste, ms, clamped to 0-500. Default 200 (upstream's fixed value).
        static let prePasteDelayMs = "oklabs.prePasteDelayMs"
        /// When true, the managed "Scribe" mode is restored on every launch.
        static let managedMode = "oklabs.managedMode"
        /// Show a notification when a cloud transcription fails. Default on.
        static let notifyOnFailure = "oklabs.notifyOnFailure"
    }

    static let defaultPrePasteDelayMs = 200

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.scribeEngine: "oklabs",
            Key.stripBracketedText: false,
            Key.applyWordReplacements: false,
            Key.automaticVocabularyCorrection: false,
            Key.prePasteDelayMs: defaultPrePasteDelayMs,
            Key.managedMode: false,
            Key.notifyOnFailure: true,
        ])
    }

    static var usesForkScribeEngine: Bool {
        (UserDefaults.standard.string(forKey: Key.scribeEngine) ?? "oklabs").lowercased() != "upstream"
    }

    static var scribeEndpoint: URL? {
        guard let raw = UserDefaults.standard.string(forKey: Key.scribeEndpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    static var keytermsFile: String? {
        guard let raw = UserDefaults.standard.string(forKey: Key.keytermsFile)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    static var stripsBracketedText: Bool {
        #if OKLABS
        return UserDefaults.standard.bool(forKey: Key.stripBracketedText)
        #else
        return true
        #endif
    }

    static var appliesWordReplacements: Bool {
        #if OKLABS
        return UserDefaults.standard.bool(forKey: Key.applyWordReplacements)
        #else
        return true
        #endif
    }

    static var appliesVocabularyCorrection: Bool {
        #if OKLABS
        return UserDefaults.standard.bool(forKey: Key.automaticVocabularyCorrection)
        #else
        return true
        #endif
    }

    /// Seconds before paste.
    static var prePasteDelay: TimeInterval {
        #if OKLABS
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Key.prePasteDelayMs) == nil
            ? defaultPrePasteDelayMs : defaults.integer(forKey: Key.prePasteDelayMs)
        return TimeInterval(min(500, max(0, stored))) / 1000
        #else
        return TimeInterval(defaultPrePasteDelayMs) / 1000
        #endif
    }

    static var notifiesOnFailure: Bool {
        #if OKLABS
        return UserDefaults.standard.bool(forKey: Key.notifyOnFailure)
        #else
        return false
        #endif
    }
}
