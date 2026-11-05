import Foundation
import UniformTypeIdentifiers

/// What identifies "the same file" between two scans.
public struct FileFingerprint: Hashable, Sendable {
    public let size: Int64
    public let modified: Date
    public let inode: UInt64

    public init(size: Int64, modified: Date, inode: UInt64) {
        self.size = size
        self.modified = modified
        self.inode = inode
    }
}

public enum LibraryProblem: Equatable, Sendable {
    case timingUnreadable, cannotOpenFolder, cannotSave, cannotAddPhoto

    public var message: String {
        switch self {
        case .timingUnreadable: return "Couldn't read your timing; saved a copy"
        case .cannotOpenFolder: return "Couldn't open your Moobility Cam folder"
        case .cannotSave: return "Couldn't save your timing"
        case .cannotAddPhoto: return "Couldn't add some photos"
        }
    }
}

/// The photo folder and its `library.json`. Not thread-safe: use it from one actor.
///
/// The file name is the identity of a photo, compared after Unicode normalization. The store keeps
/// one ordered entry list that includes entries whose files are missing, so a file that comes
/// back brings its rules with it; `photos` is the entries whose files are on disk.
public final class LibraryStore {
    /// `~/Pictures/Moobility Cam`.
    public static var defaultFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("Moobility Cam", isDirectory: true)
    }

    /// Entries whose files are present, in grid order.
    public private(set) var photos: [Photo] = []
    public private(set) var problem: LibraryProblem?

    public let folder: URL
    private let fileManager = FileManager.default
    private var entries: [Photo] = []
    /// Files present as of the last scan or add, by normalized name.
    private var fingerprints: [String: FileFingerprint] = [:]

    // `problem` shows the first of these that is set. A failure to open or save outranks the
    // unreadable-file notice, which stays until `library.json` is read again (`load()`, or a scan
    // that finds it changed).
    private var cannotOpen = false
    private var cannotSave = false
    /// Set by a failed copy in `add`; only an `add` whose copies all succeed clears it, never a save.
    private var cannotAdd = false
    private var unreadable = false
    /// The unreadable `library.json` couldn't be set aside yet, so saving must not replace it.
    private var badFileStillInPlace = false
    /// `library.json` as last read or written by this store (nil: not there). A scan that finds
    /// something else knows the file was edited from outside.
    private var jsonPrint: FileFingerprint?

    private let trash: (URL) throws -> Void

    /// `trash` moves a removed photo out of the folder; tests pass a plain delete to keep the real Trash clean.
    public init(folder: URL, trash: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) {
        self.folder = folder
        self.trash = trash
    }

    private var jsonURL: URL { folder.appendingPathComponent("library.json") }

    // MARK: Loading

    /// Reads `library.json`. One that can't be read is renamed to `library.json.bad-<timestamp>`
    /// and never overwritten; the store then starts with no entries.
    public func load() {
        readLibraryFile()
        refreshPhotos()
        updateProblem()
    }

    /// Replaces the entries with what `library.json` holds, and the unreadable state with what the
    /// read finds. Shared by `load()` and by a scan that notices the file was edited from outside.
    private func readLibraryFile() {
        entries = []
        unreadable = false
        badFileStillInPlace = false
        // Fingerprint first: an edit that lands during the read then shows up as a change next scan.
        jsonPrint = fingerprint(at: jsonURL)
        guard fileManager.fileExists(atPath: jsonURL.path) else { return }
        do {
            let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: jsonURL))
            var seen = Set<String>()
            entries = file.photos.compactMap { stored in
                // A duplicate loses to the first.
                guard seen.insert(Self.key(stored.file)).inserted else { return nil }
                return Photo(file: stored.file, title: stored.title, rules: stored.rules)
            }
        } catch {
            entries = []
            unreadable = true
            badFileStillInPlace = !setAsideJSON()
            if !badFileStillInPlace { jsonPrint = nil }
        }
    }

    /// Re-reads `library.json` if its fingerprint isn't the one this store last saw. A file that has
    /// simply gone is not a reason to forget: the entries stay and the next save writes them back.
    private func reloadIfEditedExternally() {
        let current = fingerprint(at: jsonURL)
        guard current != jsonPrint else { return }
        guard current != nil else {
            jsonPrint = nil
            return
        }
        readLibraryFile()
    }

    // MARK: Scanning

    /// Matches the folder against the entries. Creates the folder if it is missing. First picks up an
    /// edit made to `library.json` from outside (a repaired or seeded file) before this store saves over it.
    /// Returns true when the photos, any fingerprint or the entries changed.
    @discardableResult
    public func scan() -> Bool {
        let photosBefore = photos
        let fingerprintsBefore = fingerprints
        let entriesBefore = entries

        reloadIfEditedExternally()
        let reloadChangedEntries = entries != entriesBefore

        var createdFolder = false
        let found: [(name: String, fingerprint: FileFingerprint)]
        do {
            if !fileManager.fileExists(atPath: folder.path) {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                createdFolder = true
            }
            found = try candidateFiles()
            cannotOpen = false
        } catch {
            // Nothing can be shown from a folder we can't read; the entries (and their rules) stay.
            cannotOpen = true
            fingerprints = [:]
            refreshPhotos()
            updateProblem()
            return reloadChangedEntries || photos != photosBefore || fingerprints != fingerprintsBefore
        }

        var present: [String: FileFingerprint] = [:]
        var onDiskName: [String: String] = [:]
        for item in found {
            present[Self.key(item.name)] = item.fingerprint
            onDiskName[Self.key(item.name)] = item.name
        }

        var entriesChanged = false
        var known = Set<String>()
        for index in entries.indices {
            let key = Self.key(entries[index].file)
            known.insert(key)
            // Once matched, the entry uses the name on disk.
            if let name = onDiskName[key], name != entries[index].file {
                entries[index].file = name
                entriesChanged = true
            }
        }
        for item in found.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard known.insert(Self.key(item.name)).inserted else { continue }
            entries.append(Photo(file: item.name, title: Self.title(forFile: item.name), rules: []))
            entriesChanged = true
        }

        fingerprints = present
        refreshPhotos()
        // A folder recreated under us lost its library.json; write the entries back.
        if entriesChanged || (createdFolder && !entries.isEmpty) {
            save()
        } else {
            updateProblem()
        }
        return reloadChangedEntries || photos != photosBefore || fingerprints != fingerprintsBefore
    }

    public func fingerprint(of file: String) -> FileFingerprint? {
        fingerprints[Self.key(file)]
    }

    public func url(of file: String) -> URL {
        folder.appendingPathComponent(file)
    }

    /// Regular, non-hidden, non-symlink files whose extension is an image type.
    private func candidateFiles() throws -> [(name: String, fingerprint: FileFingerprint)] {
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard Self.isImageName(name), Self.isRegularFile(url), let fingerprint = fingerprint(at: url) else {
                return nil
            }
            return (name, fingerprint)
        }
    }

    // MARK: Editing

    /// Copies images into the folder and appends them with no rules. Non-images and files already in
    /// the folder are skipped; a name clash becomes "photo 2.jpg". Returns the photos added.
    public func add(_ urls: [URL]) -> [Photo] {
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            cannotOpen = false
        } catch {
            cannotOpen = true
            updateProblem()
            return []
        }

        let folderPath = Self.canonicalPath(folder)
        var taken = Set(entries.map { Self.key($0.file) })
        var added: [Photo] = []
        var copyFailed = false
        for source in urls {
            let resolved = source.resolvingSymlinksInPath()
            guard Self.isImageName(source.lastPathComponent), Self.isRegularFile(resolved),
                  Self.canonicalPath(resolved.deletingLastPathComponent()) != folderPath else { continue }
            // A name held by a missing file's entry counts as a clash too, so the new photo can't
            // inherit that entry's rules.
            let name = availableName(for: source.lastPathComponent, taken: taken)
            let destination = url(of: name)
            do {
                try fileManager.copyItem(at: resolved, to: destination)
            } catch {
                copyFailed = true
                continue
            }
            guard let fingerprint = fingerprint(at: destination) else {
                copyFailed = true
                continue
            }
            let photo = Photo(file: name, title: Self.title(forFile: name), rules: [])
            taken.insert(Self.key(name))
            entries.append(photo)
            fingerprints[Self.key(name)] = fingerprint
            added.append(photo)
        }
        // A failure stays reported (saving the photos that did copy mustn't hide it) until an add in
        // which every copy worked.
        if copyFailed {
            cannotAdd = true
        } else if !added.isEmpty {
            cannotAdd = false
        }
        refreshPhotos()
        if added.isEmpty { updateProblem() } else { save() }
        return added
    }

    /// Moves the file to the Trash (deleting it if the Trash fails), then forgets the entry.
    public func remove(_ file: String) {
        let key = Self.key(file)
        guard let index = entries.firstIndex(where: { Self.key($0.file) == key }) else { return }
        let fileURL = url(of: entries[index].file)
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try trash(fileURL)
            } catch {
                try? fileManager.removeItem(at: fileURL)
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                // Still there: keep the entry, or the next scan would bring it back as a new photo.
                cannotSave = true
                updateProblem()
                return
            }
        }
        entries.remove(at: index)
        fingerprints[key] = nil
        refreshPhotos()
        save()
    }

    public func setRules(_ rules: [TimingRule], for file: String) {
        edit(file) { $0.rules = rules }
    }

    public func setTitle(_ title: String, for file: String) {
        edit(file) { $0.title = title }
    }

    /// `toIndex` is a position in `photos`. Entries for missing files keep their place beside their neighbours.
    public func move(file: String, toIndex: Int) {
        let key = Self.key(file)
        guard photos.count > 1, let from = photos.firstIndex(where: { Self.key($0.file) == key }) else { return }
        let target = min(max(toIndex, 0), photos.count - 1)
        guard target != from, let entryIndex = entries.firstIndex(where: { Self.key($0.file) == key }) else { return }

        var others = photos
        others.remove(at: from)
        let moving = entries.remove(at: entryIndex)
        let insertAt: Int
        if target < others.count {
            // Just before the photo it will now precede.
            let next = Self.key(others[target].file)
            insertAt = entries.firstIndex { Self.key($0.file) == next } ?? entries.count
        } else {
            // To the end: just after the last remaining photo.
            let last = Self.key(others[others.count - 1].file)
            insertAt = entries.firstIndex { Self.key($0.file) == last }.map { $0 + 1 } ?? entries.count
        }
        entries.insert(moving, at: insertAt)
        refreshPhotos()
        save()
    }

    private func edit(_ file: String, _ change: (inout Photo) -> Void) {
        let key = Self.key(file)
        guard let index = entries.firstIndex(where: { Self.key($0.file) == key }) else { return }
        var updated = entries[index]
        change(&updated)
        guard updated != entries[index] else { return }
        entries[index] = updated
        refreshPhotos()
        save()
    }

    // MARK: Saving

    private func save() {
        defer { updateProblem() }
        if badFileStillInPlace {
            guard setAsideJSON() else {
                cannotSave = true
                return
            }
            badFileStillInPlace = false
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let file = LibraryFile(photos: entries.map { StoredPhoto(file: $0.file, title: $0.title, rules: $0.rules) })
            try encoder.encode(file).write(to: jsonURL, options: .atomic)
            // Our own write isn't an outside edit.
            jsonPrint = fingerprint(at: jsonURL)
            cannotSave = false
        } catch {
            cannotSave = true
        }
    }

    /// Renames `library.json` to `library.json.bad-<unix timestamp>`, never onto an existing file.
    private func setAsideJSON() -> Bool {
        guard fileManager.fileExists(atPath: jsonURL.path) else { return true }
        let stamp = Int(Date().timeIntervalSince1970)
        var target = folder.appendingPathComponent("library.json.bad-\(stamp)")
        var attempt = 1
        while fileManager.fileExists(atPath: target.path) {
            attempt += 1
            target = folder.appendingPathComponent("library.json.bad-\(stamp)-\(attempt)")
        }
        do {
            try fileManager.moveItem(at: jsonURL, to: target)
            return true
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private func refreshPhotos() {
        photos = entries.filter { fingerprints[Self.key($0.file)] != nil }
    }

    private func updateProblem() {
        problem = cannotOpen ? .cannotOpenFolder
            : cannotSave ? .cannotSave
            : cannotAdd ? .cannotAddPhoto
            : unreadable ? .timingUnreadable
            : nil
    }

    private func fingerprint(at url: URL) -> FileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return FileFingerprint(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// "photo.jpg", else "photo 2.jpg", "photo 3.jpg", ... skipping names on disk or held by an entry.
    private func availableName(for name: String, taken: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 1
        while taken.contains(Self.key(candidate)) || fileManager.fileExists(atPath: url(of: candidate).path) {
            number += 1
            candidate = "\(base) \(number).\(ext)"
        }
        return candidate
    }

    /// File names are compared after Unicode normalization, so "é" typed either way is one file.
    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    private static func title(forFile name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func isImageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    fileprivate static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

// MARK: - JSON

private struct StoredPhoto: Codable {
    let file: String
    let title: String
    let rules: [TimingRule]

    init(file: String, title: String, rules: [TimingRule]) {
        self.file = file
        self.title = title
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case file, title, rules }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        guard LibraryStore.isSinglePathComponent(file) else {
            throw DecodingError.dataCorruptedError(
                forKey: .file, in: container, debugDescription: "file must be a single path component")
        }
        title = try container.decode(String.self, forKey: .title)
        rules = try container.decode([TimingRule].self, forKey: .rules)
    }
}

private struct LibraryFile: Codable {
    static let version = 1
    let photos: [StoredPhoto]

    init(photos: [StoredPhoto]) {
        self.photos = photos
    }

    private enum CodingKeys: String, CodingKey { case version, photos }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "unsupported library version")
        }
        photos = try container.decode([StoredPhoto].self, forKey: .photos)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(photos, forKey: .photos)
    }
}
