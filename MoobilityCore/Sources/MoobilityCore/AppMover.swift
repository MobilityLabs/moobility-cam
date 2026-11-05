import Foundation

public enum InstallDecision: Equatable, Sendable {
    case alreadyInPlace, installFresh, replaceOlder, openInstalled, blockedByUnreadable
}

public enum InstalledCopy: Equatable, Sendable {
    case none, build(Int), unreadable
}

/// Moves the app into Applications without ever damaging a copy already there.
public enum AppMover {
    /// An old DMG can't downgrade anyone. A copy that can't be read or verified is neither replaced nor launched.
    public static func decide(runningFrom: URL, destination: URL, myBuild: Int, installed: InstalledCopy) -> InstallDecision {
        if runningFrom.standardizedFileURL == destination.standardizedFileURL { return .alreadyInPlace }
        switch installed {
        case .none: return .installFresh
        case .build(let build): return build < myBuild ? .replaceOlder : .openInstalled
        case .unreadable: return .blockedByUnreadable
        }
    }

    public struct Ops: Sendable {
        public var copy: @Sendable (URL, URL) throws -> Void
        public var rename: @Sendable (URL, URL) throws -> Void
        public var remove: @Sendable (URL) throws -> Void
        public var exists: @Sendable (URL) -> Bool

        public init(copy: @escaping @Sendable (URL, URL) throws -> Void,
                    rename: @escaping @Sendable (URL, URL) throws -> Void,
                    remove: @escaping @Sendable (URL) throws -> Void,
                    exists: @escaping @Sendable (URL) -> Bool) {
            self.copy = copy
            self.rename = rename
            self.remove = remove
            self.exists = exists
        }

        public static let live = Ops(
            copy: { from, to in
                // ditto keeps a bundle's signature and works from read-only media, such as a mounted DMG.
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = [from.path, to.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                // A quarantined copy would launch translocated, from a random read-only path, and never count
                // as being in Applications. Gatekeeper already passed this bundle to get it running.
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", to.path]
                // waitUntilExit raises an exception, which nothing can catch, on a process that never launched.
                if (try? xattr.run()) != nil { xattr.waitUntilExit() }
            },
            rename: { from, to in try FileManager.default.moveItem(at: from, to: to) },
            remove: { url in try FileManager.default.removeItem(at: url) },
            exists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
    }

    public enum MoveError: Error, Equatable {
        case copyFailed
        /// The existing app wasn't touched.
        case backupFailed
        /// The existing app, if any, is back in place.
        case installFailed
        /// The existing app couldn't be put back, and is kept at this path.
        case restoreFailed(backup: String)
    }

    public static func install(from source: URL, to destination: URL, ops: Ops) throws {
        let folder = destination.deletingLastPathComponent()
        let name = destination.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString
        let staged = folder.appendingPathComponent(".\(name)-new-\(token).app")
        let backup = folder.appendingPathComponent(".\(name)-old-\(token).app")

        do {
            try ops.copy(source, staged)
        } catch {
            try? ops.remove(staged)
            throw MoveError.copyFailed
        }

        let hadExisting = ops.exists(destination)
        if hadExisting {
            do {
                try ops.rename(destination, backup)
            } catch {
                try? ops.remove(staged)
                throw MoveError.backupFailed
            }
        }

        var moved = false
        do {
            try ops.rename(staged, destination)
            moved = ops.exists(destination)
        } catch {
            moved = false
        }
        guard moved else {
            try? ops.remove(staged)
            guard hadExisting else { throw MoveError.installFailed }
            if ops.exists(destination) { try? ops.remove(destination) }
            do {
                try ops.rename(backup, destination)
            } catch {
                throw MoveError.restoreFailed(backup: backup.path)
            }
            throw MoveError.installFailed
        }
        if hadExisting { try? ops.remove(backup) }
    }
}
