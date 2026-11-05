import CoreMediaIO
import Foundation

/// Thin wrappers over the CoreMediaIO C API. Every function returns nil on a non-zero OSStatus.
enum CMIOLookup {
    static let deviceUID = "5A8F3C1E-2B7D-4E9A-8C6F-0D1B2E3F4A5B"
    /// kCMIOStreamPropertyDirection is from the client's point of view: the camera stream clients read
    /// is an input (1); the stream the app writes into is an output (0). Verified against the live extension.
    static let directionSource: UInt32 = 1
    static let directionSink: UInt32 = 0
    /// 'mcnt' — the extension's `4cc_mcnt_glob_0000` custom property.
    static let clientCountSelector: CMIOObjectPropertySelector = 0x6D63_6E74

    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID]? {
        var addr = address(CMIOObjectPropertySelector(selector))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return nil }
        return ids
    }

    private static func cfString(of object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func device(uid: String = deviceUID) -> CMIOObjectID? {
        guard let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) else { return nil }
        return devices.first { cfString(of: $0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == uid }
    }

    static func stream(of device: CMIOObjectID, direction: UInt32) -> CMIOStreamID? {
        guard let streams = objectIDs(of: device, kCMIODevicePropertyStreams) else { return nil }
        return streams.first { stream in
            var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            var dir: UInt32 = .max
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &dir)
            return status == noErr && dir == direction
        }
    }

    static func clientCount(sourceStream: CMIOStreamID) -> Int? {
        cfString(of: sourceStream, clientCountSelector).flatMap { Int($0) }
    }
}
