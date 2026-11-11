import Foundation

/// One word of the cloud diarization pass, on the session clock.
public struct MeetingSpeakerWord: Codable, Equatable, Sendable {
    /// ElevenLabs' label, e.g. "speaker_0". Consistent within one request only.
    public let speakerID: String
    public let range: MeetingTimeRange
    public let text: String

    public init(speakerID: String, range: MeetingTimeRange, text: String) {
        self.speakerID = speakerID
        self.range = range
        self.text = text
    }
}

/// Raw output of the optional ElevenLabs Scribe v3 diarization pass over a meeting's stitched
/// system-audio track. Stored beside diarization.json as diarization-scribe.json and regenerated,
/// never edited. It only refines the local (FluidAudio) result: its speakers are mapped onto the
/// local clusters, whose IDs, numbering and user names stay authoritative. No audio, no embeddings.
public struct MeetingScribeDiarization: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let engine = "elevenlabs-scribe_v3"

    public let schemaVersion: Int
    public let engine: String
    public let createdAt: Date
    /// Seconds of audio uploaded (billable), including the silences between stitched chunks.
    public let audioSecondsSent: TimeInterval
    /// Wall-clock seconds of the pass (stitch, upload, transcription).
    public let processingSeconds: TimeInterval
    /// Number of requests the stitched track was sent in.
    public let requests: Int
    public let words: [MeetingSpeakerWord]

    public init(
        createdAt: Date = Date(), audioSecondsSent: TimeInterval, processingSeconds: TimeInterval,
        requests: Int = 1, words: [MeetingSpeakerWord]
    ) {
        schemaVersion = Self.currentSchemaVersion
        engine = Self.engine
        self.createdAt = createdAt
        self.audioSecondsSent = audioSecondsSent
        self.processingSeconds = processingSeconds
        self.requests = requests
        self.words = words.sorted { $0.range.start < $1.range.start }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw MeetingSessionError.unsupportedCheckpoint }
        for word in words {
            _ = try MeetingTimeRange(start: word.range.start, end: word.range.end)
            guard !word.speakerID.isEmpty else { throw MeetingSessionError.unsupportedCheckpoint }
        }
    }

    /// Consecutive words of one speaker merged into turns (for inspection and diagnostics).
    public var turns: [MeetingSpeakerTurn] {
        var result: [MeetingSpeakerTurn] = []
        for word in words {
            if let last = result.last, last.clusterID == word.speakerID, word.range.start - last.range.end < 1.0,
                let merged = try? MeetingTimeRange(start: last.range.start, end: max(last.range.end, word.range.end))
            {
                result[result.count - 1] = MeetingSpeakerTurn(clusterID: last.clusterID, range: merged)
            } else {
                result.append(MeetingSpeakerTurn(clusterID: word.speakerID, range: word.range))
            }
        }
        return result
    }

    /// Maps each cloud speaker to the local cluster it overlaps most. The winner must hold more
    /// than `minimumShare` (60 %, so a near-even split stays ambiguous) of that speaker's overlapped time and at least `minimumSeconds`;
    /// otherwise the speaker stays unmapped and its words are ignored.
    public func speakerMap(
        to local: MeetingDiarization, minimumShare: Double = 0.6, minimumSeconds: TimeInterval = 2
    ) -> [String: String] {
        var votes: [String: [String: TimeInterval]] = [:]
        for word in words {
            for turn in local.turns {
                let seconds = MeetingDiarization.overlap(word.range, turn.range)
                if seconds > 0 { votes[word.speakerID, default: [:]][turn.clusterID, default: 0] += seconds }
            }
        }
        var map: [String: String] = [:]
        for (speaker, tally) in votes {
            let total = tally.values.reduce(0, +)
            guard let best = tally.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                best.value >= minimumSeconds, best.value > total * minimumShare
            else { continue }
            map[speaker] = best.key
        }
        return map
    }
}

/// Uses the cloud words to refine the local clusters for one transcript line.
public struct MeetingScribeRefiner: Sendable {
    public let scribe: MeetingScribeDiarization
    /// Cloud speaker -> local cluster.
    public let speakerMap: [String: String]

    /// A line gets a cluster from the cloud words only if one cluster holds at least this share of them.
    public var assignShare = 0.6
    /// A line is split only if at least this share of its words could be aligned to cloud words...
    public var minimumAlignedShare = 0.5
    /// ...and each of the two strongest voices holds at least this share and `minimumSplitWords` words.
    public var minimumSplitShare = 0.25
    public var minimumSplitWords = 3

    public init(scribe: MeetingScribeDiarization, local: MeetingDiarization) {
        self.scribe = scribe
        speakerMap = scribe.speakerMap(to: local)
    }

    /// Cloud words whose midpoint lies in `range` (with a little slack for chunk-edge timing).
    func words(in range: MeetingTimeRange, slack: TimeInterval = 0.3) -> [MeetingSpeakerWord] {
        scribe.words.filter {
            let mid = ($0.range.start + $0.range.end) / 2
            return mid >= range.start - slack && mid <= range.end + slack
        }
    }

    /// The local cluster most of the line's cloud words belong to, for lines the local pass left unassigned.
    public func dominantCluster(for range: MeetingTimeRange) -> String? {
        var counts: [String: Int] = [:]
        var total = 0
        for word in words(in: range) {
            guard let cluster = speakerMap[word.speakerID] else { continue }
            counts[cluster, default: 0] += 1
            total += 1
        }
        guard total > 0,
            let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
            Double(best.value) >= Double(total) * assignShare
        else { return nil }
        return best.key
    }

    /// The line's own text cut into runs of one voice each, or nil when the line is one voice
    /// (or the evidence is too thin). Each run carries the local cluster of its words.
    public func split(text: String, range: MeetingTimeRange) -> [MeetingLinePart]? {
        let tokens = MeetingWordAligner.tokens(text)
        guard tokens.count >= minimumSplitWords * 2 else { return nil }
        let cloud = words(in: range)
        guard !cloud.isEmpty else { return nil }
        let alignment = MeetingWordAligner.align(tokens.map(\.key), cloud.map { MeetingWordAligner.key($0.text) })
        var clusters: [String?] = Array(repeating: nil, count: tokens.count)
        var aligned = 0
        for (lineIndex, cloudIndex) in alignment {
            guard let cluster = speakerMap[cloud[cloudIndex].speakerID] else { continue }
            clusters[lineIndex] = cluster
            aligned += 1
        }
        guard Double(aligned) >= Double(tokens.count) * minimumAlignedShare else { return nil }
        // Unaligned words take the voice of the nearest aligned word before them (else after).
        var last: String?
        for i in clusters.indices {
            if let c = clusters[i] { last = c } else { clusters[i] = last }
        }
        var next: String?
        for i in clusters.indices.reversed() {
            if let c = clusters[i] { next = c } else { clusters[i] = next }
        }
        var runs = Self.runs(clusters.map { $0 ?? "" })
        // Absorb short runs (a stray word or two) into the run before them, or after for the first.
        var merged = true
        while merged && runs.count > 1 {
            merged = false
            if let i = runs.indices.first(where: { runs[$0].count < minimumSplitWords }) {
                let target = i > 0 ? i - 1 : i + 1
                runs[target].count += runs[i].count
                if target > i { runs[target].start = runs[i].start }
                runs.remove(at: i)
                runs = Self.coalesce(runs)
                merged = true
            }
        }
        guard runs.count > 1 else { return nil }
        var perCluster: [String: Int] = [:]
        for run in runs { perCluster[run.cluster, default: 0] += run.count }
        let strongest = perCluster.values.sorted(by: >)
        guard strongest.count >= 2, strongest[1] >= minimumSplitWords,
            Double(strongest[1]) >= Double(tokens.count) * minimumSplitShare
        else { return nil }
        return runs.map { run in
            let slice = tokens[run.start..<(run.start + run.count)]
            let lower = slice.first!.range.lowerBound
            let upper = slice.last!.range.upperBound
            return MeetingLinePart(
                text: String(text[lower..<upper]), clusterID: run.cluster.isEmpty ? nil : run.cluster)
        }
    }

    struct Run: Equatable {
        var cluster: String
        var start: Int
        var count: Int
    }

    static func runs(_ labels: [String]) -> [Run] {
        var result: [Run] = []
        for (i, label) in labels.enumerated() {
            if let last = result.last, last.cluster == label {
                result[result.count - 1].count += 1
            } else {
                result.append(Run(cluster: label, start: i, count: 1))
            }
        }
        return result
    }

    static func coalesce(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.cluster == run.cluster {
                result[result.count - 1].count += run.count
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// One voice's share of a transcript line, in the line's own words.
public struct MeetingLinePart: Codable, Equatable, Sendable {
    public let text: String
    public let clusterID: String?

    public init(text: String, clusterID: String?) {
        self.text = text
        self.clusterID = clusterID
    }
}

/// Aligns the words of a transcript line with the cloud pass's words of the same audio.
enum MeetingWordAligner {
    struct Token {
        let key: String
        let range: Range<String.Index>
    }

    /// Whitespace-separated words with their position in `text`; the key ignores case and punctuation.
    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let s = start { result.append(Token(key: key(String(text[s..<index])), range: s..<index)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let s = start { result.append(Token(key: key(String(text[s...])), range: s..<text.endIndex)) }
        return result.filter { !$0.key.isEmpty }
    }

    static func key(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Longest common subsequence of equal keys: pairs of (line index, cloud index).
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
