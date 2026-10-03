import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H29 (old H11) — the hands-free end line, and a re-press within 300 ms of the stopping tap folded
/// into the stop (no capture, so no K04). Pure machine + mock turn controller; no live tap.
@Suite("H29 — hands-free end summary and stop fold")
struct HandsFreeEndH29Tests {
    typealias T = TurnControllerTests

    // MARK: Stop fold (HotkeyStateMachine)

    /// Double tap → latched; the stop press goes down at `stopDown` and up 80 ms later.
    private func latchedThenStopped(stopDown: TimeInterval = 5) -> HotkeyStateMachine {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.08)
        m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.28) == [.enterLatch])
        #expect(m.keyDown(at: stopDown) == [])
        #expect(m.keyUp(at: stopDown + 0.08) == [.finalize])
        #expect(m.lastGesture == .latchStop)
        return m
    }

    @Test("a re-press within 300 ms of the stopping tap does nothing (no capture → no K04)")
    func quickRePressFolds() {
        var m = latchedThenStopped()
        #expect(m.keyDown(at: 5.08 + 0.15) == [], "no startCapture")
        #expect(m.phase == .folded)
        #expect(m.keyUp(at: 5.08 + 0.25) == [], "its key-up does nothing either")
        #expect(m.phase == .idle)
        #expect(m.lastGesture == .folded)
        // The next press after that is an ordinary one.
        #expect(m.keyDown(at: 7) == [.startCapture])
    }

    @Test("a folded re-press held long still does nothing; a double-tap habit never re-latches")
    func foldedHoldAndDoubleTap() {
        var m = latchedThenStopped()
        m.keyDown(at: 5.2)
        #expect(m.keyUp(at: 6.5) == [], "a fold is the whole press")
        var n = latchedThenStopped()
        n.keyDown(at: 5.15); n.keyUp(at: 5.2)
        #expect(n.keyDown(at: 5.3) == [.startCapture], "the fold does not arm a double tap")
        #expect(n.keyUp(at: 5.35) == [.cancelCapture])
    }

    @Test("a press after the 300 ms window starts a dictation as usual")
    func laterPressStarts() {
        var m = latchedThenStopped()
        #expect(m.keyDown(at: 5.08 + 0.35) == [.startCapture])
    }

    @Test("only a hands-free stop arms the fold — a hold's key-up does not")
    func holdDoesNotArm() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0)
        #expect(m.keyUp(at: 1) == [.finalize])
        #expect(m.keyDown(at: 1.1) == [.startCapture])
    }

    @Test("the service folds too: stop + quick re-press emits nothing after the finalize")
    func serviceFolds() {
        let d = UserDefaults(suiteName: "AppTests.h29.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.secureInputProbe = { .off }
        final class Box { var actions: [HotkeyStateMachine.Action] = [] }
        let box = Box()
        s.onAction = { box.actions.append($0) }
        let alt = HotkeyBinding.Kind.option.flagMask | HotkeyBinding.Kind.deviceLeftAltMask
        for (t, down) in [(0.0, true), (0.08, false), (0.2, true), (0.28, false), (4.0, true), (4.08, false),
                          (4.2, true), (4.3, false)] {
            s.handle(keyCode: 58, flags: down ? alt : 0, timestamp: t)
        }
        #expect(box.actions == [.startCapture, .cancelCapture, .startCapture, .enterLatch, .finalize])
    }

    // MARK: Tally

    @Test("tally: one app → named; several → not; nothing → no line")
    func tally() {
        var t = HandsFreeTally()
        #expect(t.outcome == nil)
        t.noteInserted(app: "Claude"); t.noteInserted(app: "Claude")
        t.note(.init(stage: .landed, app: "Claude"))
        #expect(t.outcome?.pillLine == "Hands-free ended · 3 inserted in Claude")
        t.noteSavedToNotes()
        #expect(t.outcome?.pillLine == "Hands-free ended · 3 inserted in Claude · 1 saved to Notes")
        t.noteInserted(app: "Mail")
        #expect(t.outcome?.pillLine == "Hands-free ended · 4 inserted · 1 saved to Notes")
        #expect(!HandsFreeTally.LastPiece(stage: .cancelled, app: nil).endsWithSummary)
        #expect(!HandsFreeTally.LastPiece(stage: .failed, app: nil).endsWithSummary)
    }

    // MARK: Summary on the turn controller

    private final class Shown: @unchecked Sendable {
        let lock = NSLock()
        var outcomes: [TurnOutcome] = []
        func add(_ o: TurnOutcome) { lock.withLock { outcomes.append(o) } }
        var all: [TurnOutcome] { lock.withLock { outcomes } }
    }

    private func latchedTurn(_ h: T.Harness) -> TurnID? {
        guard case .began(let id) = h.controller.keyDown() else { return nil }
        h.controller.captureOpened(id)
        h.controller.noteLatched(true)
        return h.controller.keyUp(id) ? id : nil
    }

    @Test("stop with a last piece: its row first, then 'Hands-free ended · 3 inserted in TextEdit'")
    func summaryAfterLastPiece() async throws {
        let h = T.Harness()
        let shown = Shown()
        var earlier = HandsFreeTally()
        earlier.noteInserted(app: "TextEdit"); earlier.noteInserted(app: "TextEdit")
        h.controller.handsFreeTally = { earlier }
        h.controller.onHandsFreeEnded = { shown.add($0) }
        let id = try #require(latchedTurn(h))
        await h.controller.finalize(id, spans: T.words("last piece"))
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(shown.all.isEmpty, "the piece's own row shows first")
        h.clock.advance(TurnController.handsFreeSummaryDelayDefault + 0.05)
        #expect(await h.wait { shown.all.count == 1 })
        #expect(shown.all.first?.pillLine == "Hands-free ended · 3 inserted in TextEdit")
    }

    @Test("an empty tail still ends with the summary of the pieces already typed")
    func summaryWithEmptyTail() async throws {
        let h = T.Harness()
        let shown = Shown()
        var earlier = HandsFreeTally()
        earlier.noteInserted(app: "Claude")
        h.controller.handsFreeTally = { earlier }
        h.controller.onHandsFreeEnded = { shown.add($0) }
        let id = try #require(latchedTurn(h))
        await h.controller.finalize(id, spans: [])
        h.clock.advance(1.1)
        #expect(shown.all.map(\.pillLine) == ["Hands-free ended · 1 inserted in Claude"])
        #expect(h.events.notices.isEmpty)
    }

    @Test("nothing typed or saved in the whole session: no summary line")
    func noSummaryWhenNothing() async throws {
        let h = T.Harness()
        let shown = Shown()
        h.controller.handsFreeTally = { HandsFreeTally() }
        h.controller.onHandsFreeEnded = { shown.add($0) }
        let id = try #require(latchedTurn(h))
        await h.controller.finalize(id, spans: [])
        h.clock.advance(1.1)
        #expect(shown.all.isEmpty)
    }

    @Test("Escape ends hands-free with its own row, not the summary; a hold never gets one")
    func noSummaryOnEscapeOrHold() async throws {
        let h = T.Harness()
        let shown = Shown()
        var earlier = HandsFreeTally()
        earlier.noteInserted(app: "Claude")
        h.controller.handsFreeTally = { earlier }
        h.controller.onHandsFreeEnded = { shown.add($0) }
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.noteLatched(true)
        h.controller.escape()
        h.clock.advance(1.1)
        #expect(shown.all.isEmpty)
        _ = try #require(await h.holdToPreview(T.words("a hold")))
        h.clock.advance(3)
        #expect(shown.all.isEmpty)
    }
}
