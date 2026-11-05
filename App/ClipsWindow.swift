import AVFoundation
import MoobilityCore
import SwiftUI

struct ClipsWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // `clipsRevision` makes the list re-read after the app changes the folder.
        let clips = model.clips
        VStack(spacing: 0) {
            topBar
            Divider()
            if let message = model.clipMessage ?? model.replayMessage ?? model.hotKeyProblem {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            if clips.isEmpty {
                ContentUnavailableView {
                    Text("No clips yet. Record one, or save the last few minutes during a call.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(clips, id: \.file) { clip in
                    ClipRow(model: model, clip: clip)
                }
                .id(model.clipsRevision)
            }
        }
        .frame(minWidth: 620, minHeight: 360)
        .sheet(isPresented: Binding(get: { model.recordSheetOpen },
                                    set: { if !$0 { model.closeRecordSheet() } })) {
            RecordSheet(model: model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Record…") { model.openRecordSheet() }
                .disabled(model.replay.isActive)
            // Recent video fills without publishing anything, so this re-checks it on a schedule.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Menu("Save last") {
                    ForEach(ReplayTarget.presets, id: \.self) { target in
                        if case .last(let seconds) = target {
                            Button(target.title) { model.saveLast(seconds) }
                        }
                    }
                }
                .fixedSize()
                .disabled(model.heldSeconds < ReplayConstants.minLength)
            }
            Spacer()
            Text("Hotkey").foregroundStyle(.secondary)
            HotKeyRecorder(combo: model.hotKeyCombo) { model.setHotKey($0) }
            Text("plays \(model.replayTarget.title)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
    }
}

private struct ClipRow: View {
    @ObservedObject var model: AppModel
    let clip: Clip

    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    @FocusState private var nameFocused: Bool

    private var target: ReplayTarget { .clip(file: clip.file) }
    private var isPlaying: Bool { model.replay.state == .playing(target: target) }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { editing = false; problem = nil }
                } else {
                    Text(clip.title)
                        .lineLimit(1)
                        .onTapGesture {
                            draft = clip.title
                            editing = true
                            nameFocused = true
                        }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text(ClipTime.text(duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button(isPlaying ? "Stop" : "Play") {
                if isPlaying { model.goLive() } else { model.playOnly(target) }
            }
            Button(model.replayTarget == target ? "✓ For hotkey" : "Use for hotkey") { model.useForHotkey(clip) }
                .disabled(model.replayTarget == target)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.clipURL(clip)]) }
            Divider()
            Button("Delete") { model.deleteClip(clip) }
        }
        .task(id: clip.file) { await loadDetails() }
    }

    private func commitRename() {
        if let message = model.renameClip(clip, to: draft) {
            problem = message
        } else {
            problem = nil
            editing = false
        }
    }

    private func loadDetails() async {
        let asset = AVURLAsset(url: model.clipURL(clip))
        duration = (try? await asset.load(.duration))?.seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        if let image = try? await generator.image(at: .zero).image {
            thumbnail = NSImage(cgImage: image, size: .zero)
        }
    }
}

/// Click, then press the new shortcut. Esc cancels. It must include ⌘, ⌃ or ⌥.
private struct HotKeyRecorder: View {
    let combo: HotKeyCombo
    let onChange: (HotKeyCombo) -> Void

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button(listening ? "Press keys…" : combo.display) {
            if listening { stop() } else { start() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
                return nil
            }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= 256 }
            if event.modifierFlags.contains(.shift) { modifiers |= 512 }
            if event.modifierFlags.contains(.option) { modifiers |= 2048 }
            if event.modifierFlags.contains(.control) { modifiers |= 4096 }
            guard let new = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers) else {
                return nil  // keep listening for one with ⌘, ⌃ or ⌥
            }
            onChange(new)
            stop()
            return nil
        }
    }

    private func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
