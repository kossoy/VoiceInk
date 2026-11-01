import Foundation

/// Word error rate and Latin-term retention, ported from the dictation benchmark's
/// `score_real.py` so numbers from this harness compare with it directly:
/// NFC, lowercase, ё→е, every non-alphanumeric character → space.
public enum Scoring {
    public static func normalize(_ text: String) -> String {
        let lowered = text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "ё", with: "е")
        var out = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            out.append(isAlphanumeric(scalar) ? scalar : " ")
        }
        return String(out).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Python `str.isalnum()`: letter or numeric general categories.
    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// `^[a-z0-9]*[a-z][a-z0-9]*$` on a normalised token.
    public static func isLatin(_ token: String) -> Bool {
        var hasLetter = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A: hasLetter = true
            case 0x30...0x39: continue
            default: return false
            }
        }
        return hasLetter
    }

    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Word alignment by edit distance (same tie-breaking as `score_real.py`).
    public static func align(_ reference: [String], _ hypothesis: [String]) -> [(String?, String?)] {
        let n = reference.count
        let m = hypothesis.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(
                        d[i - 1][j] + 1, d[i][j - 1] + 1,
                        d[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
                }
            }
        }
        var out: [(String?, String?)] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0
                && d[i][j] == d[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
            {
                out.append((reference[i - 1], hypothesis[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                out.append((reference[i - 1], nil))
                i -= 1
            } else {
                out.append((nil, hypothesis[j - 1]))
                j -= 1
            }
        }
        return out.reversed()
    }

    /// Per-clip counts; sum them and divide for corpus-level rates.
    public struct Counts: Equatable, Sendable {
        public var wordErrors = 0
        public var referenceWords = 0
        public var referenceLatin = 0
        public var latinKept = 0
        public var exact = 0
        public var clips = 0

        public init() {}

        public static func + (lhs: Counts, rhs: Counts) -> Counts {
            var sum = lhs
            sum.wordErrors += rhs.wordErrors
            sum.referenceWords += rhs.referenceWords
            sum.referenceLatin += rhs.referenceLatin
            sum.latinKept += rhs.latinKept
            sum.exact += rhs.exact
            sum.clips += rhs.clips
            return sum
        }

        /// Percent, or nil without reference words.
        public var wer: Double? {
            referenceWords > 0 ? 100 * Double(wordErrors) / Double(referenceWords) : nil
        }

        public var latinKeptPercent: Double? {
            referenceLatin > 0 ? 100 * Double(latinKept) / Double(referenceLatin) : nil
        }
    }

    public static func score(reference: String, hypothesis: String) -> Counts {
        let r = words(reference)
        let h = words(hypothesis)
        var counts = Counts()
        counts.clips = 1
        counts.wordErrors = editDistance(r, h)
        counts.referenceWords = r.count
        counts.exact = r == h ? 1 : 0
        for (ref, hyp) in align(r, h) {
            if let ref, isLatin(ref) {
                counts.referenceLatin += 1
                if hyp == ref { counts.latinKept += 1 }
            }
        }
        return counts
    }

    /// Linear-interpolated percentile (`score_real.py` `pct`).
    public static func percentile(_ values: [Double], _ q: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let k = q * Double(sorted.count - 1)
        let f = Int(k)
        let c = min(f + 1, sorted.count - 1)
        return sorted[f] + (sorted[c] - sorted[f]) * (k - Double(f))
    }
}
