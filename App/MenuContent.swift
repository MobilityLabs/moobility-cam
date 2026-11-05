import AVFoundation
import MoobilityCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Now: \(model.background.current.title)\(model.background.isOverridden ? " (override)" : "")")

        Button("Backgrounds…") { open("backgrounds", title: "Backgrounds") }

        Menu("Override background") {
            Button("Use schedule") { model.background.override(nil) }
            Divider()
            ForEach(model.background.library.photos, id: \.file) { photo in
                overrideButton(.photo(photo))
            }
            Divider()
            ForEach(Season.allCases, id: \.self) { season in
                overrideButton(.season(season))
            }
        }

        Divider()
        if case .playing(let target) = model.replay.state {
            Text("Replaying: \(target.title)")
            Button("Go live") { model.goLive() }
            if case .last = target {
                Button(model.keptCurrentReplay ? "Kept" : "Keep this clip") { model.keepReplay() }
                    .disabled(model.keptCurrentReplay)
            }
        } else if case .loading = model.replay.state {
            Text("Loading replay…")
            Button("Go live") { model.goLive() }
        }
        Menu("Replay") {
            ForEach(ReplayTarget.presets, id: \.self) { target in
                Button(checked(model.replayTarget == target, target.title)) { model.play(target) }
            }
            let clips = model.clips
            if !clips.isEmpty {
                Divider()
                ForEach(clips, id: \.file) { clip in
                    let target = ReplayTarget.clip(file: clip.file)
                    Button(checked(model.replayTarget == target, clip.title)) { model.play(target) }
                }
            }
        }
        Button("Clips…") { open("clips", title: "Clips") }
        Button("Setup…") { model.showSetup() }
        Button("Check for Updates…") { model.updater.checkForUpdates() }
            .disabled(!model.updater.isRunning)
        Toggle("Hold recent video for replay", isOn: $model.holdRecent)

        Divider()
        ForEach(CameraMode.allCases, id: \.self) { mode in
            Button(checked(model.mode == mode, mode.title)) { model.mode = mode }
        }
        Divider()

        Menu("Source camera") {
            Button(checked(model.selectedSourceID == nil, "Automatic")) { model.selectSource(nil) }
            Divider()
            ForEach(CameraPipeline.availableSources(), id: \.uniqueID) { device in
                Button(checked(model.selectedSourceID == device.uniqueID, device.localizedName)) {
                    model.selectSource(device)
                }
            }
        }

        if let status = model.statusLine {
            Divider()
            Button("⚠︎ \(status)") {
                if let url = model.statusURL { NSWorkspace.shared.open(url) }
            }
            .disabled(model.statusURL == nil)
        }

        Divider()
        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Quit Moobility Cam") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A menu bar app isn't activated by its menu, so bring the window forward explicitly.
    private func open(_ id: String, title: String) {
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == title {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private func overrideButton(_ candidate: Candidate) -> some View {
        Button(checked(model.background.current == candidate, candidate.title)) {
            model.background.override(candidate.id)
        }
    }

    private func checked(_ on: Bool, _ title: String) -> String { on ? "✓ \(title)" : "    \(title)" }
}
