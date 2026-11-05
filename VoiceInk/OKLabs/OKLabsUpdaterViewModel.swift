#if OKLABS
import Combine
import Foundation
import SwiftUI

/// Fork updates are installed from kossoy/VoiceInk releases by voiceink-oklabs-update.
/// Keep this adapter free of Sparkle so upstream scheduler and preference migrations
/// cannot activate an updater that would replace the fork with an upstream release.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject {
    static let isSparkleDisabled = true

    let canCheckForUpdates = false
    let automaticallyChecksForUpdates = false

    func setAutomaticallyChecksForUpdates(_ value: Bool) {}
    func checkForUpdates() {}

    // Compatibility with Dashboard callers before upstream PR #1053. Keeping both
    // APIs lets this isolation fix land before the normal upstream sync runs.
    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    let checksForUpdatesWhenDashboardAppears = false
    let availableUpdate: AvailableUpdate? = nil

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool) {}
    func checkForUpdatesIfDue() {}
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
#endif
