import Foundation
import os

/// OKLabs fork: settings that must hold on every launch.
///
/// Runs in `App.init` right after `OnboardingV2Migration.prepareIfNeeded()`:
/// `AppDefaults.registerDefaults()` has registered upstream defaults by then (the
/// fork's registrations override them), and the migration has already deleted
/// pre-June mode storage, so the managed mode is not wiped after being written.
enum ManagedSettings {
    /// Fixed id so the managed mode is found again on every launch.
    static let modeId = UUID(uuidString: "0C1AB5C0-5C21-4BE0-A000-000000000001")!
    static let modeName = "Scribe"
    static let transcriptionModelName = "scribe_v2"

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OKLabsManagedSettings")

    static func applyAtLaunch(defaults: UserDefaults = .standard) {
        registerForkDefaults(defaults)
        guard defaults.bool(forKey: OKLabsSettings.Key.managedMode) else { return }
        guard defaults.bool(forKey: OnboardingSettings.completedV2Key) else {
            // Onboarding installs starter modes and picks its own default; take over
            // on the next launch (the settings script quits and relaunches the app).
            logger.notice("Managed mode deferred: onboarding not completed")
            return
        }
        upsertManagedMode()
    }

    /// Fork defaults: verbatim output, no self-update, no remote announcements.
    static func registerForkDefaults(_ defaults: UserDefaults) {
        OKLabsSettings.registerDefaults(defaults)
        defaults.register(defaults: [
            AutoLearnSettings.isEnabledKey: false,
            "VoiceInkChecksForUpdatesOnLaunch": false,
            "enableAnnouncements": false,
        ])
    }

    static func upsertManagedMode(manager: ModeManager = .shared) {
        var mode =
            manager.getConfiguration(with: modeId)
            ?? ModeConfig(
                id: modeId, name: modeName, icon: .symbol("waveform"), isAIEnhancementEnabled: false)
        let isNew = manager.getConfiguration(with: modeId) == nil

        mode.selectedTranscriptionModelName = transcriptionModelName
        mode.isRealtimeTranscriptionEnabled = true
        mode.selectedLanguage = "auto"
        mode.isAIEnhancementEnabled = false
        mode.isTextFormattingEnabled = false
        mode.useScreenCapture = false
        mode.useSelectedTextContext = false
        mode.useClipboardContext = false
        mode.outputMode = .paste
        mode.customCommand = nil
        // Per-app and per-URL modes win over the default; the managed mode claims none
        // and every other mode is disabled below.
        mode.appConfigs = nil
        mode.urlConfigs = nil
        mode.triggerGroups = nil
        mode.triggerWords = []
        mode.isEnabled = true
        mode.isDefault = true

        if isNew {
            manager.addConfiguration(mode)
        } else {
            manager.updateConfiguration(mode)
        }
        manager.setAsDefault(configId: modeId)

        var disabled: [String] = []
        for other in manager.configurations where other.id != modeId && other.isEnabled {
            manager.disableConfiguration(with: other.id)
            disabled.append(other.name)
        }
        manager.setActiveConfiguration(manager.getConfiguration(with: modeId))
        logger.notice(
            "Managed mode applied new=\(isNew, privacy: .public) disabledOthers=\(disabled.count, privacy: .public)"
        )
    }
}
