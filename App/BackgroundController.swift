import AppKit
import CoreImage
import Foundation
import MoobilityCore
import os

/// Which background is showing now: the library's ranking plus a menu override, re-evaluated every minute.
@MainActor final class BackgroundController: ObservableObject {
    @Published private(set) var library: Library
    @Published private(set) var current: Candidate
    @Published private(set) var isOverridden = false
    @Published private(set) var problem: LibraryProblem?
    /// Files that failed to decode at their current fingerprint.
    @Published private(set) var unreadable: Set<String> = []
    /// Bumped when a scan finds a change `library` can't show, such as a file replaced in place, so tiles re-read their keys.
    @Published private(set) var revision = 0

    let store: LibraryStore
    var onChange: ((CIImage) -> Void)?

    private let southern = Season.isSouthern(region: Locale.current.region?.identifier)
    private var overrideChoice = BackgroundOverride()
    private var failures = DecodeFailures()
    private var loads = BackgroundLoadTracker()
    private let loadQueue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.background-load", qos: .userInitiated)

    private var tickTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var rescanPending = false

    private var thumbnails: [String: CGImage] = [:]
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "Background")

    init(store: LibraryStore = LibraryStore(folder: LibraryStore.defaultFolder)) {
        self.store = store
        store.load()
        store.scan()
        let library = Library(photos: store.photos, southern: southern)
        self.library = library
        current = library.ranked(at: Date(), timeZone: .current).first ?? .season(.autumn)
        problem = store.problem
    }

    /// Begins timers and watchers and loads the first background. Set `onChange` first.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(.default, .NSSystemClockDidChange)
        observe(.default, .NSSystemTimeZoneDidChange)
        refresh()
    }

    /// `nil` returns to the schedule. Lasts until local midnight.
    func override(_ id: String?) {
        overrideChoice.set(id, at: Date(), timeZone: .current)
        refresh()
    }

    /// Rescan the folder, rerank, and load the winner if it changed. Call after any store edit.
    func refresh() {
        if store.scan() { revision &+= 1 }
        armFolderWatcher()
        if store.photos != library.photos { library.photos = store.photos }
        if problem != store.problem { problem = store.problem }
        forgetStaleFailures()
        chooseBackground()
        armTick()
    }

    /// Identifies a tile's image; changes when the file does, so a tile can reload.
    func thumbnailKey(for candidate: Candidate) -> String {
        guard case let .photo(photo) = candidate, let print = store.fingerprint(of: photo.file) else { return candidate.id }
        return "\(photo.file)|\(print.size)|\(print.modified.timeIntervalSince1970)|\(print.inode)"
    }

    func thumbnail(for candidate: Candidate) async -> CGImage? {
        let key = thumbnailKey(for: candidate)
        if let cached = thumbnails[key] { return cached }
        guard let url = url(of: candidate) else { return nil }
        let attempted = fingerprint(of: candidate)
        let image = await Task.detached(priority: .utility) { LibraryImageLoader.thumbnail(at: url) }.value
        if let image {
            thumbnails[key] = image
        } else if case let .photo(photo) = candidate, let attempted {
            recordFailure(photo.file, at: attempted)
        }
        return image
    }

    /// Files dropped on the window copy in. A photo dragged onto another tile moves to its place.
    func drop(_ urls: [URL], onto target: Photo?) {
        let folder = store.folder.standardizedFileURL.path
        if let target, urls.count == 1, urls[0].deletingLastPathComponent().standardizedFileURL.path == folder,
           let index = library.photos.firstIndex(where: { $0.file == target.file }) {
            store.move(file: urls[0].lastPathComponent, toIndex: index)
        } else {
            _ = store.add(urls)
        }
        refresh()
    }

    // MARK: Choosing and loading

    private func url(of candidate: Candidate) -> URL? {
        switch candidate {
        case let .photo(photo): store.url(of: photo.file)
        case let .season(season): Bundle.main.url(forResource: season.rawValue, withExtension: "jpg")
        }
    }

    private func fingerprint(of candidate: Candidate) -> FileFingerprint? {
        guard case let .photo(photo) = candidate else { return nil }
        return store.fingerprint(of: photo.file)
    }

    private func isFailed(_ candidate: Candidate) -> Bool {
        guard case let .photo(photo) = candidate else { return false }
        return failures.isFailed(photo.file, at: store.fingerprint(of: photo.file))
    }

    /// Blames only the version of the file that was tried.
    private func recordFailure(_ file: String, at attempted: FileFingerprint) {
        failures.record(file, at: attempted)
        forgetStaleFailures()
    }

    private func forgetStaleFailures() {
        failures.prune { store.fingerprint(of: $0) }
        if unreadable != failures.files { unreadable = failures.files }
    }

    private func chooseBackground() {
        let now = Date()
        let candidates = library.effective(at: now, override: overrideChoice, timeZone: .current)
        guard let choice = candidates.first(where: { !isFailed($0) }) else { return }
        let top = library.ranked(at: now, timeZone: .current).first
        let overridden = overrideChoice.activeID(at: now, timeZone: .current) != nil && choice.id != top?.id
        if isOverridden != overridden { isOverridden = overridden }

        let key = thumbnailKey(for: choice)
        switch loads.want(key) {
        case .keep:
            if current != choice { current = choice }   // same file, new title or rules
        case .alreadyRunning:
            break
        case let .start(generation):
            guard let url = url(of: choice) else {
                loads.abandon()
                log.error("no image file for \(choice.id, privacy: .public)")
                return
            }
            let attempted = fingerprint(of: choice)
            loadQueue.async { [weak self] in
                let image = LibraryImageLoader.background(at: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finishLoad(generation, key: key, choice: choice, attempted: attempted, image: image)
                    }
                }
            }
        }
    }

    private func finishLoad(_ generation: Int, key: String, choice: Candidate, attempted: FileFingerprint?, image: CIImage?) {
        guard loads.finish(generation: generation, key: key, succeeded: image != nil) else { return }   // a newer choice won
        guard let image else {
            log.error("could not decode \(choice.id, privacy: .public)")
            if case let .photo(photo) = choice, let attempted {
                recordFailure(photo.file, at: attempted)
                chooseBackground()
            }
            return
        }
        current = choice
        log.info("background → \(choice.id, privacy: .public)")
        onChange?(image)
    }

    // MARK: Timers and watchers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                self?.refresh()
            }
        }
        observers.append((center, token))
    }

    /// One shot at the next minute boundary, since no rule is finer than a minute.
    private func armTick() {
        tickTimer?.invalidate()
        let now = Date().timeIntervalSinceReferenceDate
        let next = (now / 60).rounded(.down) * 60 + 61
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func armFolderWatcher() {
        guard folderWatcher == nil else { return }
        let fd = open(store.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.isDisjoint(with: [.rename, .delete]) {
                    source.cancel()
                    self.folderWatcher = nil
                }
                self.scheduleRescan()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatcher = source
    }

    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.rescanPending = false
                self?.refresh()
            }
        }
    }
}
