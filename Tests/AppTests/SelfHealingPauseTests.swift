import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q8 — self-healing pauses: rebuilt from live state at present and every 100 ms while paused;
/// a cause-less pause is dropped after 2 s; focus is keyboard-only and cleared each turn.
/// Real AppKit key-window / first-responder state is not exercised (probe seam only).
@Suite("Self-healing dwell pauses (V5 Q8)")
struct SelfHealingPauseTests {
    final class Live: @unchecked Sendable {
        var state = PauseLiveState()
    }

    // MARK: Pure rule

    @Test func liveCausesApplyAndCauselessPausesDropAfterTwoSeconds() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var set = PauseSet()
        set.rebuild(from: PauseLiveState(pointerInside: true, keyboardFocus: true), now: t0)
        #expect(set.reasons == [.hover, .focus])
        // The pointer leaves; focus stays live.
        #expect(set.rebuild(from: PauseLiveState(keyboardFocus: true), now: t0.addingTimeInterval(1)).isEmpty)
        #expect(set.reasons == [.hover, .focus])
        #expect(set.rebuild(from: PauseLiveState(keyboardFocus: true), now: t0.addingTimeInterval(3.05)) == [.hover])
        #expect(set.reasons == [.focus])
    }

    @Test func aCauseReturningWithinGraceResetsTheClock() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var set = PauseSet(reasons: [.hover])
        set.rebuild(from: PauseLiveState(), now: t0)
        set.rebuild(from: PauseLiveState(pointerInside: true), now: t0.addingTimeInterval(1.5))
        #expect(set.rebuild(from: PauseLiveState(), now: t0.addingTimeInterval(3)).isEmpty)
        #expect(set.reasons == [.hover])
    }

    @Test func reviewIsAnIntentNeverDropped() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var set = PauseSet(reasons: [.review])
        #expect(set.rebuild(from: PauseLiveState(), now: t0).isEmpty)
        #expect(set.rebuild(from: PauseLiveState(), now: t0.addingTimeInterval(60)).isEmpty)
        #expect(set.reasons == [.review])
    }

    // MARK: Controller

    @Test("cause-less pause drops within 2 s and the dwell fires")
    func causelessPauseDrops() async throws {
        let h = TurnControllerTests.Harness()
        let live = Live()
        h.controller.liveState = { live.state }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        // A stale focus pause nothing will ever resume (the V4.41 failure shape).
        h.controller.pauseDwell(.focus)
        h.clock.advance(1.9)
        #expect(h.system.postCount == 0)
        h.clock.advance(0.3 + 0.7)   // > 2 s cause-less, then the 0.6 s dwell
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("key press then pointer leaves → dwell fires")
    func keyPressThenPointerLeaves() async throws {
        let h = TurnControllerTests.Harness()
        let live = Live()
        live.state = PauseLiveState(pointerInside: true)
        h.controller.liveState = { live.state }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        h.controller.rebuildPauses()
        // Hovering, the user presses a key: the old code turned the mouse focus into keyboard focus.
        h.controller.pauseDwell(.focus)
        h.clock.advance(5)
        #expect(h.system.postCount == 0, "pointer still on the pill")
        live.state = PauseLiveState()          // pointer leaves; the window is not key
        h.controller.resumeDwell(.hover)
        h.clock.advance(2.2 + 0.7)
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("a live cause holds the pause indefinitely")
    func liveCauseHolds() async throws {
        let h = TurnControllerTests.Harness()
        let live = Live()
        live.state = PauseLiveState(editing: true)
        h.controller.liveState = { live.state }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        h.controller.rebuildPauses()
        h.clock.advance(10)
        #expect(h.system.postCount == 0)
        #expect(h.controller.previewInfo?.paused == true)
    }

    // MARK: Pill focus

    @MainActor
    @Test("focus from turn N doesn't pause N+1")
    func focusClearedEachTurn() {
        let pill = PillViewModel()
        pill.present(.finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0.6)))
        pill.setFocus(true, element: "pill.actions")       // Tab, pointer elsewhere
        #expect(pill.focusInside)
        pill.present(.starting)
        #expect(!pill.focusInside)
        #expect(!pill.isKeyboardFocusReallyInside)
    }

    @MainActor
    @Test func mouseAcquiredFocusIsNotKeyboardFocus() {
        let pill = PillViewModel()
        pill.setPointerInside(true)
        pill.setFocus(true, element: "draft.editor")       // a click, not a key event
        #expect(!pill.focusInside)
    }

    @MainActor
    @Test func keyboardFocusNeedsAKeyPillWindow() {
        let pill = PillViewModel()
        pill.setFocus(true, element: "pill.actions")
        pill.keyFocusProbe = { false }
        #expect(!pill.isKeyboardFocusReallyInside)
        pill.keyFocusProbe = { true }
        #expect(pill.isKeyboardFocusReallyInside)
        #expect(TurnWiring.liveState(of: pill).keyboardFocus)
    }
}
