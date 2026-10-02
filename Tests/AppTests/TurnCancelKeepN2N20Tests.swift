import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// N2 — Cancel after recognition means "don't type here": the text is kept (held, in history, with
/// Insert here / Copy) and never dropped; only Escape during capture discards. Pill buttons follow
/// the turn's real offer. N20 — the notch says Working until the write finishes or the text is held;
/// the held row names the app that took focus; a refused press says "Previous text still landing".
@Suite("N2 + N20: kept-not-typed cancel, honest presence and held copy")
struct TurnCancelKeepN2N20Tests {
    typealias H = TurnControllerTests.Harness
    static func words(_ text: String) -> [TranscriptSpan] { TurnControllerTests.words(text) }

    // MARK: N2 — Cancel after recognition keeps the text

    @Test("Cancel on the preview: nothing typed, the text is held for Insert here / Copy and recorded")
    func cancelPreviewKeeps() async throws {
        let h = H()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        let info = try #require(h.controller.previewInfo)
        h.controller.finalRendered(id)
        #expect(TurnWiring.route(.cancel, shown: .finalPreview(info), to: h.controller, finishLatch: nil))
        #expect(await h.wait { h.events.landed.count == 1 })
        h.clock.advance(5)
        #expect(h.system.postCount == 0, "Cancel = don't type here")
        #expect(h.field == TurnControllerTests.original)
        let result = try #require(h.events.landed.first)
        #expect(result.delivery == .held(reason: DeliveryReason.keptByUser))
        #expect(h.focusGuard.heldText(turn: id)?.text == info.text, "kept for Insert here / Copy")
        #expect(h.store.entry(id)?.stage == .held, "never .cancelled — the payload is not dropped")
        #expect(h.store.entry(id)?.record.finalText == info.text)
        #expect(!h.events.events.contains(.cancelCapture))
    }

    @Test("Escape after key-up with no live words: the late final pass is kept, not dropped")
    func escapeWhileFinishingKeepsFinalPass() async throws {
        let h = H()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        #expect(h.controller.escape() == nil, "nothing discarded")
        #expect(!h.events.events.contains(.cancelCapture), "the final pass must be allowed to finish")
        await h.controller.finalize(id, spans: Self.words("late words"))
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.system.postCount == 0)
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.keptByUser))
        #expect(h.focusGuard.heldText(turn: id)?.text.contains("late words") == true)
        #expect(h.store.entry(id)?.stage == .held)
    }

    @Test("Cancel while finishing with live words keeps those words (Use-available path), types nothing")
    func cancelFinishingKeepsLiveWords() async throws {
        let h = H()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.notePartial("hello from the")
        #expect(h.controller.keyUp(id))
        h.controller.cancelFinishing()
        #expect(await h.wait { h.events.landed.count == 1 })
        await h.controller.finalize(id, spans: Self.words("hello from the other side"))
        h.clock.advance(5)
        #expect(h.system.postCount == 0)
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.keptByUser))
        #expect(h.focusGuard.heldText(turn: id)?.text.contains("hello from the") == true)
        #expect(h.store.entry(id)?.stage == .held)
    }

    @Test("Escape during capture still discards")
    func escapeDuringCaptureDiscards() async throws {
        let h = H()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.notePartial("never mind")
        #expect(h.controller.escape() == .cancel)
        #expect(h.store.entry(id)?.stage == .cancelled)
        #expect(h.focusGuard.heldText(turn: id) == nil)
    }

    @Test("an emptied draft (Q12) is still discarded")
    func emptiedDraftDiscards() async throws {
        let h = H()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.controller.discardPreview()
        h.clock.advance(5)
        #expect(h.store.entry(id)?.stage == .cancelled)
        #expect(h.system.postCount == 0)
    }

    // MARK: N2 — pill buttons follow the turn's offer

    @Test("finishing row: no buttons until the turn raises an offer; withdrawn offer clears them")
    @MainActor
    func pillOfferFollowsTurn() {
        let model = PillViewModel()
        model.present(.finishing(elapsedWarning: true))
        #expect(model.content().buttons.isEmpty)
        model.setFinishingOffer(.cancel)
        #expect(model.content().buttons == [PillButton("Cancel", .cancel, primary: true)])
        model.setFinishingOffer(nil)
        #expect(model.content().buttons.isEmpty, "payload started: the offer is withdrawn")
    }

    @Test("kept-not-typed held row: saved-to-history copy with Insert here / Copy")
    func keptRowCopy() {
        let c = PillTurnContext(destination: "Notes")
        let row = PillContent.make(.held(HeldPillInfo(text: "hello", destination: "Notes", reason: DeliveryReason.keptByUser)),
                                   context: c)
        #expect(row.status == "Not typed · saved to history")
        #expect(row.buttons.contains(PillButton("Insert here", .insert, primary: true)))
        #expect(row.buttons.contains(PillButton("Copy text", .copy)))
    }

    // MARK: N20 — held row names the app that took focus

    @Test("an app switch during the preview: the held row names the app that took focus")
    func heldNamesFocusTaker() async throws {
        let h = H()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.controller.finalRendered(id)
        h.system.frontmost = TurnControllerTests.mail
        h.clock.advance(1.5)
        #expect(await h.wait { h.events.landed.count == 1 })
        let result = try #require(h.events.landed.first)
        #expect(DeliveryPillDriver.tookFocus(result) == "Mail")
        let state = PillDeliveryRouter.state(for: try #require(result.delivery), text: result.text,
                                             destination: "TextEdit", tookFocus: DeliveryPillDriver.tookFocus(result))
        let row = PillContent.make(state, context: PillTurnContext(destination: "TextEdit"))
        #expect(row.status == "⚠ Mail took focus · text held")
        #expect(row.helper == "Nothing was typed in Mail")
        #expect(!row.buttons.contains { $0.label.lowercased().contains("return") })
    }

    @Test("held row without a different focus-taker keeps the H0 copy")
    func heldWithoutFocusTaker() {
        let info = HeldPillInfo(text: "x", destination: "Mail", reason: DeliveryReason.destinationChanged, tookFocus: "Mail")
        #expect(info.tookFocus == nil)
        let row = PillContent.make(.held(info), context: PillTurnContext())
        #expect(row.status == PillDeck.heldStatus)
    }

    // MARK: N20 — refused press copy

    @Test("a refused press shows 'Previous text still landing'")
    func busyCopy() async throws {
        let h = H()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        #expect(h.controller.keyDown() == .busy(id))
        #expect(h.events.notices == [.K04])
        #expect(TurnWiring.noticeNote(for: RecoveryCatalog.entry(.K04)) == "Previous text still landing")
        #expect(TurnWiring.noticeNote(for: RecoveryCatalog.entry(.A06)) == nil)
    }

    // MARK: N20 — the notch stays on Working until the write finishes or the text is held

    @Test("presence gate: landed/idle read as Working between key-up and the turn's end")
    func presenceGateSequence() {
        let gate = PresenceTurnGate()
        #expect(gate.map(.landed) == .landed, "no turn controller: untouched")
        gate.turnsAttached = true
        #expect(gate.map(.listening(level: 0.3)) == .listening(level: 0.3))
        #expect(gate.map(.finishing) == .finishing)
        #expect(gate.map(.landed) == .finalizing, "recognised is not typed")
        #expect(gate.map(.idle) == .finalizing)
        gate.turnEnded()
        #expect(gate.map(.landed) == .landed)
        #expect(gate.map(.idle) == .idle)
        #expect(gate.map(.finalizing) == .finalizing)
        #expect(gate.map(.cancelled) == .cancelled)
        #expect(gate.map(.idle) == .idle, "a cancelled turn is over")
    }

    @Test("presence sequence over a real turn: Working until the write lands, then rest")
    func presenceOverTurn() async throws {
        let h = H()
        let gate = PresenceTurnGate()
        gate.turnsAttached = true
        let ended = TurnControllerTests.Box(false)
        let previous = h.controller.onTurnEnded
        h.controller.onTurnEnded = { id, stage in previous?(id, stage); gate.turnEnded(); ended.value = true }
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        _ = gate.map(.finishing)
        await h.controller.finalize(id, spans: Self.words("hello there"))
        #expect(gate.map(.landed) == .finalizing, "engine done, text not typed yet")
        #expect(!ended.value)
        h.controller.finalRendered(id)
        h.clock.advance(1.5)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(await h.wait { ended.value })
        #expect(h.system.postCount == 1)
        #expect(gate.map(.idle) == .idle, "rest only after the write")
    }
}
