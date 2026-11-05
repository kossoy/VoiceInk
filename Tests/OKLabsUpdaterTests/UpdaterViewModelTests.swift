import Foundation
import XCTest

@testable import OKLabsUpdater

final class UpdaterViewModelTests: XCTestCase {
    func testStoredPreferencesAndAllUpdateActionsLeaveForkUpdaterDisabled() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let preferenceKeys = ["VoiceInkChecksForUpdatesOnLaunch", "SUEnableAutomaticChecks"]
            let previousValues = preferenceKeys.map { defaults.object(forKey: $0) }
            defer {
                for (key, previousValue) in zip(preferenceKeys, previousValues) {
                    if let previousValue {
                        defaults.set(previousValue, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }

            // Both the old Dashboard preference and Sparkle's current preference
            // may already be true in an installation. Neither may activate Sparkle
            // or be migrated/removed by the fork's updater initialization.
            for legacyPreference in [false, true] {
                for sparklePreference in [false, true] {
                    defaults.set(legacyPreference, forKey: preferenceKeys[0])
                    defaults.set(sparklePreference, forKey: preferenceKeys[1])

                    let updater = UpdaterViewModel()
                    XCTAssertTrue(UpdaterViewModel.isSparkleDisabled)
                    XCTAssertFalse(updater.canCheckForUpdates)
                    XCTAssertFalse(updater.automaticallyChecksForUpdates)

                    updater.setAutomaticallyChecksForUpdates(true)
                    updater.setChecksForUpdatesWhenDashboardAppears(true)
                    updater.checkForUpdates()
                    updater.checkForUpdatesIfDue()

                    XCTAssertFalse(updater.canCheckForUpdates)
                    XCTAssertFalse(updater.automaticallyChecksForUpdates)
                    XCTAssertFalse(updater.checksForUpdatesWhenDashboardAppears)
                    XCTAssertNil(updater.availableUpdate)
                    XCTAssertEqual(defaults.object(forKey: preferenceKeys[0]) as? Bool, legacyPreference)
                    XCTAssertEqual(defaults.object(forKey: preferenceKeys[1]) as? Bool, sparklePreference)
                }
            }
        }
    }
}
