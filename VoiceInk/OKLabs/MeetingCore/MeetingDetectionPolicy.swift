import Foundation

/// Application audio IO is a meeting hint, never speaker identity or permission to record.
public struct MeetingAppActivity: Equatable, Sendable {
    public let inputActive: Bool
    public let outputActive: Bool
    public let processCount: Int

    public init(inputActive: Bool, outputActive: Bool, processCount: Int = 1) {
        self.inputActive = inputActive
        self.outputActive = outputActive
        self.processCount = processCount
    }

    public var hasCallAudio: Bool { inputActive && outputActive }
}

/// Debounce transient device checks and notify once, even if the banner is dismissed.
/// Short gaps (mute/device switches) do not create a second meeting notification.
public struct MeetingDetectionPolicy {
    public enum Event: Equatable { case detected, ended }
    public private(set) var isMeetingActive = false
    private var candidateSince: TimeInterval?
    private var lastActiveAt: TimeInterval?
    private var lastObservation: TimeInterval?
    private var hasNotified = false
    private let confirmationDelay: TimeInterval
    private let endDelay: TimeInterval

    public init(confirmationDelay: TimeInterval = 4, endDelay: TimeInterval = 30) {
        self.confirmationDelay = confirmationDelay
        self.endDelay = endDelay
    }

    public mutating func observe(
        _ activity: MeetingAppActivity?, at now: TimeInterval, enabled: Bool = true, recording: Bool = false
    ) -> Event? {
        guard now.isFinite, now >= 0, now >= (lastObservation ?? 0) else { return nil }
        guard enabled else {
            let event: Event? = isMeetingActive ? .ended : nil
            reset()
            return event
        }
        // An unavailable CoreAudio snapshot does not prove that a meeting ended.
        guard let activity else {
            candidateSince = nil
            return nil
        }
        if !isMeetingActive, let previous = lastObservation, now - previous > 5 {
            candidateSince = nil
        }
        lastObservation = now
        if activity.hasCallAudio {
            lastActiveAt = now
            if candidateSince == nil { candidateSince = now }
            if now - (candidateSince ?? now) >= confirmationDelay {
                isMeetingActive = true
                if !hasNotified {
                    hasNotified = true
                    return recording ? nil : .detected
                }
            }
        } else {
            candidateSince = nil
            if isMeetingActive, let lastActiveAt, now - lastActiveAt >= endDelay {
                reset()
                return .ended
            }
        }
        return nil
    }

    private mutating func reset() {
        isMeetingActive = false
        candidateSince = nil
        lastActiveAt = nil
        lastObservation = nil
        hasNotified = false
    }
}

public enum MeetingPermissionState: String, Sendable {
    case notRequested, allowed, denied, restricted
    public var isAllowed: Bool { self == .allowed }
    public var actionTitle: String {
        switch self {
        case .notRequested: return "Allow"
        case .allowed: return "Allowed"
        case .denied: return "Open Settings"
        case .restricted: return "Restricted"
        }
    }
}

public struct MeetingPermissionSnapshot: Equatable, Sendable {
    public var microphone: MeetingPermissionState
    public var systemAudio: MeetingPermissionState
    public var isReady: Bool { microphone.isAllowed && systemAudio.isAllowed }

    public init(microphone: MeetingPermissionState, systemAudio: MeetingPermissionState) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
}
