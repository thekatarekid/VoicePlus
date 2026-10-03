import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H28 (Q8, old H10+H13) — during hands-free the pill stays out; a piece that landed is a brief
/// status-line swap on the hands-free row (the ribbon still flies, because the state is still
/// `.landed`), held/error outcomes keep their own rows, and the chin does not reset between pieces.
@Suite("H28 — hands-free pieces on the pill and the chin")
struct PresenceHandsFreePieceTests {
    static let t0 = Date(timeIntervalSince1970: 90_000)

    private func latchedModel() -> (PillViewModel, () -> Void) {
        let model = PillViewModel()
        var clock = Self.t0
        model.now = { clock }
        model.latched = true
        model.present(.latched(elapsed: 3))
        model.apply(.listening(level: 0.3))
        return (model, { clock = clock.addingTimeInterval(0.7) })
    }

    @Test func aLandedPieceIsAStatusLineSwapOnTheHandsFreeRow() {
        let (model, advance) = latchedModel()
        let latchedFace = model.content()
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Piece one.", destination: "Claude")
        // Still `.landed` underneath: the tape flight (ribbon) keys off this state.
        #expect(model.state.caseName == "landed")
        let face = model.content()
        #expect(face.designKey == latchedFace.designKey, "the hands-free row stays; no segment row drawn over it")
        #expect(face.status.contains("Claude"), "status line reads Inserted in <App>: \(face.status)")
        #expect(face.status != latchedFace.status)
        #expect(face.buttons == latchedFace.buttons)
        // Same surface → the pill never resizes and never orders out between pieces.
        #expect(PillPanelController.surface(for: face) == PillPanelController.surface(for: latchedFace))
        // The timer keeps counting under the swap.
        model.present(.latched(elapsed: 4))
        #expect(model.content().trailing == .timer(4))
        // The dwell ends: back to "Hands-free".
        advance()
        model.retractDelivery()
        #expect(model.state == .latched(elapsed: 4))
        #expect(model.content().status == latchedFace.status)
    }

    @Test func heldAndFailedPiecesKeepTheirOwnRows() {
        let (model, _) = latchedModel()
        model.present(delivery: .held(reason: "destination changed"), text: "Piece one.", destination: "Mail")
        #expect(model.state.caseName == "held")
        #expect(model.content().designKey != "latched", "a held piece is never swallowed")
    }

    @Test func outsideHandsFreeTheLandedRowIsUnchanged() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Hello.", destination: "Claude")
        #expect(model.content().designKey == "inserted")
    }

    @MainActor @Test func theChinDoesNotResetBetweenPiecesButDoesWhenTheSessionEnds() async {
        let presence = PresenceIndicatorController()
        presence.setHandsFreeActive(true)
        presence.setEngine(.previewing(text: "piece"))
        presence.noteTurnEnded(.landed)
        #expect(presence.currentInputs.engine == .previewing(text: "piece"), "a piece end is not a reset")
        presence.setHandsFreeActive(false)
        #expect(presence.currentInputs.engine == .idle, "the session end applies the held-back reset")
    }

    @MainActor @Test func withoutHandsFreeATurnEndStillResets() async {
        let presence = PresenceIndicatorController()
        presence.setEngine(.previewing(text: "hi"))
        presence.noteTurnEnded(.landed)
        #expect(presence.currentInputs.engine == .idle)
    }
}
