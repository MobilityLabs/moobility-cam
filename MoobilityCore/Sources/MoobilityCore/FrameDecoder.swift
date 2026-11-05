@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes one frame at a time, synchronously: the pixels exist when `decode` returns.
public final class FrameDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?

    public init(format: CMFormatDescription) throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else { throw VideoCodecError.failed(status) }
        session = created
    }

    public func accepts(_ format: CMFormatDescription) -> Bool {
        guard let session else { return false }
        return VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format)
    }

    /// Returns nil when this frame fails to decode.
    public func decode(_ sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard let session else { return nil }
        final class Box: @unchecked Sendable { var pixels: CVPixelBuffer? }
        let box = Box()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr { box.pixels = image }
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return box.pixels
    }

    public func invalidate() {
        guard let session else { return }
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}
