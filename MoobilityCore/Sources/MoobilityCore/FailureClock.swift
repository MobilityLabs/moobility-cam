import Foundation

/// Tracks how long an operation has been failing continuously. Repeated failures do not
/// restart the clock; a single success clears it.
public struct FailureClock: Sendable {
    private let threshold: TimeInterval
    private var failingSince: Date?

    public init(threshold: TimeInterval = 10) {
        self.threshold = threshold
    }

    public mutating func record(success: Bool, at now: Date) {
        if success {
            failingSince = nil
        } else if failingSince == nil {
            failingSince = now
        }
    }

    public mutating func reset() {
        failingSince = nil
    }

    /// Returns `true` when failures have run continuously for at least `threshold`.
    public func isFailing(at now: Date) -> Bool {
        guard let failingSince else { return false }
        return now.timeIntervalSince(failingSince) >= threshold
    }
}
