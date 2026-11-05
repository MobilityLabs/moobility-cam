import AppKit
@preconcurrency import AVFoundation
import Security
import Combine
import Foundation
import MoobilityCore
import os
import ServiceManagement
import SwiftUI

/// Wires the watcher, sink, pipeline, background and installer together and owns the menu's status line.
@MainActor final class AppModel: ObservableObject {
    let installer = ExtensionInstaller()
    let background = BackgroundController()
    private let watcher = ClientWatcher()
    private nonisolated let sink = SinkConnection()
    private lazy var pipeline = CameraPipeline(sink: sink)
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "App")
    private let clipStore = ClipStore()
    private let hotKey = HotKey()
    let updater = Updater()

    @Published var mode: CameraMode = CameraMode(rawValue: UserDefaults.standard.string(forKey: "cameraMode") ?? "")
        ?? .overBackground {
        didSet { modeChanged() }
    }
    @Published private(set) var cameraDenied = false
    @Published private(set) var cameraAccess = AppModel.currentCameraAccess()
    @Published private(set) var setupMessage: String?
    @Published private(set) var setupRevealPath: URL?
    /// The extension is approved, but macOS isn't running it. Replacing a running one can leave this until a restart.
    @Published private(set) var restartNeeded = false
    @Published private(set) var isMoving = false
    private var extensionActiveSince: Date?
    @Published private(set) var cameraUnavailable = false
    @Published private(set) var notReady = false
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published private(set) var replay = ReplayMachine()
    @Published private(set) var replayTarget = ReplayTarget(stored: UserDefaults.standard.string(forKey: "replayTarget") ?? "")
        ?? .default
    @Published private(set) var replayMessage: String?
    @Published private(set) var keptCurrentReplay = false
    @Published private(set) var hotKeyCombo = HotKeyCombo(stored: UserDefaults.standard.string(forKey: "replayHotKey") ?? "")
        ?? .default
    @Published private(set) var hotKeyProblem: String?

    /// The Record sheet holds the webcam on its own, with no sink.
    @Published private(set) var recordSheetOpen = false
    @Published private(set) var recordingCountdown: Int?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed = 0.0
    @Published private(set) var cameraQuiet = false
    @Published private(set) var clipMessage: String?
    /// Bumped when the app changes the clips folder, so the window re-reads it.
    @Published private(set) var clipsRevision = 0
    @Published var holdRecent = UserDefaults.standard.object(forKey: "holdRecentVideo") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(holdRecent, forKey: "holdRecentVideo")
            if !holdRecent { pipeline.wipeRecent() }
            updateRecentHolding()
        }
    }

    /// True while the virtual camera is sending looped footage. Stays true while switching to another target.
    var isReplaying: Bool { replay.isOutputReplay }
    var clips: [Clip] { clipStore.list() }
    var captureSession: AVCaptureSession { pipeline.captureSession }
    var heldSeconds: Double { pipeline.replay.heldSeconds }
    func clipURL(_ clip: Clip) -> URL { clipStore.url(of: clip.file) }
    /// Whether the Record sheet's Start can work at all.
    var canRecord: Bool { cameraAuthorized == true && currentSource() != nil && !cameraQuiet }
    var recordProblem: String? {
        if cameraAuthorized != true { return "Camera access needed" }
        if currentSource() == nil || cameraQuiet { return "Camera unavailable" }
        return nil
    }

    /// A load in flight, and what's on screen for Keep this clip.
    private var loadCancel: CancelFlag?
    private var playingFootage: ReplayEngine.Footage?

    private var sheetTimer: Timer?
    private var countdownEnds: Date?
    private var recordingStartedAt = Date()
    private var sheetOpenedAt = Date()
    private var recordingPart: (url: URL, base: String)?

    private var wantsCapture = false
    private var capturing = false {
        didSet { updateRecentHolding() }
    }
    /// nil until the camera permission prompt is answered; capture waits for `true`.
    private var cameraAuthorized: Bool? {
        switch cameraAccess {
        case .granted: true
        case .denied: false
        case .notAsked: nil
        }
    }
    /// 4 s, not less: Continuity cameras can take a few seconds to deliver a first frame.
    private var watchdog = FrameWatchdog(timeout: 4)
    private var sinkFailures = FailureClock()
    private var retryTimer: Timer?
    private var bag: Set<AnyCancellable> = []

    var statusLine: String? {
        if restartNeeded || installer.status == .needsRestart { return Self.restartMessage }
        if cameraDenied { return "Camera access needed" }
        switch installer.status {
        case .needsApproval, .failed: return "Allow Moobility Cam extension in System Settings"
        default: break
        }
        if cameraUnavailable { return "Camera unavailable" }
        if notReady { return "Moobility Cam not ready" }
        return replayMessage ?? hotKeyProblem ?? clipMessage ?? background.problem?.message
    }

    var statusURL: URL? {
        switch statusLine {
        case "Camera access needed":
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        case "Allow Moobility Cam extension in System Settings":
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        default: nil
        }
    }

    func start() {
        installer.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.setupProgressed() }
        }.store(in: &bag)
        background.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCameraAccess() }
        }
        cameraDenied = cameraAccess == .denied
        if SetupState(setupFacts).opensAtLaunch(finishedBefore: setupFinished) { showSetup() }
        // Outside Applications, nothing else starts: macOS refuses the extension from there,
        // and a copy on a DMG mustn't feed an extension an installed copy already set up.
        guard inApplications else { return }

        if LoginItemPolicy.shouldRegister(Self.loginItemState(), userOptedOut: UserDefaults.standard.bool(forKey: Self.optOutKey),
                                          bundlePath: Bundle.main.bundlePath) {
            do { try SMAppService.mainApp.register() } catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        background.onChange = { [weak self] image in self?.pipeline.setBackground(image) }
        background.start()
        pipeline.setMode(mode)
        clipStore.removeLeftoverParts()
        hotKey.onPress = { [weak self] in self?.toggleReplay() }
        if !hotKey.register(hotKeyCombo) { hotKeyProblem = Self.hotKeyInUse }
        pipeline.replay.onRecordingMustStop = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        pipeline.replay.onPlaybackFailed = { [weak self] in
            DispatchQueue.main.async { self?.playbackFailed() }
        }

        installer.onActivated = { [weak self] in
            self?.extensionActiveSince = Date()
            self?.watcher.retryNow()
        }
        installer.activate()

        sink.onFailure = { [weak self] in
            DispatchQueue.main.async { self?.captureFailed() }
        }
        watcher.onChange = { [weak self] capture in self?.setWantsCapture(capture) }
        watcher.onLookupStateChange = { [weak self] in self?.checkHealth() }

        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.sourceDisconnected(id) }
        }

        watcher.start()
        updater.start()
        // A first run asks from the setup window, with the reason on screen.
        if setupFinished, cameraAccess == .notAsked { allowCamera() }
    }

    // MARK: Setup

    private static let installedApp = URL(fileURLWithPath: "/Applications/MoobilityCam.app")
    private static let restartMessage = "Restart your Mac to finish updating the camera"
    private static let relaunchedForDeviceKey = "relaunchedForDevice"
    private static let hasSeenClientKey = "hasSeenClient"
    private static let setupFinishedKey = "setupFinished"

    private var setupWindow: NSWindow?
    private var setupFinished: Bool {
        get { UserDefaults.standard.bool(forKey: Self.setupFinishedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.setupFinishedKey) }
    }

    var inApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL == Self.installedApp.standardizedFileURL
    }

    var setupFacts: SetupFacts {
        SetupFacts(inApplications: inApplications, camera: cameraAccess, extensionActive: installer.status == .active,
                   hasSeenClient: UserDefaults.standard.bool(forKey: Self.hasSeenClientKey))
    }

    private static func currentCameraAccess() -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// A grant in System Settings doesn't reach the app any other way.
    func refreshCameraAccess() {
        let current = Self.currentCameraAccess()
        guard current != cameraAccess else { return }
        cameraAccess = current
        cameraDenied = current == .denied
        guard inApplications else { return }
        if current == .granted { tryStartCapture() } else { stopCapture() }
        setupProgressed()
    }

    func allowCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshCameraAccess() }
        }
    }

    private func setupProgressed() {
        if SetupState(setupFacts).isComplete, !setupFinished { setupFinished = true }
        objectWillChange.send()
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupWindow(model: self)))
            window.title = "Set up Moobility Cam"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.center()
        setupWindow?.makeKeyAndOrderFront(nil)
        setupWindow?.orderFrontRegardless()
    }

    func openSettings(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func revealForDragging() {
        NSWorkspace.shared.activateFileViewerSelecting([setupRevealPath ?? Bundle.main.bundleURL])
    }

    func moveToApplications() {
        guard !isMoving else { return }
        setupMessage = nil
        setupRevealPath = nil
        let source = Bundle.main.bundleURL
        let destination = Self.installedApp
        let myBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        switch AppMover.decide(runningFrom: source, destination: destination, myBuild: myBuild,
                               installed: Self.installedCopy(at: destination)) {
        case .alreadyInPlace:
            return
        case .openInstalled:
            handOff(to: destination)
        case .blockedByUnreadable:
            setupMessage = "There's a Moobility Cam in Applications that can't be verified. Move it to the Trash, then try again."
            setupRevealPath = destination
        case .installFresh, .replaceOlder:
            isMoving = true
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try AppMover.install(from: source, to: destination, ops: .live)
                    await self?.handOff(to: destination)
                } catch let error as AppMover.MoveError {
                    await self?.moveFailed(error)
                } catch {
                    await self?.moveFailed(.copyFailed)
                }
            }
        }
    }

    private static func installedCopy(at url: URL) -> InstalledCopy {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard isSignedLikeThisApp(url) else { return .unreadable }
        let version = Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
        return version.flatMap(Int.init).map(InstalledCopy.build) ?? .unreadable
    }

    /// Handing off launches whatever is at that path, so it has to be this app from this team, whatever its version says.
    private static func isSignedLikeThisApp(_ url: URL) -> Bool {
        var me: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              let myStatic = staticCode(of: me),
              SecCodeCopySigningInformation(myStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = Bundle.main.bundleIdentifier else { return false }
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func staticCode(of code: SecCode) -> SecStaticCode? {
        var result: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &result) == errSecSuccess ? result : nil
    }

    private func moveFailed(_ error: AppMover.MoveError) {
        isMoving = false
        if case .restoreFailed(let backup) = error {
            setupMessage = "The older copy couldn't be put back. It's at \(backup)."
            setupRevealPath = URL(fileURLWithPath: backup)
        } else {
            setupMessage = "Couldn't move it. Drag Moobility Cam to Applications."
        }
        log.error("move to Applications failed: \(String(describing: error), privacy: .public)")
    }

    /// An approved extension whose device doesn't appear has one of two causes. This process's view of the
    /// device list can be stale after a replacement, and only a fresh process sees past that, so it relaunches
    /// once. If the device is still missing after that, macOS isn't running the extension, and that takes a restart.
    private func checkDevicePresent(at now: Date) {
        guard let since = watcher.lookupFailingSince else {
            if restartNeeded { restartNeeded = false }
            UserDefaults.standard.removeObject(forKey: Self.relaunchedForDeviceKey)
            return
        }
        switch DeviceRecovery.next(missingSince: since, activeSince: extensionActiveSince, now: now,
                                   alreadyRelaunched: UserDefaults.standard.bool(forKey: Self.relaunchedForDeviceKey)) {
        case .wait:
            break
        case .relaunch:
            log.info("device absent; relaunching once")
            UserDefaults.standard.set(true, forKey: Self.relaunchedForDeviceKey)
            handOff(to: Bundle.main.bundleURL)
        case .askForRestart:
            if !restartNeeded {
                log.error("device still absent after relaunching")
                restartNeeded = true
            }
        }
    }

    /// The new copy must start after this one exits, or it would quit as a duplicate and leave nothing running.
    private func handOff(to app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"", "sh",
                            String(ProcessInfo.processInfo.processIdentifier), app.path]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            moveFailed(.copyFailed)
        }
    }

    // MARK: Menu actions

    func selectSource(_ device: AVCaptureDevice?) {
        selectedSourceID = device?.uniqueID
        sourceLeaving()
        endReplay(.sourceChanged)
        pipeline.wipeRecent()
        useCurrentSource()
    }

    // MARK: Replay

    private static let hotKeyInUse = "That hotkey is in use"

    func setHotKey(_ combo: HotKeyCombo) {
        clipMessage = nil
        guard hotKey.register(combo) else {
            hotKeyProblem = Self.hotKeyInUse
            return
        }
        hotKeyProblem = nil
        hotKeyCombo = combo
        UserDefaults.standard.set(combo.stored, forKey: "replayHotKey")
    }

    /// The hotkey: start the target, or go live when a replay is loading or playing.
    func toggleReplay() {
        if replay.isActive { goLive() } else { start(replayTarget, isHotkey: true) }
    }

    /// The menu: choosing an item makes it the target and starts it.
    func play(_ target: ReplayTarget) {
        setReplayTarget(target)
        start(target, isHotkey: false)
    }

    /// The Clips window's Play: starts it without changing what the hotkey plays.
    func playOnly(_ target: ReplayTarget) {
        start(target, isHotkey: false)
    }

    func goLive() {
        replayMessage = nil
        clipMessage = nil
        endReplay(.goLive)
    }

    func keepReplay() {
        guard case .playing(let target) = replay.state, case .last = target, let footage = playingFootage else { return }
        keptCurrentReplay = true
        save(footage, title: target.title)
    }

    /// The Clips window's Save last: keeps recent video without playing it.
    func saveLast(_ seconds: Int) {
        clipMessage = nil
        let target = ReplayTarget.last(seconds: seconds)
        pipeline.snapshotRecent(seconds: Double(seconds)) { [weak self] footage in
            DispatchQueue.main.async {
                guard let self else { return }
                let length = footage.reduce(0) { $0 + $1.duration }
                guard length >= ReplayConstants.minLength else {
                    self.clipMessage = ReplayRefusal.notEnoughVideo.message
                    return
                }
                self.save(footage, title: target.title)
            }
        }
    }

    private func save(_ footage: ReplayEngine.Footage, title: String) {
        let store = clipStore
        let base = ClipStore.defaultBase(title, at: Date(), timeZone: .current)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let part = try store.newPartURL(base: base)
                do {
                    try await ClipFile.write(footage, to: part)
                    _ = try store.publish(part: part, base: base)
                } catch {
                    try? FileManager.default.removeItem(at: part)
                    throw error
                }
                await self?.clipsChanged()
            } catch {
                await self?.showClipProblem("Couldn't save the clip")
            }
        }
    }

    private func clipsChanged() {
        clipsRevision += 1
    }

    private func showClipProblem(_ message: String) {
        clipMessage = message
        keptCurrentReplay = false  // a failed Keep can be tried again
    }

    // MARK: Clips

    /// Returns a message when the name is refused; the old name stays.
    func renameClip(_ clip: Clip, to title: String) -> String? {
        do {
            var wasLoading = false
            if case .loading(_, .clip(clip.file), _) = replay.state { wasLoading = true }
            let newFile = try clipStore.rename(clip.file, to: title)
            replay.clipRenamed(from: clip.file, to: newFile)
            setReplayTarget(replayTarget.afterRenaming(clip.file, to: newFile))
            // The read in flight has the old path, so start it again under the new one.
            if wasLoading { start(.clip(file: newFile), isHotkey: false) }
            clipsChanged()
            return nil
        } catch let error as ClipNameError {
            return error.message
        } catch {
            return "Couldn't rename the clip"
        }
    }

    func deleteClip(_ clip: Clip) {
        if case .loading(_, .clip(clip.file), _) = replay.state {
            loadCancel?.cancel()
            loadCancel = nil
        }
        replay.clipRemoved(file: clip.file)
        do {
            try clipStore.delete(clip.file)
            setReplayTarget(replayTarget.afterRemoving(file: clip.file))
            clipsChanged()
        } catch {
            clipMessage = "Couldn't delete the clip"
        }
    }

    func useForHotkey(_ clip: Clip) {
        setReplayTarget(.clip(file: clip.file))
    }

    // MARK: Recording

    func openRecordSheet() {
        guard !replay.isActive else { return }
        clipMessage = nil
        recordSheetOpen = true
        cameraQuiet = false
        recordingElapsed = 0
        sheetOpenedAt = Date()
        pipeline.setCameraWanted(true, device: currentSource())
        sheetTimer?.invalidate()
        sheetTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sheetTick() }
        }
    }

    /// Closing while recording stops and saves.
    func closeRecordSheet() {
        stopRecording()
        recordingCountdown = nil
        countdownEnds = nil
        sheetTimer?.invalidate()
        sheetTimer = nil
        recordSheetOpen = false
        pipeline.setCameraWanted(false, device: nil)
    }

    func beginCountdown() {
        guard canRecord, !isRecording, countdownEnds == nil else { return }
        countdownEnds = Date().addingTimeInterval(ReplayConstants.countdown)
        recordingCountdown = Int(ReplayConstants.countdown)
    }

    private func sheetTick() {
        let now = Date()
        let last = pipeline.lastFrameAt ?? .distantPast
        let quiet = now.timeIntervalSince(max(last, sheetOpenedAt)) >= 4
        if quiet != cameraQuiet { cameraQuiet = quiet }
        if let ends = countdownEnds {
            let left = Int(ends.timeIntervalSince(now).rounded(.up))
            if left <= 0 {
                countdownEnds = nil
                recordingCountdown = nil
                if canRecord { startRecording() }
            } else if left != recordingCountdown {
                recordingCountdown = left
            }
        }
        guard isRecording else { return }
        recordingElapsed = now.timeIntervalSince(recordingStartedAt)
        // The writer stops at the limit on a frame; this stops it if the camera has gone quiet.
        if recordingElapsed >= ReplayConstants.maxLength { stopRecording() }
    }

    private func startRecording() {
        let base = ClipStore.defaultBase("Recording", at: Date(), timeZone: .current)
        do {
            let url = try clipStore.newPartURL(base: base)
            recordingPart = (url, base)
            isRecording = true
            recordingElapsed = 0
            recordingStartedAt = Date()
            pipeline.beginRecording(to: url)
        } catch {
            clipMessage = "Couldn't save the clip"
        }
    }

    /// The webcam is going away or changing: no countdown carries on, and a recording stops and saves.
    private func sourceLeaving() {
        countdownEnds = nil
        recordingCountdown = nil
        stopRecording()
    }

    func stopRecording() {
        guard isRecording, let part = recordingPart else { return }
        isRecording = false
        recordingPart = nil
        let store = clipStore
        pipeline.finishRecording { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let seconds) where seconds >= ReplayConstants.minLength:
                    do {
                        _ = try store.publish(part: part.url, base: part.base)
                        self.clipsChanged()
                    } catch {
                        try? FileManager.default.removeItem(at: part.url)
                        self.clipMessage = "Couldn't save the clip"
                    }
                case .success:
                    try? FileManager.default.removeItem(at: part.url)
                    self.clipMessage = "Clip too short"
                case .failure(let error):
                    try? FileManager.default.removeItem(at: part.url)
                    self.clipMessage = error as? ClipWriteError == .noFrames ? "Clip too short" : "Couldn't save the clip"
                }
            }
        }
    }

    private func setReplayTarget(_ target: ReplayTarget) {
        guard target != replayTarget else { return }
        replayTarget = target
        UserDefaults.standard.set(target.stored, forKey: "replayTarget")
    }

    private func start(_ target: ReplayTarget, isHotkey: Bool) {
        replayMessage = nil
        clipMessage = nil
        let conditions = ReplayConditions(hasClient: capturing, recordSheetOpen: recordSheetOpen, recentVideoOn: holdRecent,
                                          mode: mode, heldSeconds: pipeline.replay.heldSeconds)
        log.info("replay start \(target.stored, privacy: .public): held \(conditions.heldSeconds, privacy: .public) s, client \(conditions.hasClient, privacy: .public)")
        if let refusal = ReplayRules.refusal(for: target, given: conditions) {
            log.info("replay refused: \(refusal.message, privacy: .public)")
            replayMessage = refusal.message
            if isHotkey { NSSound.beep() }
            return
        }
        loadCancel?.cancel()
        let requestID = replay.begin(target)
        switch target {
        case .last(let seconds):
            pipeline.snapshotRecent(seconds: Double(seconds)) { [weak self] footage in
                DispatchQueue.main.async { self?.loaded(footage, requestID: requestID) }
            }
        case .clip(let file):
            let cancel = CancelFlag()
            loadCancel = cancel
            let url = clipStore.url(of: file)
            Task.detached(priority: .utility) { [weak self] in
                do {
                    let footage = try await ClipFile.read(from: url, isCancelled: { cancel.isCancelled })
                    await self?.loaded(footage, requestID: requestID)
                } catch let error as ClipReadError {
                    await self?.loadFailed(ReplayRefusal(error), requestID: requestID)
                } catch {
                    await self?.loadFailed(.badFile, requestID: requestID)
                }
            }
        }
    }

    private func loaded(_ footage: ReplayEngine.Footage, requestID: Int) {
        guard !footage.isEmpty else {
            loadFailed(.notEnoughVideo, requestID: requestID)
            return
        }
        guard replay.loadFinished(requestID: requestID) else { return }  // cancelled or replaced while it loaded
        log.info("replay playing \(footage.count, privacy: .public) frames")
        playingFootage = footage
        keptCurrentReplay = false
        watchdog.stop()
        pipeline.beginReplay(footage, mode: mode)
    }

    private func loadFailed(_ refusal: ReplayRefusal?, requestID: Int) {
        guard replay.loadFailed(requestID: requestID), let refusal else { return }
        replayMessage = refusal.message
    }

    private func playbackFailed() {
        guard replay.isOutputReplay else { return }
        endReplay(.goLive)
        replayMessage = ReplayRefusal.badFile.message
    }

    private func endReplay(_ reason: ReplayEnd) {
        loadCancel?.cancel()
        loadCancel = nil
        let wasOutput = replay.isOutputReplay
        if replay.isActive { log.info("replay ended: \(String(describing: reason), privacy: .public)") }
        let fades = replay.end(reason)
        playingFootage = nil
        guard wasOutput else { return }
        pipeline.endReplay(fade: fades)
        guard capturing, mode.needsCamera else { return }
        if currentSource() != nil { watchdog.start(at: Date()) } else { useCurrentSource() }
    }

    private func updateRecentHolding() {
        pipeline.replay.holdsRecentVideo = ReplayRules.holdsRecentVideo(hasClient: capturing, toggle: holdRecent, mode: mode)
    }

    func setLaunchAtLogin(_ on: Bool) {
        UserDefaults.standard.set(!on, forKey: Self.optOutKey)
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item toggle: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Capture lifecycle

    private func currentSource() -> AVCaptureDevice? {
        if let id = selectedSourceID, let d = AVCaptureDevice(uniqueID: id) { return d }
        return CameraPipeline.defaultSource()
    }

    private func setWantsCapture(_ wants: Bool) {
        wantsCapture = wants
        if wants {
            if !UserDefaults.standard.bool(forKey: Self.hasSeenClientKey) {
                UserDefaults.standard.set(true, forKey: Self.hasSeenClientKey)
                setupProgressed()
            }
            tryStartCapture()
        } else {
            endReplay(.clientLost)
            replayMessage = nil
            stopCapture()
            pipeline.wipeRecent()
        }
    }

    private static let optOutKey = "loginItemOptedOut"

    private static func loginItemState() -> LoginItemPolicy.State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    /// Runs on every watcher tick (1 s): folds sink-connect failures into "not ready"
    /// and restarts capture when the webcam has gone silent.
    private func checkHealth() {
        let now = Date()
        refreshCameraAccess()  // a menu click doesn't activate this app, so didBecomeActive alone would miss a grant
        checkDevicePresent(at: now)
        let failing = watcher.notReady || sinkFailures.isFailing(at: now)
        if notReady != failing { notReady = failing }
        guard capturing, mode.needsCamera, !replay.isOutputReplay else { return }
        if let last = pipeline.lastFrameAt { watchdog.frameDelivered(at: last) }
        if watchdog.isStalled(at: now) { captureStalled() }
    }

    private func modeChanged() {
        UserDefaults.standard.set(mode.rawValue, forKey: "cameraMode")
        replayMessage = nil
        endReplay(.modeChanged)
        pipeline.setMode(mode)
        updateRecentHolding()
        guard capturing else { tryStartCapture(); return }
        if mode.needsCamera {
            if cameraAuthorized != true || currentSource() == nil { restartCapture(); return }
            watchdog.start(at: Date())  // grace period while the webcam spins back up
        } else {
            watchdog.stop()
            cameraUnavailable = false
        }
    }

    private func tryStartCapture() {
        let needsCamera = mode.needsCamera
        guard wantsCapture, !capturing, !needsCamera || cameraAuthorized == true else { return }
        let device = currentSource()
        // With no camera the sink still connects, so clients see the background and never the idle image.
        cameraUnavailable = needsCamera && device == nil
        sink.queue.async { [weak self] in
            guard let self else { return }
            let ok = sink.connect()
            DispatchQueue.main.async {
                guard self.wantsCapture else {
                    self.sink.queue.async { self.sink.disconnect() }
                    return
                }
                self.sinkFailures.record(success: ok, at: Date())
                if ok {
                    self.capturing = true
                    self.pipeline.startSending(device: device)
                    if self.mode.needsCamera {
                        if device != nil { self.watchdog.start(at: Date()) } else { self.scheduleRetry() }
                    }
                } else {
                    self.scheduleRetry()
                }
            }
        }
    }

    private func stopCapture() {
        retryTimer?.invalidate()
        if !wantsCapture { sinkFailures.reset() }
        guard capturing else { return }
        capturing = false
        watchdog.stop()
        pipeline.stopSending()
        sink.queue.async { [sink] in sink.disconnect() }
    }

    private func restartCapture() {
        stopCapture()
        tryStartCapture()
    }

    private func captureFailed() {
        log.info("sink failed; retrying")
        endReplay(.sinkFailed)
        capturing = false
        watchdog.stop()
        pipeline.stopSending()
        scheduleRetry()
    }

    /// No webcam frames since capture started or for the watchdog timeout: input setup failed,
    /// the session died, or a disconnect was missed. The sink keeps sending the background; retry the webcam.
    private func captureStalled() {
        log.error("no camera frames; restarting the webcam")
        useCurrentSource()
    }

    /// Points the webcam at the current source and restarts it, leaving the sink alone.
    private func useCurrentSource() {
        guard capturing || recordSheetOpen else { return }
        if replay.isOutputReplay { return }
        let device = currentSource()
        pipeline.setSource(device)
        guard capturing, mode.needsCamera else { return }
        cameraUnavailable = device == nil
        if device != nil {
            watchdog.start(at: Date())
        } else {
            watchdog.stop()
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard wantsCapture else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.capturing { self.useCurrentSource() } else { self.tryStartCapture() }
            }
        }
    }

    private func sourceDisconnected(_ uniqueID: String?) {
        guard capturing || recordSheetOpen,
              uniqueID == pipeline.activeDevice?.uniqueID || uniqueID == selectedSourceID else { return }
        if uniqueID == selectedSourceID { selectedSourceID = nil }
        sourceLeaving()
        if replay.isOutputReplay {
            // A camera problem can't interrupt the loop. Going live re-arms the watchdog, which finds the webcam dead.
            pipeline.wipeRecent()
            return
        }
        useCurrentSource()
    }
}

/// Cancels one clip read, from any thread.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
