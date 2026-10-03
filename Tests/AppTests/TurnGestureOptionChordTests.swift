import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// X1 (owner round 4) — audio is buffered from key-down but the notch shows only after ~300 ms
/// with no other input; Option + key / click / scroll cancels the turn silently (no row, no hint,
/// no record). Mock clock and store; no live tap.
@Suite("Turn gestures: Option delay and silent chord cancel (X1)")
struct TurnGestureOptionChordTests {
    typealias H = TurnControllerTests.Harness
    final class Log: @unchecked Sendable { var value: [String] = [] }

    private func harness() -> (H, Log) {
        let h = H()
        let log = Log()
        h.controller.holdPresentDelay = TurnController.holdPresentDelayDefault
        h.controller.surfaceShowing = { false }
        h.controller.onHoldYield = { log.value.append("yield") }
        h.controller.onPresent = { log.value.append($0.caseName) }
        h.controller.onTapHint = { log.value.append("hint") }
        h.controller.onRetract = { log.value.append("retract") }
        return (h, log)
    }

    @Test("the live default is 300 ms")
    func defaultDelay() {
        #expect(TurnController.holdPresentDelayDefault == 0.300)
        #expect(H().controller.holdPresentDelay == 0, "tests and non-live wiring show at key-down")
    }

    @Test("nothing shows inside 300 ms; after it the notch yields and shows the turn's stage")
    func notchAfterDelay() {
        let (h, log) = harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(!h.controller.admitsEngineState(.listening(level: 0)), "engine rows held back too")
        h.clock.advance(0.29)
        #expect(log.value.isEmpty)
        h.clock.advance(0.02)
        #expect(log.value == ["yield", "listening"])
        #expect(h.controller.admitsEngineState(.listening(level: 0)))
    }

    @Test("Option + key inside 300 ms: no notch ever, no hint, no record")
    func chordInsideDelay() {
        let (h, log) = harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.clock.advance(0.1)
        h.controller.captureAborted(id)
        h.clock.advance(3)
        #expect(!log.value.contains("starting"))
        #expect(!log.value.contains("listening"))
        #expect(!log.value.contains("hint"))
        #expect(!log.value.contains("yield"), "the hint or edit row in front is left alone")
        h.store.flush()
        #expect(h.store.entry(id) == nil)
    }

    @Test("a chord after the notch showed takes it down quietly — no hint, no record")
    func chordAfterDelay() {
        let (h, log) = harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.clock.advance(0.5)
        h.controller.captureAborted(id)
        h.clock.advance(3)
        #expect(log.value.contains("retract"))
        #expect(!log.value.contains("hint"))
        h.store.flush()
        #expect(h.store.entry(id) == nil)
    }

    @Test("a double tap (latch) shows at once")
    func latchShowsAtOnce() {
        let (h, log) = harness()
        guard case .began = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.clock.advance(0.08)
        h.controller.noteLatched(true)
        #expect(log.value == ["yield", "starting"])
        h.clock.advance(1)
        #expect(log.value == ["yield", "starting"], "the delay timer does not show it twice")
    }

    @Test("a tap inside the delay never flashes the notch; its hint still comes")
    func tapNeverFlashes() {
        let (h, log) = harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.clock.advance(0.1)
        h.controller.captureTapped(id)
        h.clock.advance(h.controller.tapHintDelay + 0.01)
        #expect(!log.value.contains("starting"))
        #expect(log.value.contains("hint"))
    }
}
