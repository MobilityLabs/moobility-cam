import Foundation

/// Decides which background load is allowed to reach the camera. A load runs off the main thread and
/// finishes later, so by then the user may have moved on to another choice; each load carries a
/// generation number and only the current one may be applied.
public struct BackgroundLoadTracker: Sendable {
    public enum Decision: Equatable, Sendable {
        /// This choice is already the one on screen. Any load still running for another choice was discarded.
        case keep
        /// This choice is already loading.
        case alreadyRunning
        /// Start loading, and pass `generation` back to `finish`.
        case start(generation: Int)
    }

    private var generation = 0
    private var loaded: String?
    private var running: String?

    public init() {}

    public mutating func want(_ key: String) -> Decision {
        if key == loaded {
            if running != nil { abandon() }
            return .keep
        }
        if key == running { return .alreadyRunning }
        generation += 1
        running = key
        return .start(generation: generation)
    }

    /// Returns false if the load was superseded and its result must be dropped. Otherwise the load is
    /// over; if it succeeded, `key` is now the one on screen.
    public mutating func finish(generation: Int, key: String, succeeded: Bool) -> Bool {
        guard generation == self.generation else { return false }
        running = nil
        if succeeded { loaded = key }
        return true
    }

    /// Discards any running load without changing what is on screen.
    public mutating func abandon() {
        generation += 1
        running = nil
    }
}

/// Files that failed to decode, each remembered against the version of the file that was tried. A
/// replacement (a different fingerprint) is not blamed for its predecessor, so a half-copied file
/// is retried once the copy finishes.
public struct DecodeFailures: Sendable {
    private var prints: [String: FileFingerprint] = [:]

    public init() {}

    public var files: Set<String> { Set(prints.keys) }

    public mutating func record(_ file: String, at fingerprint: FileFingerprint) {
        prints[file] = fingerprint
    }

    /// True only if `file` is present now, in the same version that failed.
    public func isFailed(_ file: String, at fingerprint: FileFingerprint?) -> Bool {
        guard let fingerprint, let recorded = prints[file] else { return false }
        return recorded == fingerprint
    }

    /// Forgets every failure whose file has since changed or gone.
    public mutating func prune(current: (String) -> FileFingerprint?) {
        prints = prints.filter { current($0.key) == $0.value }
    }
}
