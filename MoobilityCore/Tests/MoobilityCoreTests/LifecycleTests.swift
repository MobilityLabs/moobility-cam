import Foundation
import Testing
@testable import MoobilityCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// Final review: capture could stay "running" with no frames after a start failure,
/// a session runtime error, or a missed disconnect. The watchdog notices the silence.
@Suite struct FrameWatchdogTests {
    @Test func stallsWhenNoFirstFrameWithinTimeout() {
        var dog = FrameWatchdog(timeout: 3)
        dog.start(at: t0)
        #expect(!dog.isStalled(at: t0.addingTimeInterval(2.9)))
        #expect(dog.isStalled(at: t0.addingTimeInterval(3)))
    }

    @Test func eachFrameRestartsTheTimeout() {
        var dog = FrameWatchdog(timeout: 3)
        dog.start(at: t0)
        dog.frameDelivered(at: t0.addingTimeInterval(2))
        #expect(!dog.isStalled(at: t0.addingTimeInterval(4.9)))
        #expect(dog.isStalled(at: t0.addingTimeInterval(5)))
    }

    @Test func frameFromBeforeStartDoesNotCount() {
        var dog = FrameWatchdog(timeout: 3)
        dog.frameDelivered(at: t0)
        dog.start(at: t0.addingTimeInterval(10))
        #expect(dog.isStalled(at: t0.addingTimeInterval(13)))
    }

    @Test func neverStalledWhenNotStarted() {
        var dog = FrameWatchdog(timeout: 3)
        #expect(!dog.isStalled(at: t0.addingTimeInterval(100)))
        dog.start(at: t0)
        dog.stop()
        #expect(!dog.isStalled(at: t0.addingTimeInterval(100)))
    }
}

/// Final review: a failing sink connect retried forever without the spec's
/// "Moobility Cam not ready" after 10 s.
@Suite struct FailureClockTests {
    @Test func failingOnlyAfterThresholdOfContinuousFailure() {
        var clock = FailureClock(threshold: 10)
        clock.record(success: false, at: t0)
        clock.record(success: false, at: t0.addingTimeInterval(5))
        #expect(!clock.isFailing(at: t0.addingTimeInterval(9.9)))
        #expect(clock.isFailing(at: t0.addingTimeInterval(10)))
    }

    @Test func successClears() {
        var clock = FailureClock(threshold: 10)
        clock.record(success: false, at: t0)
        clock.record(success: true, at: t0.addingTimeInterval(11))
        #expect(!clock.isFailing(at: t0.addingTimeInterval(11)))
        clock.record(success: false, at: t0.addingTimeInterval(12))
        #expect(!clock.isFailing(at: t0.addingTimeInterval(21)))
        #expect(clock.isFailing(at: t0.addingTimeInterval(22)))
    }

    @Test func resetClears() {
        var clock = FailureClock(threshold: 10)
        clock.record(success: false, at: t0)
        clock.reset()
        #expect(!clock.isFailing(at: t0.addingTimeInterval(60)))
    }
}

/// Final review: a one-shot "didFirstRun" flag bound the login item to whichever
/// copy ran first (a Debug build, or a copy still inside the mounted DMG).
@Suite struct LoginItemPolicyTests {
    let installed = "/Applications/MoobilityCam.app"

    @Test func registersInstalledCopyWhenNotRegistered() {
        #expect(LoginItemPolicy.shouldRegister(.notRegistered, userOptedOut: false, bundlePath: installed))
        #expect(LoginItemPolicy.shouldRegister(.notFound, userOptedOut: false, bundlePath: installed))
    }

    @Test func leavesExistingOrPendingRegistrationAlone() {
        #expect(!LoginItemPolicy.shouldRegister(.enabled, userOptedOut: false, bundlePath: installed))
        #expect(!LoginItemPolicy.shouldRegister(.requiresApproval, userOptedOut: false, bundlePath: installed))
    }

    @Test func respectsOptOut() {
        #expect(!LoginItemPolicy.shouldRegister(.notRegistered, userOptedOut: true, bundlePath: installed))
    }

    @Test func neverRegistersACopyOutsideApplications() {
        for path in ["/Volumes/MoobilityCam/MoobilityCam.app",
                     "/Users/someone/sites/x/build/Build/Products/Debug/MoobilityCam.app",
                     "/Applications.old/MoobilityCam.app"] {
            #expect(!LoginItemPolicy.shouldRegister(.notRegistered, userOptedOut: false, bundlePath: path))
        }
    }
}
