@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoCodecError: Error, Equatable {
    case failed(OSStatus)
}

/// Compresses camera frames in real time. Frames arrive at `onFrame` on VideoToolbox's thread, in order.
public final class FrameEncoder: @unchecked Sendable {
    public private(set) var usesHEVC = false

    private let onFrame: @Sendable (CMSampleBuffer, _ isKeyframe: Bool, _ startsRun: Bool) -> Void
    private var session: VTCompressionSession?
    private var size: (width: Int, height: Int)?

    public init(onFrame: @escaping @Sendable (CMSampleBuffer, _ isKeyframe: Bool, _ startsRun: Bool) -> Void) {
        self.onFrame = onFrame
    }

    /// Creates the session on first use and on any size change. Throws on session failure.
    public func encode(_ pixels: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool, startsRun: Bool) throws {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if session == nil || size?.width != width || size?.height != height {
            drain()
            invalidate()
            session = try makeSession(width: width, height: height)
            size = (width, height)
        }
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let onFrame = self.onFrame
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            onFrame(sample, Self.isKeyframe(sample), startsRun)
        }
        guard status == noErr else { throw VideoCodecError.failed(status) }
    }

    /// Blocks until every submitted frame has been delivered.
    public func drain() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        size = nil
    }

    deinit { invalidate() }

    private func makeSession(width: Int, height: Int) throws -> VTCompressionSession {
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!] as CFDictionary
        var lastStatus: OSStatus = noErr
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
            var created: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            guard lastStatus == noErr, let created else { continue }
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: ReplayConstants.bitRate as CFNumber)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
            VTCompressionSessionPrepareToEncodeFrames(created)
            usesHEVC = codec == kCMVideoCodecType_HEVC
            return created
        }
        throw VideoCodecError.failed(lastStatus)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }
}
