import CoreMediaIO
import Foundation
import IOKit.audio

/// The "Moobility Cam" device: one sink (from the app) and one source (to clients), sharing a FrameStore.
final class ExtensionDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let frames = FrameStore()
    private(set) var source: SourceStream!
    private(set) var sink: SinkStream!

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: MoobilityCamIDs.deviceName,
                                     deviceID: MoobilityCamIDs.deviceUID,
                                     legacyDeviceID: MoobilityCamIDs.deviceUID.uuidString,
                                     source: self)
        source = SourceStream(frames: frames)
        sink = SinkStream(frames: frames)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Moobility Cam: failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = MoobilityCamIDs.deviceName }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
