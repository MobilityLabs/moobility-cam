@preconcurrency import AVFoundation
import CoreImage
import MoobilityCore
import os
import Vision

/// Recent video and loop playback. Everything runs on the sink queue except where noted;
/// the encoder's callback hands frames over under `lock`.
final class ReplayEngine: @unchecked Sendable {
    typealias Footage = [TimedFrame<CMSampleBuffer>]

    /// Longer than this between camera frames counts as a break in the footage.
    private static let captureGap = 0.25

    private let compositor: Compositor
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "Replay")

    private let lock = NSLock()
    private var recent = RecentVideo<CMSampleBuffer>()  // lock
    private var holds = false                           // lock
    private var recordingActive = false                 // lock
    // A stalled disk blocks the writer. It gets its own queue so that can't hold `lock`, which the main actor takes.
    private let recordQueue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.record")
    private var recordingURL: URL?                      // recordQueue
    private var writer: ClipWriter?                     // recordQueue
    private var firstRecordedTime: CMTime?              // recordQueue
    private var lastRecordedTime: CMTime?               // recordQueue

    private var encoder: FrameEncoder?
    private var nextFrameBreaks = true
    private var lastCameraTime: CMTime?
    private var lastSize: (width: Int, height: Int)?
    private var heldLastFrame = false
    private var recordingNeedsKeyframe = false

    private var player: Player?

    /// Called on the sink queue when a whole pass of the footage decoded nothing.
    var onPlaybackFailed: (@Sendable () -> Void)?
    /// Called on the recording queue when a recording has to stop: its limit, or a write error.
    var onRecordingMustStop: (@Sendable () -> Void)?

    init(compositor: Compositor) {
        self.compositor = compositor
    }

    /// Any thread.
    var holdsRecentVideo: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holds }
        set { lock.lock(); holds = newValue; lock.unlock() }
    }

    /// Any thread.
    var heldSeconds: Double {
        lock.lock(); defer { lock.unlock() }; return recent.totalDuration
    }

    /// Sink queue only. The one replay flag the pipeline reads.
    var isPlaying: Bool { player != nil }

    // MARK: Recent video

    func cameraFrame(_ pixels: CVPixelBuffer, at time: CMTime) {
        guard !isPlaying else { return }
        lock.lock(); let wanted = holds, recording = recordingActive; lock.unlock()
        defer { heldLastFrame = wanted }
        guard wanted || recording else {
            nextFrameBreaks = true
            return
        }
        let size = (width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if let lastSize, lastSize != size { wipe() }
        lastSize = size

        var isBreak = nextFrameBreaks || (wanted && !heldLastFrame)
        if let lastCameraTime, (time - lastCameraTime).seconds > Self.captureGap { isBreak = true }
        lastCameraTime = time
        nextFrameBreaks = false
        let forceKeyframe = isBreak || recordingNeedsKeyframe
        recordingNeedsKeyframe = false

        do {
            try encoderForUse().encode(pixels, at: time, forceKeyframe: forceKeyframe, startsRun: isBreak)
        } catch {
            log.error("encoder failed: \(error.localizedDescription, privacy: .public)")
            encoder?.invalidate()
            encoder = nil
            wipe()
        }
    }

    /// A frame still in the encoder can't start the store unless it's a keyframe.
    func wipe() {
        lock.lock(); recent.removeAll(); lock.unlock()
        nextFrameBreaks = true
    }

    /// Stops nothing: encoding carries on after the drain.
    func snapshot(last seconds: Double) -> Footage {
        encoder?.drain()
        lock.lock(); defer { lock.unlock() }
        return recent.window(last: seconds)
    }

    private func encoderForUse() -> FrameEncoder {
        if let encoder { return encoder }
        let created = FrameEncoder { [weak self] sample, isKeyframe, startsRun in
            self?.encoded(sample, isKeyframe: isKeyframe, startsRun: startsRun)
        }
        encoder = created
        return created
    }

    /// VideoToolbox's thread.
    private func encoded(_ sample: CMSampleBuffer, isKeyframe: Bool, startsRun: Bool) {
        lock.lock(); defer { lock.unlock() }
        if recordingActive {
            recordQueue.async { [self] in record(sample, isKeyframe: isKeyframe) }
        }
        guard holds else { return }
        // A wipe can land between a frame's submission and its delivery. The store must start on a keyframe.
        if recent.frames.isEmpty, !isKeyframe { return }
        recent.append(sample, captureTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                      isKeyframe: isKeyframe, startsRun: startsRun || recent.frames.isEmpty,
                      byteCount: CMSampleBufferGetTotalSampleSize(sample))
    }

    // MARK: Recording

    /// The clip starts at the next frame, which is forced to be a keyframe.
    func beginRecording(to url: URL) {
        recordQueue.async { [self] in
            recordingURL = url
            writer = nil
            firstRecordedTime = nil
            lastRecordedTime = nil
        }
        lock.lock(); recordingActive = true; lock.unlock()
        recordingNeedsKeyframe = true
    }

    /// Stops, drains so the tail is kept, and finishes the file. Returns the length through `completion`.
    func finishRecording(completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        encoder?.drain()  // anything delivered is on recordQueue ahead of the block below
        lock.lock(); recordingActive = false; lock.unlock()
        recordQueue.async { [self] in
            let writer = self.writer
            let first = firstRecordedTime, last = lastRecordedTime
            self.writer = nil
            recordingURL = nil
            guard let writer, let first, let last else {
                writer?.cancel()
                completion(.failure(ClipWriteError.noFrames))
                return
            }
            let frameLength = CMTime(value: 1, timescale: 30)
            Task.detached(priority: .userInitiated) {
                do {
                    try await writer.finish(endTime: last + frameLength)
                    completion(.success((last + frameLength - first).seconds))
                } catch {
                    writer.cancel()
                    completion(.failure(error))
                }
            }
        }
    }

    /// On `recordQueue`.
    private func record(_ sample: CMSampleBuffer, isKeyframe: Bool) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        do {
            if writer == nil {
                guard isKeyframe, let recordingURL else { return }  // a clip starts on a keyframe
                writer = try ClipWriter(url: recordingURL)
            }
            if try writer?.append(sample, at: time) == true {
                if firstRecordedTime == nil { firstRecordedTime = time }
                lastRecordedTime = time
                return
            }
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
        }
        lock.lock(); recordingActive = false; lock.unlock()
        onRecordingMustStop?()
    }

    // MARK: Playback

    /// Pauses encoding and drains it first, so nothing grows the store during replay. Replaces any current playback.
    func startPlayback(_ footage: Footage, mode: CameraMode) {
        encoder?.drain()
        nextFrameBreaks = true
        player = Player(footage: footage, mode: mode, compositor: compositor)
        if player == nil { onPlaybackFailed?() }
    }

    func stopPlayback() {
        player = nil
        nextFrameBreaks = true
    }

    /// While playing, the image for this tick, and whether it crossed a seam. Nil when not playing.
    func nextImage(at hostTime: Double) -> (image: CIImage, crossedSeam: Bool)? {
        guard let player else { return nil }
        guard let next = player.next(at: hostTime) else {
            log.error("replay decoded nothing in a full pass")
            onPlaybackFailed?()
            return nil
        }
        return next
    }
}

/// One replay: decodes in order, one tick at a time, and composites with the mode it started in.
private final class Player {
    private let footage: ReplayEngine.Footage
    private let mode: CameraMode
    private let compositor: Compositor
    private var cursor: ReplayCursor
    private var clock = ReplayClock()
    private var decoder: FrameDecoder

    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var handler = VNSequenceRequestHandler()

    private var camera: CIImage?
    private var mask: CIImage?
    private var awaitingKeyframe = false
    private var decodedThisPass = false

    init?(footage: ReplayEngine.Footage, mode: CameraMode, compositor: Compositor) {
        guard let first = footage.first, let format = CMSampleBufferGetFormatDescription(first.payload),
              let decoder = try? FrameDecoder(format: format) else { return nil }
        self.footage = footage
        self.mode = mode
        self.compositor = compositor
        self.decoder = decoder
        cursor = ReplayCursor(durations: footage.map(\.duration),
                              runStarts: Set(footage.indices.filter { footage[$0].startsRun }),
                              keyframes: Set(footage.indices.filter { footage[$0].isKeyframe }))
    }

    /// Nil when a whole pass decoded nothing.
    func next(at hostTime: Double) -> (image: CIImage, crossedSeam: Bool)? {
        let step = cursor.advance(toElapsed: clock.elapsed(at: hostTime))
        if step.wrapped {
            if !decodedThisPass { return nil }
            decodedThisPass = false
        }
        if step.crossedSeam {
            handler = VNSequenceRequestHandler()  // temporal state must not carry across a cut
            awaitingKeyframe = false
        }

        if let range = step.decode, let pixels = decode(range) {
            decodedThisPass = true
            camera = CIImage(cvPixelBuffer: pixels)
            if mode != .plainCamera { segment(pixels) }
        }

        guard let camera else { return (compositor.backgroundFrame(), step.crossedSeam) }  // never raw before a mask
        let image = mode == .plainCamera ? compositor.plain(camera: camera)
                                         : compositor.composite(camera: camera, mask: mask)
        return (image, step.crossedSeam)
    }

    /// Decodes the whole range in order and returns its last good frame.
    /// After a failed frame, skips forward to the next keyframe while the last good frame repeats.
    private func decode(_ range: ClosedRange<Int>) -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        for index in range {
            let frame = footage[index]
            if awaitingKeyframe {
                guard frame.isKeyframe else { continue }
                awaitingKeyframe = false
            }
            if let format = CMSampleBufferGetFormatDescription(frame.payload), !decoder.accepts(format) {
                decoder.invalidate()
                guard let fresh = try? FrameDecoder(format: format) else {
                    awaitingKeyframe = true
                    continue
                }
                decoder = fresh
            }
            if let pixels = decoder.decode(frame.payload) {
                result = pixels
            } else {
                awaitingKeyframe = true
            }
        }
        return result
    }

    private func segment(_ pixels: CVPixelBuffer) {
        do {
            try handler.perform([request], on: pixels)
            if let m = request.results?.first?.pixelBuffer { mask = CIImage(cvPixelBuffer: m) }
        } catch {
            // Keeps the last mask; with none yet, the compositor sends the background alone.
        }
    }
}
