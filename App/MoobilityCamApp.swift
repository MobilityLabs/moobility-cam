import MoobilityCore
import SwiftUI

@main
struct MoobilityCamApp: App {
    @StateObject private var model: AppModel

    init() {
        Self.quitIfAlreadyRunning()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        model.start()
    }

    /// A second copy would delete the first one's part files, so this runs before anything else.
    private static func quitIfAlreadyRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier }
            .map { SingleInstance.Running(pid: $0.processIdentifier, launched: $0.launchDate) }
        let mine = SingleInstance.Running(pid: me.processIdentifier, launched: me.launchDate)
        if SingleInstance.shouldQuit(me: mine, others: others) { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra("Moobility Cam", systemImage: model.isReplaying ? "repeat.circle.fill" : "camera") {
            MenuContent(model: model)
        }

        Window("Backgrounds", id: "backgrounds") {
            BackgroundsWindow(background: model.background)
        }
        .defaultSize(width: 920, height: 680)

        Window("Clips", id: "clips") {
            ClipsWindow(model: model)
        }
        .defaultSize(width: 720, height: 520)
    }
}
