import CoreMediaIO
import Foundation
import MoobilityCore

/// Polls the extension's client count once a second and reports when capture should start or stop.
@MainActor final class ClientWatcher {
    var onChange: ((Bool) -> Void)?
    /// Set while the Moobility Cam device/stream can't be found; drives "Moobility Cam not ready" after 10 s.
    private(set) var lookupFailingSince: Date?
    var onLookupStateChange: (() -> Void)?

    private var gate = CaptureGate()
    private var sourceStream: CMIOStreamID?
    private var shouldCapture = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        listenForDeviceChanges()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Forget the cached stream and look it up again now (activation finished, device list changed).
    func retryNow() {
        sourceStream = nil
        tick()
    }

    var notReady: Bool {
        guard let since = lookupFailingSince else { return false }
        return Date().timeIntervalSince(since) >= 10
    }

    private func tick() {
        let now = Date()
        if sourceStream == nil, let device = CMIOLookup.device() {
            sourceStream = CMIOLookup.stream(of: device, direction: CMIOLookup.directionSource)
        }
        let count = sourceStream.flatMap { CMIOLookup.clientCount(sourceStream: $0) }
        if count == nil {
            sourceStream = nil  // stale ID after an extension restart; look up again next tick
            if lookupFailingSince == nil { lookupFailingSince = now }
        } else if lookupFailingSince != nil {
            lookupFailingSince = nil
        }
        onLookupStateChange?()
        let capture = gate.update(clientCount: count ?? 0, at: now)
        if capture != shouldCapture {
            shouldCapture = capture
            onChange?(capture)
        }
    }

    private func listenForDeviceChanges() {
        var addr = CMIOLookup.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.retryNow() }
        }
    }
}
