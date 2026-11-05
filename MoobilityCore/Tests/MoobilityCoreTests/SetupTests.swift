import Foundation
import Testing
@testable import MoobilityCore

@Suite struct SetupStateTests {
    private func facts(apps: Bool = true, camera: CameraAccess = .granted, ext: Bool = true, seen: Bool = true) -> SetupFacts {
        SetupFacts(inApplications: apps, camera: camera, extensionActive: ext, hasSeenClient: seen)
    }

    @Test func currentStepFollowsOrder() {
        #expect(SetupState(facts(apps: false, camera: .notAsked, ext: false, seen: false)).currentStep == .applications)
        #expect(SetupState(facts(camera: .notAsked, ext: false, seen: false)).currentStep == .camera)
        #expect(SetupState(facts(camera: .denied, ext: false, seen: false)).currentStep == .camera)
        #expect(SetupState(facts(ext: false, seen: false)).currentStep == .approveExtension)
        #expect(SetupState(facts(seen: false)).currentStep == .callApp)
        #expect(SetupState(facts()).currentStep == nil)
        #expect(SetupState(facts()).isComplete)
    }

    @Test func stepsCompleteInAnyOrder() {
        let state = SetupState(facts(apps: false, camera: .granted, ext: false, seen: false))
        #expect(state.isDone(.camera))
        #expect(!state.isDone(.applications))
        #expect(state.currentStep == .applications)
        #expect(!state.isComplete)
    }

    @Test func dependentStepsAreDisabled() {
        let outside = SetupState(facts(apps: false, camera: .notAsked, ext: false, seen: false))
        #expect(outside.isEnabled(.applications))
        #expect(outside.isEnabled(.camera))
        #expect(!outside.isEnabled(.approveExtension))
        #expect(!outside.isEnabled(.callApp))
        let noExtension = SetupState(facts(ext: false, seen: false))
        #expect(noExtension.isEnabled(.approveExtension))
        #expect(!noExtension.isEnabled(.callApp))
        let noCamera = SetupState(facts(camera: .denied, seen: false))
        #expect(!noCamera.isEnabled(.callApp))
    }

    @Test func opensAtLaunchRules() {
        #expect(SetupState(facts(apps: false)).opensAtLaunch(finishedBefore: true))
        #expect(!SetupState(facts()).opensAtLaunch(finishedBefore: false))
        #expect(SetupState(facts(seen: false)).opensAtLaunch(finishedBefore: false))
        #expect(!SetupState(facts(ext: false)).opensAtLaunch(finishedBefore: true))
    }
}

/// An in-memory file system with failures on demand.
private final class FakeFiles: @unchecked Sendable {
    var paths: Set<String>
    var failCopy = false
    var failRenameTo: Set<String> = []
    var failRemove = false
    var removed: [String] = []
    var lose: String?   // a path that vanishes right after being moved to
    var movesToDestination = 0

    init(_ paths: Set<String>) { self.paths = paths }

    var ops: AppMover.Ops {
        AppMover.Ops(
            copy: { from, to in
                if self.failCopy { throw CocoaError(.fileWriteUnknown) }
                self.paths.insert(to.path)
            },
            rename: { from, to in
                if self.failRenameTo.contains(where: { to.path.hasPrefix($0) }) { throw CocoaError(.fileWriteUnknown) }
                self.paths.remove(from.path)
                if to.path != self.lose { self.paths.insert(to.path) }
            },
            remove: { url in
                if self.failRemove { throw CocoaError(.fileWriteUnknown) }
                self.paths.remove(url.path)
                self.removed.append(url.path)
            },
            exists: { self.paths.contains($0.path) }
        )
    }
}

@Suite struct AppMoverTests {
    private let source = URL(fileURLWithPath: "/Volumes/Moobility Cam/MoobilityCam.app")
    private let destination = URL(fileURLWithPath: "/Applications/MoobilityCam.app")

    private func hidden(_ files: FakeFiles) -> [String] {
        files.paths.filter { $0.hasPrefix("/Applications/.") }.sorted()
    }

    @Test func decideInstall() {
        let destination = self.destination
        let decide = { (from: URL, installed: InstalledCopy) in
            AppMover.decide(runningFrom: from, destination: destination, myBuild: 10, installed: installed)
        }
        #expect(decide(destination, .build(10)) == .alreadyInPlace)
        #expect(decide(source, .none) == .installFresh)
        #expect(decide(source, .build(9)) == .replaceOlder)
        #expect(decide(source, .build(10)) == .openInstalled)
        #expect(decide(source, .build(11)) == .openInstalled)
        #expect(decide(source, .unreadable) == .blockedByUnreadable)
    }

    @Test func freshInstallHasNoBackup() throws {
        let files = FakeFiles([source.path])
        try AppMover.install(from: source, to: destination, ops: files.ops)
        #expect(files.paths.contains(destination.path))
        #expect(hidden(files).isEmpty)
        #expect(files.paths.contains(source.path), "the original stays where it is")
    }

    @Test func replaceRemovesBackupOnSuccess() throws {
        let files = FakeFiles([source.path, destination.path])
        try AppMover.install(from: source, to: destination, ops: files.ops)
        #expect(files.paths.contains(destination.path))
        #expect(hidden(files).isEmpty)
    }

    @Test func copyFailureLeavesEverythingAlone() {
        let files = FakeFiles([source.path, destination.path])
        files.failCopy = true
        #expect(throws: AppMover.MoveError.copyFailed) { try AppMover.install(from: source, to: destination, ops: files.ops) }
        #expect(files.paths == [source.path, destination.path])
    }

    @Test func backupFailureRemovesOnlyTheStagedCopy() {
        let files = FakeFiles([source.path, destination.path])
        files.failRenameTo = ["/Applications/.MoobilityCam-old"]
        #expect(throws: AppMover.MoveError.backupFailed) { try AppMover.install(from: source, to: destination, ops: files.ops) }
        #expect(files.paths.contains(destination.path))
        #expect(!files.removed.contains(destination.path), "the existing app is never removed")
        #expect(hidden(files).isEmpty)
    }

    @Test func installFailureRestoresBackup() {
        let files = FakeFiles([source.path, destination.path])
        files.failRenameTo = [destination.path]
        // The restore also renames to the destination, so let only the first one fail.
        let ops = files.ops
        let destination = self.destination
        let flaky = AppMover.Ops(copy: ops.copy, rename: { from, to in
            if to.path == destination.path {
                files.movesToDestination += 1
                if files.movesToDestination == 1 { throw CocoaError(.fileWriteUnknown) }
                files.failRenameTo = []
            }
            try ops.rename(from, to)
        }, remove: ops.remove, exists: ops.exists)
        #expect(throws: AppMover.MoveError.installFailed) { try AppMover.install(from: source, to: destination, ops: flaky) }
        #expect(files.paths.contains(destination.path))
        #expect(hidden(files).isEmpty)
    }

    @Test func restoreFailureReportsBackupPath() throws {
        let files = FakeFiles([source.path, destination.path])
        files.failRenameTo = [destination.path]
        do {
            try AppMover.install(from: source, to: destination, ops: files.ops)
            Issue.record("expected a failure")
        } catch let AppMover.MoveError.restoreFailed(backup) {
            #expect(backup.hasPrefix("/Applications/.MoobilityCam-old"))
            #expect(files.paths.contains(backup), "the backup is kept")
        }
    }

    @Test func postMoveMissingDestinationCountsAsFailure() {
        let files = FakeFiles([source.path, destination.path])
        // The move "succeeds" but nothing is there. The restore then puts the old copy back.
        files.lose = destination.path
        let ops = files.ops
        let destination = self.destination
        let lossy = AppMover.Ops(copy: ops.copy, rename: { from, to in
            if to.path == destination.path {
                files.movesToDestination += 1
                if files.movesToDestination == 2 { files.lose = nil }
            }
            try ops.rename(from, to)
        }, remove: ops.remove, exists: ops.exists)
        #expect(throws: AppMover.MoveError.installFailed) { try AppMover.install(from: source, to: destination, ops: lossy) }
        #expect(files.paths.contains(destination.path))
        #expect(hidden(files).isEmpty)
    }
}

@Suite struct DeviceRecoveryTests {
    private let start = Date(timeIntervalSince1970: 1000)

    private func next(missing: Double?, active: Double?, now: Double, relaunched: Bool = false) -> DeviceRecovery {
        DeviceRecovery.next(missingSince: missing.map { start.addingTimeInterval($0) },
                            activeSince: active.map { start.addingTimeInterval($0) },
                            now: start.addingTimeInterval(now), alreadyRelaunched: relaunched)
    }

    @Test func nothingMissingOrNotActiveMeansWait() {
        #expect(next(missing: nil, active: 0, now: 100) == .wait)
        #expect(next(missing: 0, active: nil, now: 100) == .wait)
    }

    @Test func waitsFromWhenTheExtensionBecameActive() {
        // Missing since launch, but approved only just now: a person takes longer than 20 s in Settings.
        #expect(next(missing: 0, active: 95, now: 100) == .wait)
        #expect(next(missing: 0, active: 95, now: 114) == .wait)
        #expect(next(missing: 0, active: 95, now: 115) == .relaunch)
    }

    @Test func waitsFromWhenTheDeviceWentMissing() {
        #expect(next(missing: 95, active: 0, now: 100) == .wait)
        #expect(next(missing: 95, active: 0, now: 115) == .relaunch)
    }

    @Test func relaunchesOnceThenAsksForARestart() {
        #expect(next(missing: 0, active: 0, now: 30, relaunched: true) == .askForRestart)
    }
}
