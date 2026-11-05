import CoreMedia
import CoreMediaIO
import Foundation
import os

/// Output stream that Zoom/Meet/FaceTime read. Sends the newest app frame at 30 fps, or idle.png.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let frames: FrameStore
    private let queue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.Extension.source")
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam.Extension", category: "Source")
    private var timer: DispatchSourceTimer?
    private var sendingIdle = true
    private var clientsObservation: NSKeyValueObservation?
    private var clientCount = 0

    init(frames: FrameStore) {
        self.frames = frames
        super.init()
        stream = CMIOExtensionStream(localizedName: "\(MoobilityCamIDs.deviceName) Output",
                                     streamID: MoobilityCamIDs.sourceStreamUID,
                                     direction: .source, clockType: .hostTime, source: self)
        clientsObservation = stream.observe(\.streamingClients, options: [.initial, .new]) { [weak self] stream, _ in
            self?.publishClientCount(stream.streamingClients.count)
        }
    }

    private func publishClientCount(_ count: Int) {
        queue.async { [self] in
            clientCount = count
            let state = CMIOExtensionPropertyState<AnyObject>(value: String(count) as NSString)
            stream.notifyPropertiesChanged([MoobilityCamIDs.clientCountProperty: state])
        }
    }

    // MARK: CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] { [MoobilityCamIDs.streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, MoobilityCamIDs.clientCountProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = MoobilityCamIDs.frameDuration }
        if properties.contains(MoobilityCamIDs.clientCountProperty) {
            let count = queue.sync { clientCount }
            props.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: String(count) as NSString),
                                   forProperty: MoobilityCamIDs.clientCountProperty)
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: MoobilityCamIDs.frameDuration.seconds, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            sendingIdle = true
            log.info("source started")
        }
    }

    func stopStream() throws {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            log.info("source stopped")
        }
    }

    // MARK: Frames

    private func tick() {
        let now = hostTimeNs()
        let live = frames.current(now: now).flatMap(CMSampleBufferGetImageBuffer)
        guard let pixels = live ?? frames.idlePixelBuffer else { return }
        let isIdle = live == nil
        let discontinuity: CMIOExtensionStream.DiscontinuityFlags = isIdle != sendingIdle ? .time : []
        sendingIdle = isIdle
        guard let buffer = makeSampleBuffer(pixels, hostNs: now) else { return }
        stream.send(buffer, discontinuity: discontinuity, hostTimeInNanoseconds: now)
    }

    private func makeSampleBuffer(_ pixels: CVPixelBuffer, hostNs: UInt64) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: MoobilityCamIDs.frameDuration,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostNs), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}
