import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import MeetingSystem

// Speaker-attribution probe for a LIVE Teams call (selectors in TeamsAXSelectors).
//   --wake          try AXManualAccessibility/AXEnhancedUserInterface on Teams processes
//                   (the only write this tool performs). Diagnostics only: Teams 2 rejects
//                   both (-25205/-25208) and exposes its web tree without them.
//   --watch N       poll 4 Hz for N seconds, print JSONL events to stdout
//   --dump-tree P   save one bounded AX tree snapshot (roles, subroles, DOM classes,
//                   AXDescription/AXTitle; never AXValue, never text fields) to file P
//   --redact        replace names and window titles by short SHA-256 hashes
// Nothing is clicked, focused, joined or sent.

struct SpeakerProbeOptions {
    var wake = false
    var watchSeconds: Double?
    var dumpPath: String?
    var redact = false
    var maxNodes = 4_000

    static let flags: Set<String> = ["--wake", "--watch", "--dump-tree", "--redact"]

    static func wants(_ arguments: [String]) -> Bool {
        arguments.contains { ["--wake", "--watch", "--dump-tree"].contains($0) }
    }

    static func parse(_ arguments: [String]) throws -> SpeakerProbeOptions {
        var options = SpeakerProbeOptions()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--wake": options.wake = true
            case "--redact": options.redact = true
            case "--watch":
                guard let value = iterator.next(), let seconds = Double(value), (1...3_600).contains(seconds) else {
                    throw ProbeError.usage("--watch requires seconds from 1 to 3600")
                }
                options.watchSeconds = seconds
            case "--dump-tree":
                guard let path = iterator.next(), !path.hasPrefix("--") else {
                    throw ProbeError.usage("--dump-tree requires an output file path")
                }
                options.dumpPath = path
            case "--max-nodes":
                guard let value = iterator.next(), let count = Int(value), (1...20_000).contains(count) else {
                    throw ProbeError.usage("--max-nodes requires a value from 1 to 20000")
                }
                options.maxNodes = count
            default:
                throw ProbeError.usage("Unknown argument with speaker modes: \(argument)")
            }
        }
        return options
    }
}

struct SpeakerProbe {
    let options: SpeakerProbeOptions
    let started = ProcessInfo.processInfo.systemUptime

    func redact(_ text: String) -> String {
        guard options.redact else { return text }
        let digest = SHA256.hash(data: Data(text.lowercased().utf8))
        return "h:" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func emit(_ object: [String: Any]) {
        var event = object
        event["t"] = ((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded() / 1_000
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    func run() throws -> Int32 {
        let trusted = AXIsProcessTrusted()
        let apps = TeamsAXReader.teamsApplications()
        emit([
            "event": "start", "accessibilityTrusted": trusted,
            "teamsProcesses": apps.map { ["pid": $0.processIdentifier, "bundleID": $0.bundleIdentifier ?? ""] },
            "wake": options.wake, "redact": options.redact,
            "watchSeconds": options.watchSeconds ?? 0, "dumpTree": options.dumpPath != nil,
        ])
        guard trusted else {
            emit(["event": "error", "message": "Accessibility not granted to this terminal: System Settings > Privacy & Security > Accessibility"])
            return 2
        }
        guard !apps.isEmpty else {
            emit(["event": "error", "message": "Microsoft Teams is not running"])
            return 3
        }
        if options.wake {
            let result = TeamsAXReader.wake(apps)
            let accepted = result.values.contains { $0.values.contains(0) }
            emit(["event": "wake", "anyAccepted": accepted,
                  "results": result.map { pid, codes in
                      ["pid": pid, "results": codes.mapValues { TeamsAXReader.axErrorName($0) }] as [String: Any]
                  },
                  "note": accepted ? "" : "rejected; not required, the tree is read without it"])
            if accepted { Thread.sleep(forTimeInterval: 1.5) }  // Chromium builds the tree asynchronously.
        }
        if let path = options.dumpPath { try dumpTree(apps: apps, to: path) }
        if let seconds = options.watchSeconds { watch(apps: apps, seconds: seconds) }
        emit(["event": "end"])
        return 0
    }

    func dumpTree(apps: [NSRunningApplication], to path: String) throws {
        let nodes = TeamsAXReader.nodes(of: apps, maxNodes: options.maxNodes, maxSeconds: 10)
        let rows: [[String: Any]] = nodes.map { node in
            var row: [String: Any] = ["role": node.role]
            if let subrole = node.subrole { row["subrole"] = subrole }
            if !node.labels.isEmpty { row["labels"] = node.labels.map { redact(String($0.prefix(200))) } }
            if !node.domClasses.isEmpty { row["domClasses"] = node.domClasses }
            if let title = node.windowTitle { row["window"] = redact(title) }
            if let tile = node.tileLabel { row["tile"] = redact(String(tile.prefix(200))) }
            row["depth"] = node.depth
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["nodes": rows, "count": rows.count],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        emit(["event": "dump", "path": path, "nodes": rows.count,
              "speakingCandidates": nodes.filter { node in
                  node.labels.contains { TeamsSpeakerParser.speakingName(fromLabel: $0) != nil }
                      || node.domClasses.contains(where: TeamsAXSelectors.speakingTileDOMClasses.contains)
              }.count])
    }

    func watch(apps: [NSRunningApplication], seconds: Double) {
        var lastSpeaking: Set<String> = []
        var lastRoster: Set<String> = []
        var lastWindows: [String] = []
        var lastUnmuted: Set<String> = []
        var lastFrames: [String] = []
        var tracker = TeamsSpeakerTracker()
        let end = ProcessInfo.processInfo.systemUptime + seconds
        var polls = 0
        while ProcessInfo.processInfo.systemUptime < end {
            let tick = ProcessInfo.processInfo.systemUptime
            let nodes = TeamsAXReader.nodes(of: apps, maxNodes: options.maxNodes, maxSeconds: 0.2)
            let snapshot = TeamsSpeakerSnapshot.from(nodes: nodes)
            polls += 1
            let windows = Array(Set(nodes.compactMap(\.windowTitle))).sorted()
            if windows != lastWindows {
                emit(["event": "windows", "titles": windows.map(redact),
                      "compactView": windows.contains(where: TeamsSpeakerParser.isCompactView)])
                lastWindows = windows
            }
            if snapshot.speaking != lastSpeaking {
                emit(["event": "speaking", "names": snapshot.speaking.sorted().map(redact), "nodes": nodes.count])
                lastSpeaking = snapshot.speaking
            }
            if snapshot.unmuted != lastUnmuted {
                emit(["event": "unmuted", "names": snapshot.unmuted.sorted().map(redact)])
                lastUnmuted = snapshot.unmuted
            }
            let frames = nodes.filter { $0.domClasses.contains(where: TeamsAXSelectors.speakingTileDOMClasses.contains) }
                .map { node -> String in
                    guard let tile = node.tileLabel else { return "(no tile)" }
                    if TeamsSpeakerParser.isSelfTile(tile) { return "(self)" }
                    return TeamsSpeakerParser.tileName(fromLabel: tile).map(redact) ?? "(unparsed tile)"
                }
            if frames != lastFrames {
                emit(["event": "tileFrame", "owners": frames])
                lastFrames = frames
            }
            let roster = Set(nodes.filter { $0.role == "AXListItem" || $0.role == "AXRow" || $0.role == "AXCell" }
                .compactMap { $0.labels.first.flatMap(TeamsSpeakerParser.rosterName) })
            if roster != lastRoster {
                emit(["event": "roster", "names": roster.sorted().map(redact)])
                lastRoster = roster
            }
            let t = tick - started
            for cue in tracker.observe(snapshot, at: t) {
                emit(["event": "cue", "name": redact(cue.displayName), "start": cue.range.start, "end": cue.range.end])
            }
            if polls % 40 == 0 { emit(["event": "heartbeat", "polls": polls, "nodes": nodes.count]) }
            let sleep = 0.25 - (ProcessInfo.processInfo.systemUptime - tick)
            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
        }
        for cue in tracker.finish(at: ProcessInfo.processInfo.systemUptime - started) {
            emit(["event": "cue", "name": redact(cue.displayName), "start": cue.range.start, "end": cue.range.end])
        }
    }
}
