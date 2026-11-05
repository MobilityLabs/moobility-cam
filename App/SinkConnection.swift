import CoreMedia
import CoreMediaIO
import Foundation
import MoobilityCore
import os

/// Owns the app → extension sink stream: connect, enqueue frames, detect a stalled consumer, disconnect.
/// Every method must be called on `queue`.
final class SinkConnection: @unchecked Sendable {  // confined to `queue`
    enum State { case disconnected, connected }

    let queue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.sink")
    private(set) var state: State = .disconnected
    var onFailure: (() -> Void)?

    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "Sink")
    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var health = SinkHealth()

    /// device → sink stream → buffer queue → start. Returns false (and stays disconnected) on any failure.
    func connect() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if state == .connected { return true }
        guard let device = CMIOLookup.device(),
              let stream = CMIOLookup.stream(of: device, direction: CMIOLookup.directionSink) else {
            log.info("sink lookup failed")
            return false
        }
        var unmanaged: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanaged)
        guard copyStatus == noErr, let q = unmanaged?.takeRetainedValue() else {
            log.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return false
        }
        let startStatus = CMIODeviceStartStream(device, stream)
        guard startStatus == noErr else {
            log.error("CMIODeviceStartStream failed: \(startStatus)")
            return false
        }
        self.device = device
        self.stream = stream
        bufferQueue = q
        health.reset()
        state = .connected
        log.info("sink connected")
        return true
    }

    func send(_ buffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .connected, let q = bufferQueue else { return }
        let full = CMSimpleQueueGetCount(q) >= CMSimpleQueueGetCapacity(q)
        if health.record(queueFull: full, at: Date()) {
            fail("sink queue full for 1 s — extension stopped consuming")
            return
        }
        guard !full else { return }  // drop this frame
        let element = Unmanaged.passRetained(buffer).toOpaque()
        let status = CMSimpleQueueEnqueue(q, element: element)
        if status != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            fail("enqueue failed: \(status)")
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .connected else { return }
        CMIODeviceStopStream(device, stream)
        bufferQueue = nil
        health.reset()
        state = .disconnected
        log.info("sink disconnected")
    }

    private func fail(_ reason: String) {
        log.error("\(reason, privacy: .public)")
        disconnect()
        onFailure?()
    }
}
