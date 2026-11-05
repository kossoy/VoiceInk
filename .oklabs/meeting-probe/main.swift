import AppKit
import ApplicationServices
import Foundation

// Read-only diagnostics. Never requests permissions, enables AX attributes, records audio,
// performs AX actions, or guesses which participant is currently speaking.
struct ProbeOptions {
    var includeLabels = false
    var maxNodes = 500
    var maxSeconds = 3.0
    var windowIndex: Int?

    static func parse() throws -> ProbeOptions {
        var options = ProbeOptions()
        var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--include-labels":
                options.includeLabels = true
            case "--window":
                guard let value = arguments.next(), let index = Int(value), index >= 0 else {
                    throw ProbeError.usage("--window requires a nonnegative window index")
                }
                options.windowIndex = index
            case "--max-nodes":
                guard let value = arguments.next(), let count = Int(value), (1...5_000).contains(count) else {
                    throw ProbeError.usage("--max-nodes requires a value from 1 to 5000")
                }
                options.maxNodes = count
            case "--max-seconds":
                guard let value = arguments.next(), let seconds = Double(value),
                    seconds.isFinite, (0.1...15).contains(seconds)
                else { throw ProbeError.usage("--max-seconds requires a value from 0.1 to 15") }
                options.maxSeconds = seconds
            case "--help", "-h":
                print("""
                Usage: meeting-probe [--window N] [--include-labels] [--max-nodes N] [--max-seconds N]

                Inspect only Microsoft Teams desktop Accessibility windows.
                Default: role/identifier/attribute metadata; label/title/value fields are omitted.
                --include-labels includes visible Teams labels and may contain personal or work content.
                It requires --window N to restrict label inspection to the selected call window.
                Prints JSON to stdout. Does not write files, capture media, or change Teams.
                An active call is required to investigate active-speaker signals.
                """)
                exit(0)
            default:
                throw ProbeError.usage("Unknown argument: \(argument)")
            }
        }
        if options.includeLabels && options.windowIndex == nil {
            throw ProbeError.usage("--include-labels requires --window N")
        }
        return options
    }
}

enum ProbeError: Error {
    case usage(String)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func inspect(_ app: NSRunningApplication, options: ProbeOptions) -> [String: Any] {
    let started = ProcessInfo.processInfo.systemUptime
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.05)
    var value: CFTypeRef?
    let windowsStatus = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
    let windows = value as? [AXUIElement] ?? []
    var pending = windows.enumerated()
        .filter { options.windowIndex == nil || $0.offset == options.windowIndex }
        .map { ($0.element, [$0.offset]) }
    var offset = 0
    var seen = Set<CFHashCode>()
    var nodes: [[String: Any]] = []
    let labelAttributes = ["AXTitle", "AXDescription", "AXHelp", "AXValue"]
    while offset < pending.count && nodes.count < options.maxNodes
        && ProcessInfo.processInfo.systemUptime - started < options.maxSeconds
    {
        let (element, path) = pending[offset]
        offset += 1
        guard seen.insert(CFHash(element)).inserted else { continue }
        AXUIElementSetMessagingTimeout(element, 0.03)
        let role = attribute(element, "AXRole") as? String ?? ""
        // Editable chat content and app menus are irrelevant to speaker attribution.
        if ["AXTextArea", "AXTextField", "AXComboBox", "AXMenu", "AXMenuBar"].contains(role) { continue }
        var node: [String: Any] = ["path": path, "role": role]
        if let identifier = attribute(element, "AXIdentifier") as? String { node["identifier"] = identifier }
        if let subrole = attribute(element, "AXSubrole") as? String { node["subrole"] = subrole }
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success, let names {
            node["attributes"] = names as? [String] ?? []
        }
        if options.includeLabels {
            for name in labelAttributes {
                if let label = attribute(element, name) as? String { node[name] = String(label.prefix(500)) }
            }
        }
        nodes.append(node)
        if path.count < 32, let children = attribute(element, "AXChildren") as? [AXUIElement] {
            pending.append(contentsOf: children.enumerated().map { ($0.element, path + [$0.offset]) })
        }
    }
    let version = app.bundleURL.flatMap(Bundle.init(url:))?
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return [
        "bundleID": app.bundleIdentifier ?? "",
        "version": version,
        "processID": app.processIdentifier,
        "windowCount": windows.count,
        "windowReadStatus": windowsStatus.rawValue,
        "requestedWindowFound": options.windowIndex.map { windows.indices.contains($0) } ?? true,
        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
        "truncated": offset < pending.count,
        "nodes": nodes,
    ]
}

do {
    let options = try ProbeOptions.parse()
    let trusted = AXIsProcessTrusted()
    let apps = ["com.microsoft.teams2", "com.microsoft.teams"].flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }
    let report: [String: Any] = [
        "sampledAt": ISO8601DateFormatter().string(from: Date()),
        "accessibilityTrusted": trusted,
        "teamsRunning": !apps.isEmpty,
        "labelsIncluded": options.includeLabels,
        "speakerAttribution": "unverified: inspect a live call before implementing an adapter",
        "applications": trusted ? apps.map { inspect($0, options: options) } : [],
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if !trusted { exit(2) }
} catch {
    FileHandle.standardError.write(Data("meeting-probe: \(error)\n".utf8))
    exit(1)
}
