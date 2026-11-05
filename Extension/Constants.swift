import CoreMediaIO
import CoreMedia
import Foundation

/// Fixed identifiers shared with the app (spec § Global Constraints).
enum MoobilityCamIDs {
    static let deviceUID = UUID(uuidString: "5A8F3C1E-2B7D-4E9A-8C6F-0D1B2E3F4A5B")!
    static let sourceStreamUID = UUID(uuidString: "5A8F3C1E-2B7D-4E9A-8C6F-0D1B2E3F4A5C")!
    static let sinkStreamUID = UUID(uuidString: "5A8F3C1E-2B7D-4E9A-8C6F-0D1B2E3F4A5D")!
    static let deviceName = "Moobility Cam"
    static let clientCountProperty = CMIOExtensionProperty(rawValue: "4cc_mcnt_glob_0000")

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameDuration = CMTime(value: 1, timescale: 30)
    static let staleAfterNs: UInt64 = 500_000_000

    static let videoFormat: CMFormatDescription = {
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: width, height: height, extensions: nil, formatDescriptionOut: &desc)
        return desc!
    }()

    static let streamFormat = CMIOExtensionStreamFormat(formatDescription: videoFormat,
                                                        maxFrameDuration: frameDuration,
                                                        minFrameDuration: frameDuration,
                                                        validFrameDurations: nil)
}

/// Current host-clock time in nanoseconds (the timebase CMIO uses for hostTimeInNanoseconds).
func hostTimeNs() -> UInt64 {
    let t = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default)
    return UInt64(max(t.value, 0))
}
