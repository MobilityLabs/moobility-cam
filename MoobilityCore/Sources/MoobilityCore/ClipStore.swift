import Foundation

public struct Clip: Equatable, Sendable {
    public let file: String
    public let modified: Date

    public init(file: String, modified: Date) {
        self.file = file
        self.modified = modified
    }

    public var title: String { String(file.dropLast(ClipStore.movieExtension.count + 1)) }
}

public enum ClipTime {
    /// "m:ss", or empty for a length that isn't usable: a damaged movie can report NaN or infinity.
    public static func text(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 1_000_000 else { return "" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

public enum ClipNameError: Error, Equatable {
    case invalid, taken

    public var message: String {
        switch self {
        case .invalid: "That name can't be used"
        case .taken: "A clip already has that name"
        }
    }
}

/// The clips folder. The file name is the title and there's no index file, so Finder and the app agree.
public struct ClipStore: Sendable {
    static let movieExtension = "mov"
    private static let partExtension = "part"

    public let folder: URL
    private let trash: @Sendable (URL) throws -> Void

    public static var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("Moobility Cam", isDirectory: true)
    }

    @Sendable public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public init(folder: URL = ClipStore.defaultFolder,
                trash: @escaping @Sendable (URL) throws -> Void = ClipStore.moveToTrash) {
        self.folder = folder
        self.trash = trash
    }

    public func url(of file: String) -> URL {
        folder.appendingPathComponent(file)
    }

    /// Visible `.mov` files, newest first; empty when the folder doesn't exist yet.
    public func list() -> [Clip] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == Self.movieExtension }
            .map { name -> Clip in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url(of: name).path)
                return Clip(file: name, modified: attributes?[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.file < $1.file }
    }

    public static func defaultBase(_ prefix: String, at date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(formatter.string(from: date))"
    }

    /// Creates the folder if needed. Unique per call, because two saves in the same minute share a base
    /// and the file only appears once a writer starts. `publish` picks the readable numbered name.
    public func newPartURL(base: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return url(of: "\(base) \(UUID().uuidString).\(Self.movieExtension).\(Self.partExtension)")
    }

    /// Moves without overwriting; on a collision retries " 2", " 3"… Returns the file name.
    public func publish(part: URL, base: String) throws -> String {
        var suffix = 1
        while true {
            let file = suffix == 1 ? "\(base).\(Self.movieExtension)" : "\(base) \(suffix).\(Self.movieExtension)"
            suffix += 1
            if isTaken(file, except: nil) { continue }
            do {
                try FileManager.default.moveItem(at: part, to: url(of: file))
                return file
            } catch CocoaError.fileWriteFileExists {
                continue  // appeared after the check above
            }
        }
    }

    /// Returns the new file name.
    public func rename(_ file: String, to title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw ClipNameError.invalid
        }
        let newFile = "\(trimmed).\(Self.movieExtension)"
        if newFile == file { return file }
        if isTaken(newFile, except: file) { throw ClipNameError.taken }
        if Self.comparable(newFile) == Self.comparable(file) {
            // The same name to the file system: `moveItem` would see the destination as existing.
            guard Foundation.rename(url(of: file).path, url(of: newFile).path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: url(of: file), to: url(of: newFile))
            } catch CocoaError.fileWriteFileExists {
                throw ClipNameError.taken
            }
        }
        return newFile
    }

    public func delete(_ file: String) throws {
        try trash(url(of: file))
    }

    public func removeLeftoverParts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where (name as NSString).pathExtension == Self.partExtension {
            try? FileManager.default.removeItem(at: url(of: name))
        }
    }

    private func isTaken(_ file: String, except: String?) -> Bool {
        let wanted = Self.comparable(file)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { name in
            let existing = Self.comparable(name)
            return existing == wanted && name != except
        }
    }

    /// macOS volumes normally ignore case and treat composed and decomposed accents as the same.
    private static func comparable(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }
}

extension ReplayTarget {
    public func afterRemoving(file: String) -> ReplayTarget {
        self == .clip(file: file) ? .default : self
    }

    public func afterRenaming(_ old: String, to new: String) -> ReplayTarget {
        self == .clip(file: old) ? .clip(file: new) : self
    }
}
