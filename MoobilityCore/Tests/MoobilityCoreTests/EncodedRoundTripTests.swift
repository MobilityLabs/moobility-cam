@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MoobilityCore

private struct Delivered: @unchecked Sendable {
    let sample: CMSampleBuffer
    let isKeyframe: Bool
    let startsRun: Bool
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Delivered] = []
    func add(_ d: Delivered) { lock.lock(); items.append(d); lock.unlock() }
    var all: [Delivered] { lock.lock(); defer { lock.unlock() }; return items }
}

private func pixels(_ i: Int, _ width: Int = 1280, _ height: Int = 720) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!)!, Int32((i * 2) % 256), CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

private func time(_ i: Int) -> CMTime { CMTime(value: Int64(i), timescale: 30) }

private func encode(_ count: Int) throws -> [Delivered] {
    let collected = Collected()
    let encoder = FrameEncoder { sample, key, run in collected.add(Delivered(sample: sample, isKeyframe: key, startsRun: run)) }
    for i in 0..<count {
        try encoder.encode(pixels(i), at: time(i), forceKeyframe: false, startsRun: false)
    }
    encoder.drain()
    encoder.invalidate()
    return collected.all
}

private func timed(_ frames: [Delivered], duration: Double = 1.0 / 30) -> [TimedFrame<CMSampleBuffer>] {
    frames.map {
        TimedFrame(payload: $0.sample, duration: duration, isKeyframe: $0.isKeyframe, startsRun: false,
                   byteCount: CMSampleBufferGetTotalSampleSize($0.sample))
    }
}

private func grayValue(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.advanced(by: 360 * CVPixelBufferGetBytesPerRow(pb) + 640 * 4)
    return Int(base.assumingMemoryBound(to: UInt8.self)[1])
}

private func tempMovie() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
}

/// A hosted CI machine may have no video encoder. The release's rehearsal covers these there.
private let encoderAvailable: Bool = {
    final class Flag: @unchecked Sendable { var delivered = false }
    let flag = Flag()
    let encoder = FrameEncoder { _, _, _ in flag.delivered = true }
    defer { encoder.invalidate() }
    guard (try? encoder.encode(pixels(0), at: time(0), forceKeyframe: true, startsRun: true)) != nil else { return false }
    encoder.drain()
    return flag.delivered
}()

@Suite(.serialized, .enabled(if: encoderAvailable, "no video encoder on this machine")) struct EncodedRoundTripTests {
    @Test func encoderDeliversEveryFrameAfterDrain() throws {
        let frames = try encode(90)
        #expect(frames.count == 90)
        #expect(frames.first?.isKeyframe == true)
        let times = frames.map { CMSampleBufferGetPresentationTimeStamp($0.sample).seconds }
        #expect(times == times.sorted())
    }

    @Test func keyframesRoughlyEachSecond() throws {
        let frames = try encode(120)
        let keys = frames.indices.filter { frames[$0].isKeyframe }
        #expect(keys.count >= 3)
        for (a, b) in zip(keys, keys.dropFirst()) { #expect(b - a <= 31) }
    }

    @Test func forcedKeyframeAndRunMarkArrive() throws {
        let collected = Collected()
        let encoder = FrameEncoder { sample, key, run in collected.add(Delivered(sample: sample, isKeyframe: key, startsRun: run)) }
        for i in 0..<20 {
            try encoder.encode(pixels(i), at: time(i), forceKeyframe: i == 10, startsRun: i == 10)
        }
        encoder.drain()
        encoder.invalidate()
        let frames = collected.all
        #expect(frames.count == 20)
        #expect(frames[10].isKeyframe)
        #expect(frames[10].startsRun)
        #expect(!frames[9].startsRun)
    }

    @Test func sizeChangeStartsNewSession() throws {
        let collected = Collected()
        let encoder = FrameEncoder { sample, key, run in collected.add(Delivered(sample: sample, isKeyframe: key, startsRun: run)) }
        for i in 0..<10 { try encoder.encode(pixels(i), at: time(i), forceKeyframe: false, startsRun: false) }
        for i in 10..<20 { try encoder.encode(pixels(i, 640, 360), at: time(i), forceKeyframe: false, startsRun: false) }
        encoder.drain()
        encoder.invalidate()
        let frames = collected.all
        #expect(frames.count == 20)
        let format = try #require(CMSampleBufferGetFormatDescription(frames[19].sample))
        #expect(CMVideoFormatDescriptionGetDimensions(format).width == 640)
    }

    @Test func decoderReturnsPixelsSynchronously() throws {
        let frames = try encode(60)
        let format = try #require(CMSampleBufferGetFormatDescription(frames[0].sample))
        let decoder = try FrameDecoder(format: format)
        var decoded: [CVPixelBuffer] = []
        for frame in frames {
            decoded.append(try #require(decoder.decode(frame.sample)))
        }
        decoder.invalidate()
        #expect(decoded.count == 60)
        #expect(CVPixelBufferGetWidth(decoded[0]) == 1280)
        #expect(CVPixelBufferGetPixelFormatType(decoded[0]) == kCVPixelFormatType_32BGRA)
        #expect(abs(grayValue(decoded[0]) - grayValue(decoded[59])) > 40)
    }

    @Test func writeThenReadKeepsTail() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ClipFile.write(timed(try encode(90)), to: url)
        let back = try await ClipFile.read(from: url)
        #expect(back.count == 90)
        #expect(abs(back.reduce(0) { $0 + $1.duration } - 3.0) < 0.05)
        #expect(back.first?.isKeyframe == true)
        #expect(!back.contains { $0.startsRun })
    }

    @Test func writerAppendAndFinish() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try encode(90)
        let writer = try ClipWriter(url: url)
        for (i, frame) in frames.enumerated() {
            #expect(try writer.append(frame.sample, at: time(i)))
        }
        try await writer.finish(endTime: time(90))
        #expect(try await ClipFile.read(from: url).count == 90)
    }

    @Test func lateFrameStaysOutOfFile() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try encode(3)
        let writer = try ClipWriter(url: url, maxDuration: 0.4)
        let times = [0.0, 0.1, 0.5].map { CMTime(seconds: $0, preferredTimescale: 600) }
        #expect(try writer.append(frames[0].sample, at: times[0]))
        #expect(try writer.append(frames[1].sample, at: times[1]))
        #expect(try writer.append(frames[2].sample, at: times[2]) == false)
        try await writer.finish(endTime: CMTime(seconds: 0.13, preferredTimescale: 600))
        let back = try await ClipFile.read(from: url, minDuration: 0)
        #expect(back.count == 2)
        #expect(back.reduce(0) { $0 + $1.duration } < 0.4 + ReplayConstants.readSlack)
    }

    @Test func writerUsesGivenTimes() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try encode(3)
        let writer = try ClipWriter(url: url)
        let times = [0.0, 0.1, 0.5].map { CMTime(seconds: $0, preferredTimescale: 600) }
        for (frame, t) in zip(frames, times) { #expect(try writer.append(frame.sample, at: t)) }
        try await writer.finish(endTime: CMTime(seconds: 0.53, preferredTimescale: 600))
        let back = try await ClipFile.read(from: url, minDuration: 0)
        #expect(back.count == 3)
        #expect(abs(back[0].duration - 0.1) < 0.01)
        #expect(abs(back[1].duration - 0.4) < 0.01)
    }

    @Test func writerCancelDeletesFile() throws {
        let url = tempMovie()
        let frames = try encode(3)
        let writer = try ClipWriter(url: url)
        #expect(try writer.append(frames[0].sample, at: time(0)))
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fullLengthReadsBack() async throws {
        let group = try encode(30)
        func file(frameCount: Int) -> [TimedFrame<CMSampleBuffer>] {
            let one = timed(group)
            return (0..<frameCount).map { one[$0 % 30] }
        }
        let ok = tempMovie(), long = tempMovie()
        defer {
            try? FileManager.default.removeItem(at: ok)
            try? FileManager.default.removeItem(at: long)
        }
        try await ClipFile.write(file(frameCount: 9002), to: ok)  // 300.07 s
        #expect(try await ClipFile.read(from: ok).count == 9002)
        try await ClipFile.write(file(frameCount: 9015), to: long)  // 300.5 s
        await #expect(throws: ClipReadError.tooLong) { try await ClipFile.read(from: long) }
    }

    @Test func readErrorsMapToRefusals() {
        #expect(ReplayRefusal(ClipReadError.tooLong) == .clipTooLong)
        for error in [ClipReadError.tooBig, .tooShort, .notInOrder, .noVideo, .unreadable] {
            #expect(ReplayRefusal(error) == .badFile)
        }
        #expect(ReplayRefusal(ClipReadError.cancelled) == nil)
    }

    @Test func tooBigRefusedDuringRead() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ClipFile.write(timed(try encode(90)), to: url)
        await #expect(throws: ClipReadError.tooBig) { try await ClipFile.read(from: url, maxBytes: 10) }
    }

    @Test func tooShortRefused() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ClipFile.write(timed(try encode(60)), to: url)
        await #expect(throws: ClipReadError.tooShort) { try await ClipFile.read(from: url) }
    }

    @Test func cancelledStopsRead() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ClipFile.write(timed(try encode(90)), to: url)
        await #expect(throws: ClipReadError.cancelled) { try await ClipFile.read(from: url, isCancelled: { true }) }

        let calls = Collected()
        let probe = try encode(1)[0]
        await #expect(throws: ClipReadError.cancelled) {
            try await ClipFile.read(from: url, isCancelled: {
                calls.add(probe)
                return calls.all.count > 10
            })
        }
    }

    @Test func missingFileIsUnreadable() async {
        await #expect(throws: ClipReadError.unreadable) {
            try await ClipFile.read(from: URL(fileURLWithPath: "/nonexistent/clip.mov"))
        }
    }

    @Test func nonMovieIsRefused() async throws {
        let url = tempMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not a movie".write(to: url, atomically: false, encoding: .utf8)
        do {
            _ = try await ClipFile.read(from: url)
            Issue.record("expected a read error")
        } catch let error as ClipReadError {
            #expect(error == .unreadable || error == .noVideo)
        }
    }
}
