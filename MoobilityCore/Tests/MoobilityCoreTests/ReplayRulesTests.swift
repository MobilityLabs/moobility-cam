import Foundation
import Testing
@testable import MoobilityCore

@Suite struct ReplayRulesTests {
    private let last = ReplayTarget.last(seconds: 60)
    private let clip = ReplayTarget.clip(file: "a.mov")

    private func ok(client: Bool = true, sheet: Bool = false, recent: Bool = true,
                    mode: CameraMode = .overBackground, held: Double = 100) -> ReplayConditions {
        ReplayConditions(hasClient: client, recordSheetOpen: sheet, recentVideoOn: recent, mode: mode, heldSeconds: held)
    }

    @Test func everyRefusalRow() {
        #expect(ReplayRules.refusal(for: last, given: ok()) == nil)
        #expect(ReplayRules.refusal(for: clip, given: ok()) == nil)
        for target in [last, clip] {
            #expect(ReplayRules.refusal(for: target, given: ok(client: false)) == .noApp)
            #expect(ReplayRules.refusal(for: target, given: ok(sheet: true)) == .recordSheetOpen)
        }
        #expect(ReplayRules.refusal(for: last, given: ok(recent: false)) == .recentVideoOff)
        #expect(ReplayRules.refusal(for: clip, given: ok(recent: false)) == nil)
        #expect(ReplayRules.refusal(for: last, given: ok(mode: .backgroundOnly)) == .backgroundOnly)
        #expect(ReplayRules.refusal(for: last, given: ok(held: 1)) == .notEnoughVideo)
        #expect(ReplayRules.refusal(for: clip, given: ok(held: 0)) == nil)
    }

    @Test func refusalOrderFollowsTable() {
        #expect(ReplayRules.refusal(for: last, given: ok(client: false, sheet: true)) == .noApp)
        #expect(ReplayRules.refusal(for: last, given: ok(sheet: true, recent: false)) == .recordSheetOpen)
        #expect(ReplayRules.refusal(for: last, given: ok(recent: false, mode: .backgroundOnly)) == .recentVideoOff)
        #expect(ReplayRules.refusal(for: last, given: ok(mode: .backgroundOnly, held: 0)) == .backgroundOnly)
    }

    @Test func exactlyThreeSecondsPlays() {
        #expect(ReplayRules.refusal(for: last, given: ok(held: 3.0)) == nil)
        #expect(ReplayRules.refusal(for: last, given: ok(held: 2.99)) == .notEnoughVideo)
    }

    @Test func clipPlaysInBackgroundOnly() {
        #expect(ReplayRules.refusal(for: clip, given: ok(mode: .backgroundOnly)) == nil)
    }

    @Test func messagesMatchSpec() {
        #expect(ReplayRefusal.noApp.message == "No app is using Moobility Cam")
        #expect(ReplayRefusal.recordSheetOpen.message == "Close the Record window first")
        #expect(ReplayRefusal.recentVideoOff.message == "Recent video is off")
        #expect(ReplayRefusal.backgroundOnly.message == "No recent video in Background only")
        #expect(ReplayRefusal.notEnoughVideo.message == "Not enough recent video yet")
        #expect(ReplayRefusal.badFile.message == "Can't play this clip")
        #expect(ReplayRefusal.clipTooLong.message == "Clip is longer than 5 minutes")
    }

    @Test func targetSavedForm() {
        for target in ReplayTarget.presets + [.clip(file: "Hello there.mov")] {
            #expect(ReplayTarget(stored: target.stored) == target)
        }
        for bad in ["last:45", "clip:", "clip:../x.mov", "clip:.x.mov", "", "foo"] {
            #expect(ReplayTarget(stored: bad) == nil)
        }
        #expect(ReplayTarget.default == .last(seconds: 60))
        #expect(ReplayTarget.presets == [15, 30, 60, 120, 300].map { .last(seconds: $0) })
    }

    @Test func titles() {
        #expect(ReplayTarget.last(seconds: 15).title == "Last 15 seconds")
        #expect(ReplayTarget.last(seconds: 60).title == "Last 1 minute")
        #expect(ReplayTarget.last(seconds: 120).title == "Last 2 minutes")
        #expect(ReplayTarget.last(seconds: 300).title == "Last 5 minutes")
        #expect(ReplayTarget.clip(file: "Hello.mov").title == "Hello")
    }

    @Test func holdsRecentVideoRules() {
        #expect(ReplayRules.holdsRecentVideo(hasClient: true, toggle: true, mode: .overBackground))
        #expect(ReplayRules.holdsRecentVideo(hasClient: true, toggle: true, mode: .plainCamera))
        #expect(!ReplayRules.holdsRecentVideo(hasClient: true, toggle: true, mode: .backgroundOnly))
        #expect(!ReplayRules.holdsRecentVideo(hasClient: true, toggle: false, mode: .overBackground))
        #expect(!ReplayRules.holdsRecentVideo(hasClient: false, toggle: true, mode: .overBackground))
    }
}

@Suite struct ReplayMachineTests {
    private let a = ReplayTarget.clip(file: "a.mov")
    private let b = ReplayTarget.clip(file: "b.mov")

    private func playing(_ target: ReplayTarget) -> ReplayMachine {
        var m = ReplayMachine()
        let id = m.begin(target)
        let r1 = m.loadFinished(requestID: id)
        #expect(r1)
        return m
    }

    @Test func startsIdle() {
        let m = ReplayMachine()
        #expect(m.state == .idle)
        #expect(!m.isActive)
        #expect(!m.isOutputReplay)
    }

    @Test func secondPressDuringLoadingGoesIdle() {
        var m = ReplayMachine()
        _ = m.begin(a)
        #expect(m.isActive)
        #expect(!m.isOutputReplay)
        let r2 = m.end(.goLive)
        #expect(r2 == false)
        #expect(m.state == .idle)
    }

    @Test func staleLoadIsIgnored() {
        var m = ReplayMachine()
        let id = m.begin(a)
        _ = m.end(.goLive)
        let r3 = m.loadFinished(requestID: id)
        #expect(r3 == false)
        #expect(m.state == .idle)
    }

    @Test func newBeginReplacesLoad() {
        var m = ReplayMachine()
        let first = m.begin(a)
        let second = m.begin(b)
        let r4 = m.loadFinished(requestID: first)
        #expect(r4 == false)
        if case .loading(let id, let target, _) = m.state {
            #expect(id == second)
            #expect(target == b)
        } else {
            Issue.record("expected loading, got \(m.state)")
        }
        let r5 = m.loadFinished(requestID: second)
        #expect(r5)
        #expect(m.state == .playing(target: b))
    }

    @Test func switchWhilePlayingKeepsOutput() {
        var m = playing(a)
        let id = m.begin(b)
        #expect(m.state == .loading(requestID: id, target: b, replacing: a))
        #expect(m.isOutputReplay)
        let r6 = m.loadFinished(requestID: id)
        #expect(r6)
        #expect(m.state == .playing(target: b))

        var n = playing(a)
        let failing = n.begin(b)
        let r7 = n.loadFailed(requestID: failing)
        #expect(r7)
        #expect(n.state == .playing(target: a))
    }

    @Test func switchOfSwitchKeepsTheOneStillPlaying() {
        var m = playing(a)
        _ = m.begin(b)
        let id = m.begin(.clip(file: "c.mov"))
        #expect(m.state == .loading(requestID: id, target: .clip(file: "c.mov"), replacing: a))
    }

    @Test func goLiveDuringSwitchFades() {
        var m = playing(a)
        let id = m.begin(b)
        let r8 = m.end(.goLive)
        #expect(r8)
        #expect(m.state == .idle)
        let r9 = m.loadFinished(requestID: id)
        #expect(r9 == false)
    }

    @Test func eachCauseCancelsLoading() {
        for reason in [ReplayEnd.goLive, .modeChanged, .sourceChanged, .clientLost, .sinkFailed] {
            var m = ReplayMachine()
            _ = m.begin(a)
            let r10 = m.end(reason)
            #expect(r10 == false)
            #expect(m.state == .idle)
        }
    }

    @Test func fadeOnlyForChosenEnds() {
        for (reason, fades) in [(ReplayEnd.goLive, true), (.modeChanged, true), (.sourceChanged, true),
                                (.clientLost, false), (.sinkFailed, false)] {
            var m = playing(a)
            let r11 = m.end(reason)
            #expect(r11 == fades)
            #expect(m.state == .idle)
        }
    }

    @Test func endWhenIdleDoesNothing() {
        var m = ReplayMachine()
        let r12 = m.end(.goLive)
        #expect(r12 == false)
        #expect(m.state == .idle)
    }

    @Test func deletingLoadingClipCancels() {
        var m = ReplayMachine()
        let id = m.begin(a)
        m.clipRemoved(file: "a.mov")
        #expect(m.state == .idle)
        let r13 = m.loadFinished(requestID: id)
        #expect(r13 == false)

        var other = ReplayMachine()
        let otherID = other.begin(b)
        other.clipRemoved(file: "a.mov")
        #expect(other.state == .loading(requestID: otherID, target: b, replacing: nil))

        var play = playing(a)
        play.clipRemoved(file: "a.mov")
        #expect(play.state == .playing(target: a))

        var both = playing(.clip(file: "x.mov"))
        _ = both.begin(a)
        both.clipRemoved(file: "a.mov")
        #expect(both.state == .playing(target: .clip(file: "x.mov")))
    }

    @Test func renamedPlayingClipKeepsPlayingUnderItsNewName() {
        var m = playing(a)
        m.clipRenamed(from: "a.mov", to: "z.mov")
        #expect(m.state == .playing(target: .clip(file: "z.mov")))
        m.clipRenamed(from: "b.mov", to: "y.mov")
        #expect(m.state == .playing(target: .clip(file: "z.mov")))
    }

    @Test func renameFollowsLoadingAndReplaced() {
        var m = playing(a)
        let id = m.begin(b)
        m.clipRenamed(from: "b.mov", to: "z.mov")
        #expect(m.state == .loading(requestID: id, target: .clip(file: "z.mov"), replacing: a))
        m.clipRenamed(from: "a.mov", to: "y.mov")
        #expect(m.state == .loading(requestID: id, target: .clip(file: "z.mov"), replacing: .clip(file: "y.mov")))
        m.clipRemoved(file: "z.mov")
        #expect(m.state == .playing(target: .clip(file: "y.mov")))
    }

    @Test func loadFailedOnlyForCurrent() {
        var m = ReplayMachine()
        let first = m.begin(a)
        let second = m.begin(b)
        let r14 = m.loadFailed(requestID: first)
        #expect(r14 == false)
        #expect(m.state == .loading(requestID: second, target: b, replacing: nil))
        let r15 = m.loadFailed(requestID: second)
        #expect(r15)
        #expect(m.state == .idle)
    }
}
