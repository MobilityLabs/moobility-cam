import Foundation

/// Decides whether the app should send to the virtual camera: on as soon as a client appears,
/// off only after the client count has stayed at zero for `stopDelay`.
public struct CaptureGate: Sendable {
    private let stopDelay: TimeInterval
    private var capturing = false
    private var zeroSince: Date?

    public init(stopDelay: TimeInterval = 2) {
        self.stopDelay = stopDelay
    }

    public mutating func update(clientCount: Int, at now: Date) -> Bool {
        if clientCount > 0 {
            capturing = true
            zeroSince = nil
        } else if capturing {
            let since = zeroSince ?? now
            zeroSince = since
            if now.timeIntervalSince(since) >= stopDelay {
                capturing = false
                zeroSince = nil
            }
        }
        return capturing
    }
}
