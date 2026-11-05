import CoreMedia
import CoreMediaIO
import Foundation
import os

/// Input stream the Moobility Cam app feeds composited frames into.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let frames: FrameStore
    private let queue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.Extension.sink")
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam.Extension", category: "Sink")
    private var client: CMIOExtensionClient?
    private var running = false

    init(frames: FrameStore) {
        self.frames = frames
        super.init()
        stream = CMIOExtensionStream(localizedName: "\(MoobilityCamIDs.deviceName) Input",
                                     streamID: MoobilityCamIDs.sinkStreamUID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    // MARK: CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] { [MoobilityCamIDs.streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = MoobilityCamIDs.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkBufferUnderrunCount) { props.sinkBufferUnderrunCount = 0 }
        if properties.contains(.streamSinkEndOfData) { props.sinkEndOfData = 0 }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard ClientCheck.isOurApp(client) else { return false }
        queue.sync { self.client = client }
        return true
    }

    func startStream() throws {
        queue.async { [self] in
            running = true
            log.info("sink started")
            consumeNext()
        }
    }

    func stopStream() throws {
        queue.async { [self] in
            running = false
            log.info("sink stopped")
        }
    }

    // MARK: Consume loop

    private func consumeNext() {
        guard running, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, hasMore, error in
            guard let self else { return }
            self.queue.async {
                let now = hostTimeNs()
                if let buffer {
                    self.frames.store(buffer, at: now)
                    self.stream.notifyScheduledOutputChanged(
                        CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                }
                if let error { self.log.debug("consume error: \(error.localizedDescription, privacy: .public)") }
                guard self.running else { return }
                if hasMore {
                    self.consumeNext()
                } else {
                    // Nothing queued yet: poll again at twice the frame rate.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(16)) { self.consumeNext() }
                }
            }
        }
    }
}
