import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H3 (owner Q3.2) — a hold in any state starts a fresh dictation: a hint, outcome, error or edit
/// row still up gives way to the listening row, and the edit pill can no longer hijack the hold
/// (old H6 "ended at key-down"). Replays the shape of EE2E974B / 8A8B8406 (a row left up across
/// later presses) with mocks only.
@Suite("Turn gestures: a hold always wins (H3)")
struct TurnGestureHoldYieldTests {
    typealias H = TurnControllerTests.Harness
    final class Log: @unchecked Sendable { var value: [String] = [] }

    @Test("key-down yields whatever the notch shows, then presents .starting — in that order",
          arguments: [true, false])
    func yieldPrecedesStarting(latched: Bool) {
        let h = H()
        let log = Log()
        h.controller.onHoldYield = { log.value.append("yield") }
        let present = h.controller.onPresent
        h.controller.onPresent = { state in log.value.append(state.caseName); present?(state) }
        guard case .began = h.controller.keyDown(latched: latched) else { Issue.record("no turn"); return }
        #expect(log.value == ["yield", "starting"])
    }

    @Test("a repeat of the key already down yields nothing")
    func repeatDoesNotYield() {
        let h = H()
        let log = Log()
        guard case .began = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.onHoldYield = { log.value.append("yield") }
        guard case .repeated = h.controller.keyDown() else { Issue.record("not a repeat"); return }
        #expect(log.value.isEmpty)
    }

    @Test("tap to talk replaced the tap hint: a tap that starts nothing presents nothing afterwards")
    func tapSchedulesNoHint() {
        let h = H()
        let log = Log()
        h.controller.surfaceShowing = { false }
        guard case .began(let tap) = h.controller.keyDown() else { Issue.record("no tap"); return }
        let present = h.controller.onPresent
        h.controller.onPresent = { state in log.value.append(state.caseName); present?(state) }
        h.controller.captureTapped(tap)
        h.clock.advance(5)
        #expect(log.value.isEmpty, "no hint row is ever scheduled")
    }

    @MainActor
    @Test("hint, X08 error, outcome and cancelled rows are replaced by the hold's .starting row",
          arguments: [PillState.preview(text: "Saved to Notes · no text field"),
                      .error(message: RecoveryCatalog.entry(.X08).headline),
                      .cancelled, .undoAvailable])
    func rowsGiveWay(row: PillState) {
        let pill = PillViewModel()
        pill.present(row)
        #expect(pill.state == row)
        pill.present(.starting)
        #expect(pill.state == .starting)
        // A stale retraction (the old row's timer) never takes the new turn's row down.
        pill.retractDelivery()
        #expect(pill.state == .starting)
    }

    @MainActor
    @Test("the edit pill stands down at key-down: no warm tick redraws it over the listening row")
    func editPillYields() {
        let h = H()
        let pill = PillViewModel()
        let driver = TransformPillDriver(pill: pill)
        driver.handle(.prompt("Say the new text"))
        guard case .transform = pill.state else { Issue.record("edit row not shown"); return }
        #expect(driver.reducer.needsTicks)

        let wiring = TurnWiring(controller: h.controller, store: h.store, escape: EscapeHotkey())
        wiring.onTransformYield = { driver.handle(.ended) }
        h.controller.onHoldYield = { wiring.yieldToHold() }
        h.controller.onPresent = { pill.present($0) }
        guard case .began = h.controller.keyDown() else { Issue.record("no turn"); return }

        #expect(pill.state == .starting)
        #expect(!driver.reducer.needsTicks, "no warm window, no closing notice left to tick")
        #expect(pill.ghost == nil && pill.morph == nil)
        driver.tick()
        #expect(pill.state == .starting, "a tick after the yield never re-presents the edit row")
    }

}
