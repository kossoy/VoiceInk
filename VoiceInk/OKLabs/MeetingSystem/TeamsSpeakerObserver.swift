import AppKit
import ApplicationServices
import Foundation
#if SWIFT_PACKAGE
import MeetingCore
#endif

// Teams active-speaker attribution through the Accessibility tree (the Granola approach):
// Teams desktop shows "<Name> is speaking" and per-participant tiles; we read those labels
// while a meeting recording runs and turn them into MeetingSpeakerCue ranges on the
// session clock. Voices are not analysed here.
//
// STATUS: selectors are UNCONFIRMED. They come from public reverse engineering of
// Teams 2 (see TeamsAXSelectors) and must be verified on a live call with
// `.oklabs/meeting-probe --watch`. The observer is off unless the user default
// `oklabs.meeting.teamsSpeakerObserver` is true.

/// Every Teams-specific string the observer matches, in one place.
public enum TeamsAXSelectors {
    /// Teams 2 main app and its WebView/helper processes.
    public static let bundlePrefixes = ["com.microsoft.teams2", "com.microsoft.teams"]
    /// Label suffixes announcing the active speaker, e.g. "Alex Smith is speaking".
    public static let speakingSuffixes = [" is speaking", ", speaking", " is talking"]
    /// DOM class Teams puts on the gallery tile of the participant who talks.
    public static let speakingTileDOMClasses = ["vdi-frame-occlusion"]
    /// Roles that carry the speaking label or the tile.
    public static let speakingRoles: Set<String> = ["AXGroup", "AXMenuItem", "AXButton", "AXStaticText"]
    /// Window of the floating call view while sharing the screen.
    public static let compactViewTitles = ["Meeting compact view"]
    public static let compactViewSubrole = "AXSystemDialog"
    /// Parenthesised tags and comma-separated status words Teams appends to names.
    public static let nameTags = ["guest", "unverified", "external", "organizer", "organiser", "presenter",
                                  "attendee", "you", "me"]
    public static let nameStatusWords = ["meeting guest", "unmuted", "muted", "organizer", "organiser",
                                         "presenter", "attendee", "hand raised", "camera on", "camera off",
                                         "video on", "video off", "speaking", "external", "guest", "unverified",
                                         "in this meeting", "has left", "pinned", "spotlighted"]
    /// Accessibility attributes that switch on the Chromium/WebView tree.
    public static let wakeAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]
    /// Attributes read from each node. AXValue is deliberately absent: it carries chat text.
    public static let labelAttributes = ["AXDescription", "AXTitle"]
    public static let domClassAttribute = "AXDOMClassList"
    /// Roles never descended into or read (chat composer, menus).
    public static let skippedRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXMenu", "AXMenuBar"]
}

/// Pure label parsing, unit-tested against recorded strings.
public enum TeamsSpeakerParser {
    public static func isTeamsBundle(_ id: String) -> Bool {
        TeamsAXSelectors.bundlePrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// "Alex Smith (Guest) is speaking" -> "Alex Smith"; nil when the label announces nobody.
    public static func speakingName(fromLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in TeamsAXSelectors.speakingSuffixes {
            guard trimmed.lowercased().hasSuffix(suffix) else { continue }
            let name = normalizeName(String(trimmed.dropLast(suffix.count)))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Strips Teams decorations: "(Guest)", "(Unverified)", ", Meeting guest", ", Unmuted", …
    /// Keeps the person's own words, including commas in "Smith, Alex" when the remainder is not
    /// a known status word.
    public static func normalizeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        // Parenthesised tags anywhere: "Alex (Guest)", "Alex (Unverified) (External)".
        while let open = name.range(of: "(", options: .backwards),
            let close = name.range(of: ")", range: open.upperBound..<name.endIndex)
        {
            let tag = name[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            guard TeamsAXSelectors.nameTags.contains(tag) || tag.isEmpty else { break }
            name.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // Trailing ", <status>" parts.
        var parts = name.components(separatedBy: ",")
        while parts.count > 1,
            TeamsAXSelectors.nameStatusWords.contains(parts.last!.trimmingCharacters(in: .whitespaces).lowercased())
        {
            parts.removeLast()
        }
        name = parts.joined(separator: ",")
        return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    public init(role: String, subrole: String? = nil, labels: [String] = [], domClasses: [String] = [],
                windowTitle: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.labels = labels
        self.domClasses = domClasses
        self.windowTitle = windowTitle
    }
}

/// What one poll saw.
public struct TeamsSpeakerSnapshot: Equatable, Sendable {
    public var speaking: Set<String>
    public var fingerprint: Int

    public init(speaking: Set<String>, fingerprint: Int) {
        self.speaking = speaking
        self.fingerprint = fingerprint
    }

    public static func from(nodes: [TeamsAXNode]) -> TeamsSpeakerSnapshot {
        var speaking = Set<String>()
        var hasher = Hasher()
        for node in nodes {
            hasher.combine(node.labels)
            hasher.combine(node.domClasses)
            guard TeamsAXSelectors.speakingRoles.contains(node.role) else { continue }
            for label in node.labels {
                if let name = TeamsSpeakerParser.speakingName(fromLabel: label) { speaking.insert(name) }
            }
            if node.domClasses.contains(where: TeamsAXSelectors.speakingTileDOMClasses.contains),
                let label = node.labels.first, let name = TeamsSpeakerParser.rosterName(fromLabel: label)
            {
                speaking.insert(name)
            }
        }
        return TeamsSpeakerSnapshot(speaking: speaking, fingerprint: hasher.finalize())
    }
}

/// Turns timed snapshots into cues: a speaker stays current for `hold` seconds after the last
/// sighting, so flickering labels do not split one turn. A tree that has not changed for
/// `staleAfter` seconds (Teams minimised, window frozen) stops extending cues.
public struct TeamsSpeakerTracker {
    public var hold: TimeInterval
    public var staleAfter: TimeInterval
    private var open: [String: (start: TimeInterval, lastSeen: TimeInterval)] = [:]
    private var lastFingerprint: Int?
    private var unchangedSince: TimeInterval?

    public init(hold: TimeInterval = 2.5, staleAfter: TimeInterval = 20) {
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

    /// Close everything (recording stopped) at session time `t`.
    public mutating func finish(at t: TimeInterval) -> [MeetingSpeakerCue] {
        let cues = open.compactMap { Self.cue($0.key, $0.value.start, min($0.value.lastSeen + hold, t)) }
        open = [:]
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

    /// Asks Chromium/WebView to build its tree. The only write; returns attribute -> AXError per pid.
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
                var queue = [window]
                var index = 0
                while index < queue.count, out.count < maxNodes,
                    ProcessInfo.processInfo.systemUptime - started < maxSeconds
                {
                    let element = queue[index]
                    index += 1
                    AXUIElementSetMessagingTimeout(element, 0.03)
                    let role = string(element, kAXRoleAttribute) ?? ""
                    if TeamsAXSelectors.skippedRoles.contains(role) { continue }
                    let labels = TeamsAXSelectors.labelAttributes.compactMap { string(element, $0) }
                        .filter { !$0.isEmpty }
                    let classes = value(element, TeamsAXSelectors.domClassAttribute) as? [String] ?? []
                    out.append(TeamsAXNode(role: role, subrole: string(element, kAXSubroleAttribute),
                                           labels: labels, domClasses: classes, windowTitle: title))
                    if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                        queue.append(contentsOf: children)
                    }
                }
            }
        }
        return out
    }
}

/// Polls Teams while a meeting recording runs and reports closed cues.
/// Disabled unless `UserDefaults[enabledKey]` is true (selectors still unconfirmed).
@MainActor
public final class TeamsSpeakerObserver {
    public static let enabledKey = "oklabs.meeting.teamsSpeakerObserver"
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    private let interval: TimeInterval
    private var tracker: TeamsSpeakerTracker
    private var timer: Timer?
    private var clock: (() -> TimeInterval)?
    private var onCue: ((MeetingSpeakerCue) -> Void)?

    /// `interval` 0.25–0.5 s (2–4 Hz).
    public init(interval: TimeInterval = 0.33, tracker: TeamsSpeakerTracker = TeamsSpeakerTracker()) {
        self.interval = min(max(interval, 0.25), 0.5)
        self.tracker = tracker
    }

    /// `clock` returns the session-relative time used by MeetingSession ranges.
    public func start(clock: @escaping () -> TimeInterval, onCue: @escaping (MeetingSpeakerCue) -> Void) {
        guard timer == nil, AXIsProcessTrusted() else { return }
        self.clock = clock
        self.onCue = onCue
        TeamsAXReader.wake(TeamsAXReader.teamsApplications())
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

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
