import Foundation

/// Flags a sink connection as failed when its queue has stayed full for `fullTimeout`,
/// i.e. the extension stopped consuming frames without raising an error.
public struct SinkHealth: Sendable {
    private let fullTimeout: TimeInterval
    private var fullSince: Date?

    public init(fullTimeout: TimeInterval = 1) {
        self.fullTimeout = fullTimeout
    }

    /// Returns `true` when the connection should be treated as failed.
    public mutating func record(queueFull: Bool, at now: Date) -> Bool {
        guard queueFull else { fullSince = nil; return false }
        let since = fullSince ?? now
        fullSince = since
        return now.timeIntervalSince(since) >= fullTimeout
    }

    public mutating func reset() {
        fullSince = nil
    }
}
