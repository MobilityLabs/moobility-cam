import Foundation
import Testing
@testable import MoobilityCore

@Suite struct ReplayCursorTests {
    private func cursor(_ n: Int, _ d: Double, runStarts: Set<Int> = [], keyEvery: Int = 1) -> ReplayCursor {
        ReplayCursor(durations: Array(repeating: d, count: n), runStarts: runStarts,
                     keyframes: Set(stride(from: 0, to: n, by: keyEvery)))
    }

    @Test func firstStepDecodesFrameZero() {
        var c = cursor(3, 0.1)
        let s = c.advance(toElapsed: 0)
        #expect(s.frameIndex == 0)
        #expect(s.decode == 0...0)
        #expect(!s.crossedSeam)
        #expect(!s.wrapped)
    }

    @Test func unevenDurations() {
        var c = ReplayCursor(durations: [0.1, 1.0 / 120, 1.0 / 30], runStarts: [], keyframes: [0])
        #expect(c.advance(toElapsed: 0.05).frameIndex == 0)
        #expect(c.advance(toElapsed: 0.104).frameIndex == 1)
        #expect(c.advance(toElapsed: 0.11).frameIndex == 2)
    }

    @Test func sameFrameDecodesNothing() {
        var c = cursor(3, 0.1)
        _ = c.advance(toElapsed: 0.01)
        let s = c.advance(toElapsed: 0.02)
        #expect(s.decode == nil)
        #expect(s.frameIndex == 0)
    }

    @Test func lateTickDecodesEveryFrameInBetween() {
        var c = cursor(10, 0.1, keyEvery: 10)
        _ = c.advance(toElapsed: 0)
        let s = c.advance(toElapsed: 0.55)
        #expect(s.frameIndex == 5)
        #expect(s.decode == 1...5)
        #expect(!s.crossedSeam)
    }

    @Test func wrapReportsSeamAndRestart() {
        var c = cursor(3, 0.1, keyEvery: 3)
        _ = c.advance(toElapsed: 0.25)
        let s = c.advance(toElapsed: 0.32)
        #expect(s.frameIndex == 0)
        #expect(s.wrapped)
        #expect(s.crossedSeam)
        #expect(s.decode == 0...0)
    }

    @Test func runStartReportsSeam() {
        var c = cursor(4, 0.1, runStarts: [2], keyEvery: 2)
        _ = c.advance(toElapsed: 0.15)
        let s = c.advance(toElapsed: 0.21)
        #expect(s.frameIndex == 2)
        #expect(s.crossedSeam)
        #expect(!s.wrapped)
    }

    @Test func lateTickDoesNotSkipSeamReport() {
        var c = cursor(4, 0.1, runStarts: [2], keyEvery: 2)
        _ = c.advance(toElapsed: 0.15)
        let s = c.advance(toElapsed: 0.35)
        #expect(s.frameIndex == 3)
        #expect(s.crossedSeam)
    }

    @Test func runStartAtFrameZeroIsNotASeamAtStart() {
        var c = cursor(4, 0.1, runStarts: [0])
        #expect(!c.advance(toElapsed: 0).crossedSeam)
    }

    @Test func hugeJumpStaysWithinBudget() throws {
        var c = cursor(9000, 1.0 / 30, keyEvery: 30)
        _ = c.advance(toElapsed: 1)
        let s = c.advance(toElapsed: 1_000_000)
        let range = try #require(s.decode)
        #expect(range.count <= ReplayCursor.decodeBudget)
        #expect(range.lowerBound % 30 == 0)
        #expect(s.crossedSeam)
    }

    @Test func skipAheadWithoutWrapIsASeam() throws {
        var c = cursor(900, 1.0 / 30, keyEvery: 30)
        _ = c.advance(toElapsed: 0)
        let s = c.advance(toElapsed: 10.5)
        let range = try #require(s.decode)
        #expect(range.lowerBound % 30 == 0)
        #expect(s.crossedSeam)
        #expect(!s.wrapped)
    }

    @Test func laggingCursorCatchesUp() throws {
        var c = cursor(900, 1.0 / 30, keyEvery: 30)
        _ = c.advance(toElapsed: 0)
        let target = 10.9  // frame 327; the nearest keyframe is 300, 27 frames back
        var last = c.advance(toElapsed: target)
        var previousEnd = try #require(last.decode).upperBound
        #expect(last.frameIndex == previousEnd)
        var ticks = 0
        while last.frameIndex < 327, ticks < 20 {
            last = c.advance(toElapsed: target)
            let range = try #require(last.decode)
            #expect(range.lowerBound == previousEnd + 1)
            #expect(range.count <= ReplayCursor.decodeBudget)
            #expect(last.frameIndex == range.upperBound)
            previousEnd = range.upperBound
            ticks += 1
        }
        #expect(last.frameIndex == 327)
        #expect(c.advance(toElapsed: target).decode == nil)
    }

    @Test func minimumLengthClipLoops() {
        var c = cursor(90, 1.0 / 30, keyEvery: 30)
        _ = c.advance(toElapsed: 2.99)
        let s = c.advance(toElapsed: 3.01)
        #expect(s.wrapped)
        #expect(s.frameIndex == 0)
    }

    @Test func clockStartsAtZero() {
        var clock = ReplayClock()
        #expect(clock.elapsed(at: 123456.7) == 0)
        #expect(abs(clock.elapsed(at: 123457.2) - 0.5) < 0.0001)
    }

    @Test func fadeMix() {
        let f = ReplayFade(start: 10)
        #expect(f.mix(at: 10) == 0)
        #expect(abs(f.mix(at: 10.25) - 0.5) < 0.0001)
        #expect(f.mix(at: 10.5) == 1)
        #expect(f.mix(at: 11) == 1)
        #expect(!f.isDone(at: 10.49))
        #expect(f.isDone(at: 10.5))
    }
}
