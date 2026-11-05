import Foundation
import Testing
@testable import MoobilityCore

@Suite struct RecentVideoTests {
    private func close(_ a: Double, _ b: Double, within: Double = 0.0001) -> Bool { abs(a - b) < within }

    @Test func durationsAssignGapToPrecedingFrame() {
        var v = RecentVideo<Int>()
        v.append(0, captureTime: 0, isKeyframe: true, startsRun: true, byteCount: 1)
        v.append(1, captureTime: 0.100, isKeyframe: false, startsRun: false, byteCount: 1)
        v.append(2, captureTime: 0.108, isKeyframe: false, startsRun: false, byteCount: 1)
        #expect(close(v.frames[0].duration, 0.100))
        #expect(close(v.frames[1].duration, 1.0 / 120))
        #expect(close(v.frames[2].duration, 1.0 / 30))

        var w = RecentVideo<Int>()
        w.append(0, captureTime: 0, isKeyframe: true, startsRun: true, byteCount: 1)
        w.append(1, captureTime: 0.1, isKeyframe: false, startsRun: false, byteCount: 1)
        w.append(2, captureTime: 0.11, isKeyframe: false, startsRun: false, byteCount: 1)
        #expect(close(w.frames[0].duration, 0.1))
        #expect(close(w.frames[1].duration, 0.01))
        #expect(close(w.frames[2].duration, 1.0 / 30))
    }

    @Test func durationGapIsLimited() {
        var v = RecentVideo<Int>()
        v.append(0, captureTime: 0, isKeyframe: true, startsRun: true, byteCount: 1)
        v.append(1, captureTime: 5, isKeyframe: false, startsRun: false, byteCount: 1)
        #expect(close(v.frames[0].duration, 0.1))
    }

    @Test func runStartLeavesPreviousFrameAlone() {
        var v = RecentVideo<Int>()
        v.append(0, captureTime: 0, isKeyframe: true, startsRun: true, byteCount: 1)
        v.append(1, captureTime: 90, isKeyframe: true, startsRun: true, byteCount: 1)
        #expect(close(v.frames[0].duration, 1.0 / 30))
        #expect(close(v.totalDuration, 2.0 / 30))
    }

    @Test func trimsAtKeyframeByDuration() {
        var v = RecentVideo<Int>(maxDuration: 3)
        for i in 0..<150 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i % 30 == 0, startsRun: i == 0, byteCount: 1)
        }
        #expect(v.frames[0].isKeyframe)
        #expect(v.totalDuration <= 3)
        #expect(v.totalDuration > 2)
    }

    @Test func trimsAtKeyframeBySize() {
        var v = RecentVideo<Int>(maxBytes: 100)
        for i in 0..<100 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i % 5 == 0, startsRun: i == 0, byteCount: 10)
        }
        #expect(v.frames[0].isKeyframe)
        #expect(v.totalBytes <= 100)
        #expect(v.totalBytes > 0)
    }

    @Test func neverTrimsTheOnlyKeyframeGroup() {
        var v = RecentVideo<Int>(maxDuration: 1)
        for i in 0..<61 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i == 0, startsRun: i == 0, byteCount: 1)
        }
        #expect(v.frames.count == 61)
    }

    @Test func windowStartsOnKeyframeAtOrBefore() {
        var v = RecentVideo<Int>()
        for i in 0..<300 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i % 30 == 0, startsRun: i == 0, byteCount: 1)
        }
        let w = v.window(last: 2.5)
        #expect(w[0].isKeyframe)
        let length = w.reduce(0) { $0 + $1.duration }
        #expect(length >= 2.5)
        #expect(length < 3.5)
        #expect(w.last?.payload == 299)
    }

    @Test func windowOnShortStoreReturnsEverything() {
        var v = RecentVideo<Int>()
        for i in 0..<60 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i % 30 == 0, startsRun: i == 0, byteCount: 1)
        }
        #expect(v.window(last: 60).count == 60)
    }

    @Test func runMarksSurviveTrimming() {
        var v = RecentVideo<Int>(maxDuration: 3)
        for i in 0..<150 {
            v.append(i, captureTime: Double(i) / 30, isKeyframe: i % 30 == 0, startsRun: i == 0 || i == 120, byteCount: 1)
        }
        #expect(v.frames.contains { $0.payload == 120 && $0.startsRun })
    }

    @Test func removeAllEmptiesIt() {
        var v = RecentVideo<Int>()
        v.append(0, captureTime: 0, isKeyframe: true, startsRun: true, byteCount: 5)
        v.removeAll()
        #expect(v.frames.isEmpty)
        #expect(v.totalDuration == 0)
        #expect(v.totalBytes == 0)
    }

    @Test func emptyStoreWindowIsEmpty() {
        #expect(RecentVideo<Int>().window(last: 10).isEmpty)
    }
}
