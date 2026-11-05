import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os

/// Newest frame from the app (sink) plus the idle fallback, shared with the source timer.
final class FrameStore {
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    private var arrivalNs: UInt64 = 0
    let idlePixelBuffer: CVPixelBuffer?

    init() {
        idlePixelBuffer = FrameStore.loadIdle()
    }

    func store(_ buffer: CMSampleBuffer, at nowNs: UInt64) {
        lock.lock(); latest = buffer; arrivalNs = nowNs; lock.unlock()
    }

    /// The live frame, or nil when there is none or it is older than 0.5 s.
    func current(now nowNs: UInt64) -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, nowNs &- arrivalNs <= MoobilityCamIDs.staleAfterNs else { return nil }
        return latest
    }

    private static func loadIdle() -> CVPixelBuffer? {
        let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam.Extension", category: "FrameStore")
        guard let url = Bundle.main.url(forResource: "idle", withExtension: "png"),
              let image = CIImage(contentsOf: url) else {
            log.error("idle.png missing from extension bundle")
            return nil
        }
        let w = Int(MoobilityCamIDs.width), h = Int(MoobilityCamIDs.height)
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        let e = image.extent
        let scale = max(CGFloat(w) / e.width, CGFloat(h) / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let se = scaled.extent
        let centred = scaled.transformed(by: CGAffineTransform(translationX: (CGFloat(w) - se.width) / 2 - se.minX,
                                                               y: (CGFloat(h) - se.height) / 2 - se.minY))
        CIContext().render(centred, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pb
    }
}
