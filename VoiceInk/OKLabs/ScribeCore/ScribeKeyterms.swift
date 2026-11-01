import Foundation

/// The keyterms that go to the realtime API, plus everything that was left out and why.
public struct KeytermSelection: Equatable, Sendable {
    public init() {}

    public var terms: [String] = []
    /// Longer than `ScribeLimits.maxKeytermChars` characters (Unicode scalars, as voxtype counts).
    public var tooLong: [String] = []
    /// Contains one of `<>{}[]\`, which the realtime endpoint rejects.
    public var unsupported: [String] = []
    /// Case-insensitive duplicates of an earlier term.
    public var duplicates: [String] = []
    /// Valid terms past the first `ScribeLimits.maxKeyterms`.
    public var overLimit: [String] = []

    public var droppedCount: Int { tooLong.count + unsupported.count + overLimit.count }

    /// One line for the log; empty when nothing was dropped.
    public var dropSummary: String {
        var parts: [String] = []
        if !tooLong.isEmpty { parts.append("too long (>\(ScribeLimits.maxKeytermChars)): \(tooLong)") }
        if !unsupported.isEmpty { parts.append("unsupported characters: \(unsupported)") }
        if !overLimit.isEmpty { parts.append("over the \(ScribeLimits.maxKeyterms)-term limit: \(overLimit)") }
        return parts.joined(separator: "; ")
    }
}

public enum Keyterms {
    public static let unsupportedCharacters: Set<Character> = Set("<>{}[]\\")

    public enum ParseError: Error, Equatable, LocalizedError {
        case notAStringArray(String)
        public var errorDescription: String? {
            switch self {
            case .notAStringArray(let detail): return "keyterms file is not a JSON array of strings: \(detail)"
            }
        }
    }

    /// A JSON array of strings, or one term per line with `#` comment lines.
    public static func parse(_ contents: String) throws -> [String] {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8) else { throw ParseError.notAStringArray("not UTF-8") }
            do {
                return try JSONDecoder().decode([String].self, from: data)
            } catch {
                throw ParseError.notAStringArray(error.localizedDescription)
            }
        }
        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Dedupe case-insensitively in order, drop invalid terms, keep the first 50.
    public static func limit(_ raw: [String]) -> KeytermSelection {
        var selection = KeytermSelection()
        var seen = Set<String>()
        for candidate in raw {
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else {
                selection.duplicates.append(term)
                continue
            }
            seen.insert(key)
            if term.unicodeScalars.count > ScribeLimits.maxKeytermChars {
                selection.tooLong.append(term)
                continue
            }
            if term.contains(where: { unsupportedCharacters.contains($0) }) {
                selection.unsupported.append(term)
                continue
            }
            if selection.terms.count >= ScribeLimits.maxKeyterms {
                selection.overLimit.append(term)
                continue
            }
            selection.terms.append(term)
        }
        return selection
    }

    /// Reads a keyterms file. `~` is expanded.
    public static func load(path: String) throws -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        let contents = try String(contentsOfFile: expanded, encoding: .utf8)
        return try parse(contents)
    }

    /// File terms first (file order), then the rest, deduplicated and limited.
    public static func merge(fileTerms: [String], otherTerms: [String]) -> KeytermSelection {
        limit(fileTerms + otherTerms)
    }
}
