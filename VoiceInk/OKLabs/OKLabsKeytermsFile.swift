import Foundation
import os

/// Reads `oklabs.keytermsFile` for every recording, so edits apply without a relaunch.
enum OKLabsKeytermsFile {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OKLabsKeyterms")

    /// File terms in file order, or none when unset or unreadable (logged).
    static func terms() -> [String] {
        guard let path = OKLabsSettings.keytermsFile else { return [] }
        do {
            let terms = try Keyterms.load(path: path)
            let selection = Keyterms.limit(terms)
            if !selection.dropSummary.isEmpty {
                logger.warning("Keyterms file \(path, privacy: .public): \(selection.dropSummary, privacy: .public)")
            }
            return terms
        } catch {
            logger.error("Keyterms file \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
