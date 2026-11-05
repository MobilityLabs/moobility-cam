import Foundation

/// Flags capture as stalled when no frame has arrived within `timeout` of the later of
/// the start or the last delivered frame, i.e. the session is "running" but silent.
public struct FrameWatchdog: Sendable {
    private let timeout: TimeInterval
    private var startedAt: Date?
    private var lastFrame: Date?

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public mutating func start(at now: Date) {
        startedAt = now
    }

    public mutating func frameDelivered(at now: Date) {
        lastFrame = now
    }

    public mutating func stop() {
        startedAt = nil
    }

    /// Returns `true` when capture has been started and has gone quiet for `timeout`.
    public func isStalled(at now: Date) -> Bool {
        guard let startedAt else { return false }
        let lastActivity = max(startedAt, lastFrame ?? startedAt)
        return now.timeIntervalSince(lastActivity) >= timeout
    }
}
