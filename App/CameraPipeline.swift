@preconcurrency import AVFoundation
import CoreImage
import MoobilityCore
import os
import Vision

/// Webcam → person mask → composite over the background → SinkConnection.
/// Camera frames and filler frames are produced on `sink.queue`, so `sink.send` is called on its own queue.
/// Until the webcam delivers (and in Background only mode, always) a 30 fps filler sends the background,
/// so the raw camera never goes out and clients never fall back to the extension's idle image.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let compositor = Compositor()
    let replay: ReplayEngine
    private let sink: SinkConnection
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.mobilitylabs.MoobilityCam.session")
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "Pipeline")

    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastMask: CIImage?
    private var pool: CVPixelBufferPool?
    private var lastOutput: CVPixelBuffer?   // sink.queue; the most recent frame sent
    private var fadeFrom: CVPixelBuffer?     // sink.queue
    private var fade: ReplayFade?            // sink.queue

    private let flagLock = NSLock()
    private var _mode: CameraMode = .overBackground
    private var _lastFrameAt: Date?
    private var _sending = false

    var mode: CameraMode {
        flagLock.lock(); defer { flagLock.unlock() }; return _mode
    }

    /// When the webcam last delivered a frame; read from main by AppModel's stall check.
    var lastFrameAt: Date? {
        flagLock.lock(); defer { flagLock.unlock() }; return _lastFrameAt
    }

    private(set) var activeDevice: AVCaptureDevice?
    private var device: AVCaptureDevice?  // sessionQueue
    private var cameraWanted = false      // sessionQueue; the Record sheet's demand
    private var filler: DispatchSourceTimer?  // sink.queue
    /// For the Record sheet's preview layer.
    var captureSession: AVCaptureSession { session }
    static let fillerAfter: TimeInterval = 0.25

    init(sink: SinkConnection) {
        self.sink = sink
        replay = ReplayEngine(compositor: compositor)
        super.init()
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(Compositor.outputSize.width),
            kCVPixelBufferHeightKey: Int(Compositor.outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// Prefers an external or Continuity camera, then the built-in one. Never returns Moobility Cam itself.
    static func defaultSource() -> AVCaptureDevice? {
        let devices = availableSources()
        for type in [AVCaptureDevice.DeviceType.external, .continuityCamera, .builtInWideAngleCamera] {
            if let d = devices.first(where: { $0.deviceType == type }) { return d }
        }
        return devices.first
    }

    static func availableSources() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .continuityCamera, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified)
            .devices
            .filter { $0.uniqueID != CMIOLookup.deviceUID && $0.localizedName != "Moobility Cam" }
    }

    func setBackground(_ image: CIImage) {
        compositor.setBackground(image)
    }

    /// Starts sending frames. With `device` nil the filler sends the background until `setSource` gives it a camera.
    func startSending(device: AVCaptureDevice?) {
        flagLock.lock(); _sending = true; flagLock.unlock()
        sessionQueue.async { [self] in
            self.device = device
            updateCamera()
        }
        sink.queue.async { [self] in startFiller() }
    }

    func stopSending() {
        flagLock.lock(); _sending = false; flagLock.unlock()
        sessionQueue.async { [self] in updateCamera() }
        sink.queue.async { [self] in
            filler?.cancel()
            filler = nil
            // Nothing from this call may fade into the next one.
            lastOutput = nil
            fadeFrom = nil
            fade = nil
        }
    }

    // MARK: Replay. AppModel decides; these hand the work to sink.queue, so live and replay output can't interleave.

    func beginReplay(_ footage: ReplayEngine.Footage, mode: CameraMode) {
        sink.queue.async { [self] in
            startFade()
            replay.startPlayback(footage, mode: mode)
        }
    }

    func endReplay(fade fades: Bool) {
        sink.queue.async { [self] in
            replay.stopPlayback()
            if fades { startFade() }
            sequenceHandler = VNSequenceRequestHandler()
            lastMask = nil
        }
    }

    func snapshotRecent(seconds: Double, completion: @escaping @Sendable (ReplayEngine.Footage) -> Void) {
        sink.queue.async { [self] in completion(replay.snapshot(last: seconds)) }
    }

    func beginRecording(to url: URL) {
        sink.queue.async { [self] in replay.beginRecording(to: url) }
    }

    func finishRecording(completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        sink.queue.async { [self] in replay.finishRecording(completion: completion) }
    }

    func wipeRecent() {
        sink.queue.async { [self] in replay.wipe() }
    }

    /// Switches mode while running: Background only turns the webcam off, unless the Record sheet holds it.
    func setMode(_ newMode: CameraMode) {
        flagLock.lock(); _mode = newMode; flagLock.unlock()
        sessionQueue.async { [self] in updateCamera() }
    }

    /// The Record sheet's demand, which doesn't need the sink.
    func setCameraWanted(_ wanted: Bool, device: AVCaptureDevice?) {
        sessionQueue.async { [self] in
            cameraWanted = wanted
            if wanted {
                if device?.uniqueID != self.device?.uniqueID { stopSession() }
                self.device = device
            }
            updateCamera()
        }
    }

    /// Always stops and restarts the session when the camera should be running, even with the same device,
    /// because a stalled session can report that it's running. Doesn't touch the sink.
    func setSource(_ device: AVCaptureDevice?) {
        sessionQueue.async { [self] in
            self.device = device
            stopSession()
            updateCamera()
        }
    }

    private func updateCamera() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        flagLock.lock(); let sending = _sending, mode = _mode; flagLock.unlock()
        if (sending && mode.needsCamera) || cameraWanted {
            if !session.isRunning, let device { runSession(on: device) }
        } else {
            stopSession()
        }
    }

    private func runSession(on device: AVCaptureDevice) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            log.error("camera input failed: \(error.localizedDescription, privacy: .public)")
            session.commitConfiguration()
            return  // no frames; AppModel's stall check retries
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sink.queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            log.error("camera output could not be added")  // no frames; AppModel's stall check retries
        }
        session.commitConfiguration()
        activeDevice = device
        sink.queue.async { [self] in lastMask = nil }
        session.startRunning()
        log.info("capture started on \(device.localizedName, privacy: .public)")
    }

    private func stopSession() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard session.isRunning else { return }
        session.stopRunning()
        activeDevice = nil
        log.info("capture stopped")
    }

    // MARK: Frames (on sink.queue)

    private func startFiller() {
        filler?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sink.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        filler = timer
    }

    /// The only thing that sends during replay: replay comes before the filler's freshness check,
    /// so a healthy webcam can't silence the output and a stalled one can't let the background through.
    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let next = replay.nextImage(at: now.seconds) {
            if next.crossedSeam { startFade() }
            send(next.image, at: now, duration: CMTime(value: 1, timescale: 30))
            return
        }
        fillIfNeeded()
    }

    private func fillIfNeeded() {
        let now = Date()
        if mode.needsCamera, let last = lastFrameAt, now.timeIntervalSince(last) < Self.fillerAfter { return }
        send(compositor.backgroundFrame(), at: CMClockGetTime(CMClockGetHostTimeClock()),
             duration: CMTime(value: 1, timescale: 30))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        flagLock.lock(); _lastFrameAt = Date(); let sending = _sending, mode = _mode; flagLock.unlock()
        replay.cameraFrame(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard sending, mode.needsCamera, !replay.isPlaying else { return }
        let camera = CIImage(cvPixelBuffer: pixels)
        let image: CIImage
        if mode == .plainCamera {
            image = compositor.plain(camera: camera)
        } else {
            do {
                try sequenceHandler.perform([request], on: pixels)
                if let m = request.results?.first?.pixelBuffer { lastMask = CIImage(cvPixelBuffer: m) }
            } catch {
                log.debug("segmentation failed: \(error.localizedDescription, privacy: .public)")
            }
            image = compositor.composite(camera: camera, mask: lastMask)  // nil mask → background, never raw camera
        }
        send(image, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: CMSampleBufferGetDuration(sampleBuffer))
    }

    /// Holds the most recent output and dissolves from it, for the loop seam, run breaks, entering replay and going live.
    private func startFade() {
        guard let lastOutput else { return }
        fadeFrom = lastOutput
        fade = ReplayFade(start: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    private func faded(_ image: CIImage, at seconds: Double) -> CIImage {
        guard let fade, let fadeFrom else { return image }
        if fade.isDone(at: seconds) {
            self.fade = nil
            self.fadeFrom = nil
            return image
        }
        return compositor.blend(from: CIImage(cvPixelBuffer: fadeFrom), to: image, mix: fade.mix(at: seconds))
    }

    private func send(_ image: CIImage, at pts: CMTime, duration: CMTime) {
        guard let pool else { return }
        var outPixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPixels)
        guard let outPixels else { return }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        compositor.render(faded(image, at: hostNow), into: outPixels)
        lastOutput = outPixels
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: outPixels,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: outPixels,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &out)
        if let out { sink.send(out) }
    }
}
