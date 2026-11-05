import Foundation
import Testing
@testable import MoobilityCore

/// Final review: a load for a choice the user has left must never reach the camera.
@Suite struct BackgroundLoadTrackerTests {
    @Test func newChoiceStartsALoad() {
        var t = BackgroundLoadTracker()
        #expect(t.want("a") == .start(generation: 1))
    }

    @Test func sameChoiceDoesNotRestart() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        #expect(t.want("a") == .alreadyRunning)
    }

    @Test func finishedChoiceIsKept() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        #expect(t.finish(generation: 1, key: "a", succeeded: true) == true)
        #expect(t.want("a") == .keep)
    }

    @Test func newerChoiceDiscardsOlderLoad() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        #expect(t.want("b") == .start(generation: 2))
        #expect(t.finish(generation: 1, key: "a", succeeded: true) == false)
        #expect(t.finish(generation: 2, key: "b", succeeded: true) == true)
    }

    @Test func returningToShownImageCancelsInFlightLoad() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        _ = t.finish(generation: 1, key: "a", succeeded: true)
        #expect(t.want("b") == .start(generation: 2))
        #expect(t.want("a") == .keep)
        #expect(t.finish(generation: 2, key: "b", succeeded: true) == false)
        #expect(t.want("a") == .keep)
    }

    @Test func failedLoadCanBeRetriedAndIsNotKept() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        #expect(t.finish(generation: 1, key: "a", succeeded: false) == true)
        #expect(t.want("a") == .start(generation: 2))
    }

    @Test func abandonDiscardsAnyRunningLoad() {
        var t = BackgroundLoadTracker()
        _ = t.want("a")
        t.abandon()
        #expect(t.finish(generation: 1, key: "a", succeeded: true) == false)
    }
}

/// Final review: a failure belongs to the version of the file that was tried.
@Suite struct DecodeFailuresTests {
    let old = FileFingerprint(size: 1, modified: Date(timeIntervalSince1970: 1), inode: 1)
    let new = FileFingerprint(size: 2, modified: Date(timeIntervalSince1970: 2), inode: 2)

    @Test func failedVersionStaysFailed() {
        var f = DecodeFailures()
        f.record("a.jpg", at: old)
        #expect(f.isFailed("a.jpg", at: old))
        #expect(f.files == ["a.jpg"])
    }

    @Test func replacementIsNotBlamedForAnOlderVersion() {
        var f = DecodeFailures()
        f.record("a.jpg", at: old)
        #expect(!f.isFailed("a.jpg", at: new))
    }

    @Test func missingFileIsNotFailed() {
        var f = DecodeFailures()
        f.record("a.jpg", at: old)
        #expect(!f.isFailed("a.jpg", at: nil))
    }

    @Test func pruneForgetsChangedFiles() {
        var f = DecodeFailures()
        f.record("a.jpg", at: old)
        f.record("b.jpg", at: old)
        f.prune { $0 == "a.jpg" ? new : old }
        #expect(f.files == ["b.jpg"])
    }
}
