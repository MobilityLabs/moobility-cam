import AppKit
import Sparkle

/// Sparkle's standard updater. Update checks are the only network use in the app.
@MainActor final class Updater {
    private var controller: SPUStandardUpdaterController?

    var isRunning: Bool { controller != nil }

    /// Updates can't install from outside Applications, so this starts only once the app is there.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
