import Foundation
import Testing
@testable import MoobilityCore

@Suite struct CaptureGateTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func gateStartsImmediately() {
        var gate = CaptureGate()
        #expect(gate.update(clientCount: 1, at: t0) == true)
    }

    @Test func gateIdleWithNoClients() {
        var gate = CaptureGate()
        #expect(gate.update(clientCount: 0, at: t0) == false)
    }

    @Test func gateIgnoresFlapping() {
        var gate = CaptureGate()
        #expect(gate.update(clientCount: 1, at: t0) == true)
        #expect(gate.update(clientCount: 0, at: t0 + 0.5) == true)
        #expect(gate.update(clientCount: 1, at: t0 + 1.0) == true)
        #expect(gate.update(clientCount: 0, at: t0 + 1.5) == true)
        #expect(gate.update(clientCount: 0, at: t0 + 3.4) == true)   // zero only since 1.5
        #expect(gate.update(clientCount: 0, at: t0 + 3.5) == false)
    }

    @Test func gateStopsAfterDelay() {
        var gate = CaptureGate()
        #expect(gate.update(clientCount: 1, at: t0 - 1) == true)
        #expect(gate.update(clientCount: 0, at: t0) == true)
        #expect(gate.update(clientCount: 0, at: t0 + 1.9) == true)
        #expect(gate.update(clientCount: 0, at: t0 + 2.0) == false)
    }
}

@Suite struct SinkHealthTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func healthFailsAfterOneSecondFull() {
        var health = SinkHealth()
        #expect(health.record(queueFull: true, at: t0) == false)
        #expect(health.record(queueFull: true, at: t0 + 0.99) == false)
        #expect(health.record(queueFull: true, at: t0 + 1.0) == true)
    }

    @Test func healthResetsOnDrain() {
        var health = SinkHealth()
        #expect(health.record(queueFull: true, at: t0) == false)
        #expect(health.record(queueFull: false, at: t0 + 0.5) == false)
        #expect(health.record(queueFull: true, at: t0 + 0.6) == false)
        #expect(health.record(queueFull: true, at: t0 + 1.5) == false)
    }

    @Test func resetClearsFullStreak() {
        var health = SinkHealth()
        _ = health.record(queueFull: true, at: t0)
        health.reset()
        #expect(health.record(queueFull: true, at: t0 + 1.2) == false)
    }
}
