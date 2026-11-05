@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

public enum ClipReadError: Error, Equatable {
    case unreadable, noVideo, tooShort, tooLong, tooBig, notInOrder, cancelled
}

extension ReplayRefusal {
    /// nil for `.cancelled`. `.tooLong` is `.clipTooLong`; everything else is `.badFile`.
    public init?(_ error: ClipReadError) {
        switch error {
        case .cancelled: return nil
        case .tooLong: self = .clipTooLong
        case .unreadable, .noVideo, .tooShort, .tooBig, .notInOrder: self = .badFile
        }
    }
}

public enum ClipWriteError: Error, Equatable {
    case noFrames, failed
}

/// Writes already-encoded frames to a `.mov` with no re-encoding.
public final class ClipWriter: @unchecked Sendable {
    private let url: URL
    private let maxDuration: Double
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var firstTime: CMTime?

    public init(url: URL, maxDuration: Double = ReplayConstants.maxLength) throws {
        self.url = url
        self.maxDuration = maxDuration
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    /// Retimes a copy of `sample` to `time`, because a writer input uses the times inside the buffer.
    /// The session starts at the first `time`. Returns false, writing nothing, when `time` is
    /// `maxDuration` or more past the first; the caller then stops.
    public func append(_ sample: CMSampleBuffer, at time: CMTime) throws -> Bool {
        if let firstTime, (time - firstTime).seconds >= maxDuration { return false }
        let input = try inputStarting(with: sample, at: time)

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &retimed)
        guard status == noErr, let retimed else { throw ClipWriteError.failed }

        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? ClipWriteError.failed }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.append(retimed) else { throw writer.error ?? ClipWriteError.failed }
        return true
    }

    /// The file is complete on return.
    public func finish(endTime: CMTime) async throws {
        guard let input else {
            cancel()
            throw ClipWriteError.noFrames
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ClipWriteError.failed }
    }

    /// Deletes the file.
    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private func inputStarting(with sample: CMSampleBuffer, at time: CMTime) throws -> AVAssetWriterInput {
        if let input { return input }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw ClipWriteError.failed }
        let created = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        created.expectsMediaDataInRealTime = true
        guard writer.canAdd(created) else { throw ClipWriteError.failed }
        writer.add(created)
        guard writer.startWriting() else { throw writer.error ?? ClipWriteError.failed }
        writer.startSession(atSourceTime: time)
        input = created
        firstTime = time
        return created
    }
}

public enum ClipFile {
    /// Timestamps are rebuilt from the frames' durations.
    public static func write(_ frames: [TimedFrame<CMSampleBuffer>], to url: URL) async throws {
        let writer = try ClipWriter(url: url, maxDuration: .infinity)
        var seconds = 0.0
        do {
            for frame in frames {
                _ = try writer.append(frame.payload, at: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += frame.duration
            }
            try await writer.finish(endTime: CMTime(seconds: seconds, preferredTimescale: 600))
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Reads a clip's encoded frames without decoding them. Every limit and the cancel flag
    /// are checked per frame, before keeping it, so an oversized file can't pass the ceiling.
    public static func read(from url: URL, isCancelled: @Sendable () -> Bool = { false },
                            maxDuration: Double = ReplayConstants.maxLength + ReplayConstants.readSlack,
                            minDuration: Double = ReplayConstants.minLength,
                            maxBytes: Int = ReplayConstants.maxBytes) async throws -> [TimedFrame<CMSampleBuffer>] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipReadError.unreadable }
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let first = tracks.first else { throw ClipReadError.noVideo }
            track = first
        } catch let error as ClipReadError {
            throw error
        } catch {
            throw ClipReadError.unreadable
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ClipReadError.unreadable }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ClipReadError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw ClipReadError.unreadable }
        defer { reader.cancelReading() }

        var frames: [TimedFrame<CMSampleBuffer>] = []
        var bytes = 0
        var firstTime: Double?
        var lastTime: Double?
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw ClipReadError.cancelled }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let lastTime, time <= lastTime { throw ClipReadError.notInOrder }
            let start = firstTime ?? time
            firstTime = start
            if time - start > maxDuration { throw ClipReadError.tooLong }
            bytes += CMSampleBufferGetTotalSampleSize(sample)
            if bytes > maxBytes { throw ClipReadError.tooBig }
            if let lastTime, let previous = frames.indices.last {
                frames[previous].duration = time - lastTime
            }
            let own = CMSampleBufferGetDuration(sample)
            frames.append(TimedFrame(payload: sample,
                                     duration: own.isValid && own.seconds > 0 ? own.seconds : ReplayConstants.provisionalDuration,
                                     isKeyframe: FrameEncoder.isKeyframe(sample), startsRun: false,
                                     byteCount: CMSampleBufferGetTotalSampleSize(sample)))
            lastTime = time
        }
        guard reader.status == .completed else { throw ClipReadError.unreadable }
        guard !frames.isEmpty else { throw ClipReadError.noVideo }
        let total = frames.reduce(0) { $0 + $1.duration }
        if total > maxDuration { throw ClipReadError.tooLong }
        if total < minDuration - 0.05 { throw ClipReadError.tooShort }
        return frames
    }
}
