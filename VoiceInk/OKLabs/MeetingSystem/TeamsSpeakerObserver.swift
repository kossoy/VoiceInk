import AppKit
import ApplicationServices
import Foundation
#if SWIFT_PACKAGE
import MeetingCore
#endif

// Teams active-speaker attribution through the Accessibility tree (the Granola approach):
// we read Teams desktop's own labels while a meeting recording runs and turn them into
// MeetingSpeakerCue ranges on the session clock. Voices are not analysed here; the
// diarization clusters get their names from these cues by majority vote
// (MeetingSpeakerNaming).
//
// Two signals, both verified on live calls (Teams 26289.204, 2026-11-11, two 600 s captures):
// 1. Main call window in front: the active speaker's tile (AXMenuItem, depth 21) gets a child
//    AXEmptyGroup with DOM class vdi-frame-occlusion: Teams' purple speaking border. It
//    followed the speakers in 73 of 73 changes, named someone 95% of the call (two at once
//    7%), switched within one 0.25 s poll, and dropped in silence (5%). The user's own tile
//    ("Myself video, ...") is excluded and never showed the border.
// 2. Main window not in front: the "Meeting compact view" window says "<Name> is speaking",
//    "Nobody is speaking" in silence. Only 1.8% of the first call, because compact view was
//    up only 15.5 s; it named a participant 74% of that time.
// Tiles: "Last, First, [video is on,] Has control of production tools, [muted,] Context menu
// is available". The web tree is readable without waking: AXManualAccessibility /
// AXEnhancedUserInterface writes fail (-25205/-25208), so the observer never writes to Teams.
//
// On by default; `defaults write com.prakashjoshipax.VoiceInk oklabs.meeting.teamsSpeakerObserver
// -bool NO` turns it off (an explicit value always wins). Needs Accessibility, which VoiceInk
// already has for pasting text; without it the observer stays idle.

/// Every Teams-specific string the observer matches, in one place.
public enum TeamsAXSelectors {
    /// Teams 2 main app and its WebView/helper processes.
    public static let bundlePrefixes = ["com.microsoft.teams2", "com.microsoft.teams"]
    /// Label suffixes announcing the active speaker, e.g. "Alex Smith is speaking" (verified).
    public static let speakingSuffixes = [" is speaking", ", speaking"]
    /// Compact view says "Nobody is speaking" during silence (verified); not a participant.
    public static let noSpeakerNames: Set<String> = ["nobody", "no one", "no-one", "someone"]
    /// Window that carries the speaking label; title "Meeting compact view | <meeting title>".
    public static let compactViewTitlePrefix = "Meeting compact view"
    /// DOM class of the speaking border inside the active speaker's tile (verified, main
    /// window). Counts only inside a tile; a frame without a tile ancestor names nobody.
    public static let speakingTileDOMClasses = ["vdi-frame-occlusion"]
    /// Participant tiles in the main call window (verified).
    public static let tileRole = "AXMenuItem"
    /// The user's own tile label starts with this part (verified).
    public static let selfTilePrefix = "myself video"
    /// Comma-separated tile parts that describe state, not the name (verified + likely variants).
    public static let tileStatusFragments = ["control of production tools", "menu is available", "context menu",
                                             "video is on", "video is off", "muted", "unmuted", "camera",
                                             "hand raised", "is presenting", "pinned", "spotlighted", "speaking",
                                             "fit to frame", "fill frame"]
    /// Parenthesised tags Teams appends to names.
    public static let nameTags = ["guest", "unverified", "external", "organizer", "organiser", "presenter",
                                  "attendee", "you", "me"]
    /// Trailing comma-separated status words on names in labels and the People pane.
    public static let nameStatusWords = ["meeting guest", "unmuted", "muted", "organizer", "organiser",
                                         "presenter", "attendee", "hand raised", "camera on", "camera off",
                                         "video on", "video off", "video is on", "video is off", "speaking",
                                         "external", "guest", "unverified", "in this meeting", "has left",
                                         "pinned", "spotlighted"]
    /// Attributes that ask Chromium-based apps to expose their web tree. Teams 2 rejects them
    /// and exposes the tree anyway; kept for the probe's --wake diagnostics only.
    public static let wakeAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]
    /// Attributes read from each node. AXValue is deliberately absent: it carries chat text.
    public static let labelAttributes = ["AXDescription", "AXTitle"]
    public static let domClassAttribute = "AXDOMClassList"
    /// Roles never descended into or read (chat composer, menus).
    public static let skippedRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXMenu", "AXMenuBar"]
}

/// Pure label parsing, unit-tested against strings recorded on a live call (names replaced).
public enum TeamsSpeakerParser {
    public static func isTeamsBundle(_ id: String) -> Bool {
        TeamsAXSelectors.bundlePrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    public static func isCompactView(_ windowTitle: String?) -> Bool {
        windowTitle?.hasPrefix(TeamsAXSelectors.compactViewTitlePrefix) ?? false
    }

    /// "Doe, Jane is speaking" -> "Doe, Jane"; nil when the label announces nobody.
    public static func speakingName(fromLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in TeamsAXSelectors.speakingSuffixes {
            guard trimmed.lowercased().hasSuffix(suffix) else { continue }
            let name = normalizeName(String(trimmed.dropLast(suffix.count)))
            return name.isEmpty || TeamsAXSelectors.noSpeakerNames.contains(name.lowercased()) ? nil : name
        }
        return nil
    }

    /// Strips Teams decorations: "(Guest)", "(Unverified)", ", Meeting guest", ", Unmuted", …
    /// Keeps "Last, First" commas when the remainder is not a known status word.
    public static func normalizeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        while let open = name.range(of: "(", options: .backwards),
            let close = name.range(of: ")", range: open.upperBound..<name.endIndex)
        {
            let tag = name[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            guard TeamsAXSelectors.nameTags.contains(tag) || tag.isEmpty else { break }
            name.removeSubrange(open.lowerBound..<close.upperBound)
        }
        var parts = name.components(separatedBy: ",")
        while parts.count > 1,
            TeamsAXSelectors.nameStatusWords.contains(parts.last!.trimmingCharacters(in: .whitespaces).lowercased())
        {
            parts.removeLast()
        }
        name = parts.joined(separator: ",")
        return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Main-window tile label -> participant name; nil for the user's own tile and non-tiles.
    /// "Doe, Jane, video is on, Has control of production tools, muted, Context menu is available"
    /// -> "Doe, Jane".
    public static func tileName(fromLabel label: String) -> String? {
        let parts = label.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.lowercased().hasPrefix(TeamsAXSelectors.selfTilePrefix) else {
            return nil
        }
        let nameParts = parts.prefix { part in
            let lower = part.lowercased()
            return !part.isEmpty && !TeamsAXSelectors.tileStatusFragments.contains { lower.contains($0) }
        }
        // A tile always has at least one status part; a label without any is not a tile.
        guard !nameParts.isEmpty, nameParts.count < parts.count else { return nil }
        let name = normalizeName(nameParts.joined(separator: ", "))
        return name.isEmpty ? nil : name
    }

    public static func isSelfTile(_ label: String) -> Bool {
        label.lowercased().hasPrefix(TeamsAXSelectors.selfTilePrefix)
    }

    /// Whether a tile label says the participant's mic is muted.
    public static func tileIsMuted(_ label: String) -> Bool {
        label.components(separatedBy: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "muted" }
    }

    /// Roster row label from the People pane -> participant name, nil for headers/buttons.
    public static func rosterName(fromLabel label: String) -> String? {
        let name = normalizeName(label)
        let lower = name.lowercased()
        let headers = ["participants", "people", "in this meeting", "invited", "attendees", "presenters",
                       "suggestions", "share invite", "mute all", "more options", "close"]
        guard !name.isEmpty, name.count <= 80, !headers.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return name
    }

    /// Stable participant id for a display name (case/space-insensitive).
    public static func participantID(for name: String) -> String {
        "teams:" + name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One Accessibility node reduced to what speaker attribution needs.
public struct TeamsAXNode: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var labels: [String]
    public var domClasses: [String]
    public var windowTitle: String?
    /// First label of the nearest AXMenuItem ancestor (the tile this node belongs to).
    public var tileLabel: String?
    public var depth: Int

    public init(role: String, subrole: String? = nil, labels: [String] = [], domClasses: [String] = [],
                windowTitle: String? = nil, tileLabel: String? = nil, depth: Int = 0) {
        self.role = role
        self.subrole = subrole
        self.labels = labels
        self.domClasses = domClasses
        self.windowTitle = windowTitle
        self.tileLabel = tileLabel
        self.depth = depth
    }
}

/// What one poll saw.
public struct TeamsSpeakerSnapshot: Equatable, Sendable {
    /// Names Teams marks as speaking now (union of both signals).
    public var speaking: Set<String>
    /// From the main-window tile border.
    public var framed: Set<String> = []
    /// From the compact-view "<Name> is speaking" label.
    public var labelled: Set<String> = []
    /// The border sat on the user's own tile (excluded from `speaking`; the mic track covers it).
    public var selfFramed = false
    /// Participants whose tile is not muted (diagnostics; unmuted is not speaking).
    public var unmuted: Set<String>
    public var compactView: Bool
    public var fingerprint: Int

    public init(speaking: Set<String>, unmuted: Set<String> = [], compactView: Bool = false, fingerprint: Int) {
        self.speaking = speaking
        self.unmuted = unmuted
        self.compactView = compactView
        self.fingerprint = fingerprint
    }

    public static func from(nodes: [TeamsAXNode]) -> TeamsSpeakerSnapshot {
        var framed = Set<String>()
        var labelled = Set<String>()
        var selfFramed = false
        var unmuted = Set<String>()
        var compact = false
        var hasher = Hasher()
        for node in nodes {
            hasher.combine(node.labels)
            hasher.combine(node.domClasses)
            if TeamsSpeakerParser.isCompactView(node.windowTitle) { compact = true }
            for label in node.labels {
                if let name = TeamsSpeakerParser.speakingName(fromLabel: label) { labelled.insert(name) }
            }
            if node.role == TeamsAXSelectors.tileRole, let label = node.labels.first,
                let name = TeamsSpeakerParser.tileName(fromLabel: label), !TeamsSpeakerParser.tileIsMuted(label)
            {
                unmuted.insert(name)
            }
            if node.domClasses.contains(where: TeamsAXSelectors.speakingTileDOMClasses.contains),
                let tile = node.tileLabel
            {
                if let name = TeamsSpeakerParser.tileName(fromLabel: tile) {
                    framed.insert(name)
                } else if TeamsSpeakerParser.isSelfTile(tile) {
                    selfFramed = true
                }
            }
        }
        var snapshot = TeamsSpeakerSnapshot(speaking: framed.union(labelled), unmuted: unmuted, compactView: compact,
                                            fingerprint: hasher.finalize())
        snapshot.framed = framed
        snapshot.labelled = labelled
        snapshot.selfFramed = selfFramed
        return snapshot
    }
}

/// Turns timed snapshots into cues: a speaker stays current for `hold` seconds after the last
/// sighting, so flickering labels do not split one turn. A missing snapshot (Teams gone,
/// tree unreadable) closes everything. `staleAfter` (off by default) closes cues when the
/// whole tree stops changing; a long monologue in compact view legitimately looks frozen.
public struct TeamsSpeakerTracker {
    public var hold: TimeInterval
    public var staleAfter: TimeInterval
    private var open: [String: (start: TimeInterval, lastSeen: TimeInterval)] = [:]
    private var lastFingerprint: Int?
    private var unchangedSince: TimeInterval?

    public init(hold: TimeInterval = 2.5, staleAfter: TimeInterval = .infinity) {
        self.hold = hold
        self.staleAfter = staleAfter
    }

    /// Feed one poll at session time `t`; returns cues that just closed.
    public mutating func observe(_ snapshot: TeamsSpeakerSnapshot?, at t: TimeInterval) -> [MeetingSpeakerCue] {
        var stale = snapshot == nil
        if let snapshot {
            if snapshot.fingerprint == lastFingerprint {
                if unchangedSince == nil { unchangedSince = t }
            } else {
                unchangedSince = nil
                lastFingerprint = snapshot.fingerprint
            }
            if let since = unchangedSince, t - since >= staleAfter { stale = true }
        }
        if !stale, let snapshot {
            for name in snapshot.speaking {
                if let current = open[name] { open[name] = (current.start, t) } else { open[name] = (t, t) }
            }
        }
        var closed: [MeetingSpeakerCue] = []
        for (name, span) in open where stale || t - span.lastSeen > hold {
            open[name] = nil
            if let cue = Self.cue(name, span.start, span.lastSeen) { closed.append(cue) }
        }
        return closed.sorted { $0.range.start < $1.range.start }
    }

    /// Close everything (recording paused or stopped) at session time `t`.
    public mutating func finish(at t: TimeInterval) -> [MeetingSpeakerCue] {
        let cues = open.compactMap { Self.cue($0.key, $0.value.start, min($0.value.lastSeen + hold, t)) }
        open = [:]
        lastFingerprint = nil
        unchangedSince = nil
        return cues.sorted { $0.range.start < $1.range.start }
    }

    private static func cue(_ name: String, _ start: TimeInterval, _ end: TimeInterval) -> MeetingSpeakerCue? {
        guard let range = try? MeetingTimeRange(start: start, end: max(start, end)) else { return nil }
        return MeetingSpeakerCue(participantID: TeamsSpeakerParser.participantID(for: name), displayName: name,
                                 range: range)
    }
}

/// Reads Teams' Accessibility tree. Shared by the observer and `.oklabs/meeting-probe`.
public enum TeamsAXReader {
    public static func teamsApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { TeamsSpeakerParser.isTeamsBundle($0.bundleIdentifier ?? "") }
    }

    /// Probe diagnostics only: tries the wake attributes and returns attribute -> AXError per pid.
    /// Teams 2 answers -25205/-25208 and exposes its tree regardless.
    @discardableResult
    public static func wake(_ apps: [NSRunningApplication]) -> [pid_t: [String: Int32]] {
        var result: [pid_t: [String: Int32]] = [:]
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            for attribute in TeamsAXSelectors.wakeAttributes {
                result[app.processIdentifier, default: [:]][attribute] =
                    AXUIElementSetAttributeValue(root, attribute as CFString, kCFBooleanTrue).rawValue
            }
        }
        return result
    }

    public static func axErrorName(_ code: Int32) -> String {
        switch code {
        case 0: return "success"
        case -25200: return "failure"
        case -25201: return "illegalArgument"
        case -25202: return "invalidUIElement"
        case -25204: return "cannotComplete"
        case -25205: return "attributeUnsupported"
        case -25208: return "notImplemented"
        case -25211: return "apiDisabled"
        default: return "error\(code)"
        }
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    public static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Breadth-first walk of all windows of `apps`, bounded by node count and time.
    public static func nodes(of apps: [NSRunningApplication], maxNodes: Int = 4_000,
                             maxSeconds: TimeInterval = 0.2) -> [TeamsAXNode] {
        let started = ProcessInfo.processInfo.systemUptime
        var out: [TeamsAXNode] = []
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                let title = string(window, kAXTitleAttribute)
                var queue: [(AXUIElement, String?, Int)] = [(window, nil, 0)]
                var index = 0
                while index < queue.count, out.count < maxNodes,
                    ProcessInfo.processInfo.systemUptime - started < maxSeconds
                {
                    let (element, tile, depth) = queue[index]
                    index += 1
                    AXUIElementSetMessagingTimeout(element, 0.03)
                    let role = string(element, kAXRoleAttribute) ?? ""
                    if TeamsAXSelectors.skippedRoles.contains(role) { continue }
                    let labels = TeamsAXSelectors.labelAttributes.compactMap { string(element, $0) }
                        .filter { !$0.isEmpty }
                    let classes = value(element, TeamsAXSelectors.domClassAttribute) as? [String] ?? []
                    out.append(TeamsAXNode(role: role, subrole: string(element, kAXSubroleAttribute),
                                           labels: labels, domClasses: classes, windowTitle: title,
                                           tileLabel: tile, depth: depth))
                    let childTile = role == TeamsAXSelectors.tileRole ? labels.first ?? tile : tile
                    if depth < 64, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                        queue.append(contentsOf: children.map { ($0, childTile, depth + 1) })
                    }
                }
            }
        }
        return out
    }
}

/// Polls Teams while a meeting recording runs and reports closed cues. Read-only.
@MainActor
public final class TeamsSpeakerObserver {
    nonisolated public static let enabledKey = "oklabs.meeting.teamsSpeakerObserver"
    /// Registered default: on. A value the user set (true or false) overrides it.
    nonisolated public static let defaultValue = true

    nonisolated public static func registerDefault(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [enabledKey: defaultValue])
    }

    nonisolated public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultValue
    }

    private let interval: TimeInterval
    private var tracker: TeamsSpeakerTracker
    private var timer: Timer?
    private var clock: (() -> TimeInterval)?
    private var onCue: (@MainActor (MeetingSpeakerCue) -> Void)?

    /// `interval` 0.25–0.5 s (2–4 Hz).
    public init(interval: TimeInterval = 0.25, tracker: TeamsSpeakerTracker = TeamsSpeakerTracker()) {
        self.interval = min(max(interval, 0.25), 0.5)
        self.tracker = tracker
    }

    public var isRunning: Bool { timer != nil }

    /// `clock` returns the session-relative time used by MeetingSession ranges.
    public func start(clock: @escaping () -> TimeInterval, onCue: @escaping @MainActor (MeetingSpeakerCue) -> Void) {
        guard timer == nil, AXIsProcessTrusted() else { return }
        self.clock = clock
        self.onCue = onCue
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling and delivers the cues still open (call before pausing/finishing the session).
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let clock { tracker.finish(at: clock()).forEach { onCue?($0) } }
        clock = nil
        onCue = nil
    }

    private func poll() {
        guard let clock else { return }
        let apps = TeamsAXReader.teamsApplications()
        let nodes = apps.isEmpty ? [] : TeamsAXReader.nodes(of: apps)
        let snapshot = nodes.isEmpty ? nil : TeamsSpeakerSnapshot.from(nodes: nodes)
        tracker.observe(snapshot, at: clock()).forEach { onCue?($0) }
    }
}
