import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// N8 + owner decisions (2026-10-02): no preview dwell (typed as soon as the final text is ready,
/// one pre-write check, timed in `stage_ms`), and on an app switch mid-dictation PULL BACK to the
/// key-down window — holding (Insert / Copy) only when the window is gone, the field is now a
/// password field, or the refocus check fails.
@Suite("Turn pull-back and no dwell (N8, owner decisions)")
struct TurnPullBackNoDwellTests {
    typealias H = TurnControllerTests.Harness
    static let textEdit = TurnControllerTests.textEdit
    static let mail = TurnControllerTests.mail
    static func words(_ t: String) -> [TranscriptSpan] { TurnControllerTests.words(t) }

    final class Raises: @unchecked Sendable { var count = 0 }

    /// A pull-back over the mock: raising puts TextEdit and window w1 back in front (unless `works`
    /// is off). Mail's window is w2; w1 stays open unless `closed`.
    static func pullBack(_ h: H, works: Bool = true, raises: Raises = Raises(), secureAfter: Bool = false) -> SystemFocusPullBack {
        let system = h.system
        let p = SystemFocusPullBack(system: system) { _ in
            raises.count += 1
            if works { system.frontmost = Self.textEdit; system.focusedWindow = "w1" }
            if secureAfter { system.field = .secure() }
            return .raised
        }
        p.settle = 0.05
        p.step = 0.005
        return p
    }

    /// Key down in TextEdit (window w1), then Mail (w2) takes focus before the final text is ready.
    static func switchToMail(_ h: H, closeW1: Bool = false) {
        h.system.frontmost = Self.mail
        h.system.focusedWindow = "w2"
        h.system.openWindows = closeW1 ? ["w2"] : ["w1", "w2"]
    }

    static func setUp(_ h: H, works: Bool = true, raises: Raises = Raises(), secureAfter: Bool = false) {
        h.system.focusedWindow = "w1"
        h.system.openWindows = ["w1"]
        h.controller.pullBack = pullBack(h, works: works, raises: raises, secureAfter: secureAfter)
    }

    static func run(_ h: H, between: () -> Void = {}) async -> TurnID? {
        guard case .began(let id) = h.controller.keyDown() else { return nil }
        h.controller.captureOpened(id)
        guard h.controller.keyUp(id) else { return nil }
        between()
        await h.controller.finalize(id, spans: words("hello there"))
        _ = await h.wait { h.events.landed.count == 1 }
        return id
    }

    // MARK: No dwell

    @Test("no dwell: typed as soon as the final text is ready — no rendered frame, no clock advance")
    func typesImmediately() async throws {
        let h = H(dwell: .immediate)
        let id = try #require(await Self.run(h))
        #expect(h.system.field.value.contains("hello there"))
        #expect(h.store.entry(id)?.stage == .landed)
        let stages = try #require(h.store.entry(id)?.resolvedExtras.stageMs)
        #expect(stages[TurnRecordExtras.Stage.preWriteCheck] != nil, "the one pre-write check is timed")
        #expect(stages[TurnRecordExtras.Stage.recognisedToTyped] != nil)
        #expect(stages[TurnRecordExtras.Stage.pullBack] == nil, "no pull-back when focus never moved")
    }

    @Test("no dwell: text or caret changes in the same field do not hold (those holds are Manual-only)",
          arguments: ["typed", "caret"])
    func noFalseHolds(_ change: String) async throws {
        let h = H(dwell: .immediate)
        let id = try #require(await Self.run(h) {
            if change == "typed" { h.system.field.value = TurnControllerTests.original + "x" }
            else { h.system.field.selection = 0..<0 }
        })
        #expect(h.store.entry(id)?.stage == .landed)
        #expect(h.system.field.value.contains("hello there"))
    }

    @Test("Manual review still waits for Insert and still holds when the field changed under it")
    func manualKeepsReviewHolds() async throws {
        let h = H(dwell: .manual)
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        _ = h.controller.keyUp(id)
        await h.controller.finalize(id, spans: Self.words("hello there"))
        h.controller.finalRendered(id)
        h.clock.advance(5)
        #expect(h.controller.stage(of: id) == .finalPreview, "manual never times out into a write")
        h.system.field.value = TurnControllerTests.original + "x"
        h.controller.insertNow()
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.system.postCount == 0)
    }

    @Test("settings: dictation types right away unless Manual review is on; legacy timed values no longer delay")
    func landingDwellSetting() {
        let store = InMemorySettingsStore()
        #expect(TurnSettings.landingDwell(store) == .immediate)
        for raw in ["600", "900", "1500", "bogus"] {
            store.set(raw, for: SettingsKeys.previewDwell)
            #expect(TurnSettings.landingDwell(store) == .immediate)
        }
        TurnSettings.setPreviewDwell(.manual, store: store)
        #expect(TurnSettings.landingDwell(store) == .manual)
        #expect(PreviewDwell.immediate.seconds == 0)
    }

    // MARK: Pull back

    @Test("app switched mid-dictation: pulled back to the key-down app and window, then typed there")
    func pullsBackAndTypes() async throws {
        let h = H(dwell: .immediate)
        let raises = Raises()
        Self.setUp(h, raises: raises)
        let id = try #require(await Self.run(h) { Self.switchToMail(h) })
        #expect(raises.count == 1)
        #expect(h.system.frontmost == Self.textEdit)
        #expect(h.store.entry(id)?.stage == .landed)
        #expect(h.system.field.value.contains("hello there"))
        #expect(h.focusGuard.heldText(turn: id) == nil)
        #expect(RecoveryCatalog.entry(for: .held(reason: PullBackReason.windowGone))?.id == .D01)
        #expect(RecoveryCatalog.entry(for: .held(reason: PullBackReason.refocusFailed))?.id == .D01)
        let stages = try #require(h.store.entry(id)?.resolvedExtras.stageMs)
        #expect(stages[TurnRecordExtras.Stage.pullBack] != nil, "the pull-back is timed")
    }

    @Test("another window of the same app took focus: pulled back to the key-down window")
    func pullsBackWindow() async throws {
        let h = H(dwell: .immediate)
        let raises = Raises()
        Self.setUp(h, raises: raises)
        let id = try #require(await Self.run(h) {
            h.system.focusedWindow = "w3"
            h.system.openWindows = ["w1", "w3"]
        })
        #expect(raises.count == 1)
        #expect(h.store.entry(id)?.stage == .landed)
    }

    @Test("the key-down window was closed: held (Insert / Copy), nothing typed, no raise")
    func windowGoneHolds() async throws {
        let h = H(dwell: .immediate)
        let raises = Raises()
        Self.setUp(h, raises: raises)
        let id = try #require(await Self.run(h) { Self.switchToMail(h, closeW1: true) })
        #expect(raises.count == 0)
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.events.landed.first?.delivery == .held(reason: PullBackReason.windowGone))
        #expect(h.focusGuard.heldText(turn: id) != nil)
        #expect(h.system.postCount == 0)
    }

    @Test("the refocus check fails (focus never comes back): held, nothing typed")
    func refocusFailsHolds() async throws {
        let h = H(dwell: .immediate)
        Self.setUp(h, works: false)
        let id = try #require(await Self.run(h) { Self.switchToMail(h) })
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.events.landed.first?.delivery == .held(reason: PullBackReason.refocusFailed))
        #expect(h.system.postCount == 0)
    }

    @Test("pulled back, but the target is now a password field: held, never typed")
    func passwordAfterPullBackHolds() async throws {
        let h = H(dwell: .immediate)
        Self.setUp(h, secureAfter: true)
        let id = try #require(await Self.run(h) { Self.switchToMail(h) })
        #expect(h.store.entry(id)?.stage == .held)
        // Held under D01 (as every pre-write refusal reads); the focus guard keeps the reason.
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.destinationChanged))
        #expect(h.focusGuard.heldText(turn: id) != nil)
        #expect(h.system.postCount == 0)
    }

    @Test("no pull-back wired: an app switch holds as before (destination changed)")
    func noPullBackHolds() async throws {
        let h = H(dwell: .immediate)
        let id = try #require(await Self.run(h) { h.system.frontmost = Self.mail })
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.destinationChanged))
    }

    @Test("SystemFocusPullBack: window state from window tokens")
    func windowStates() {
        let mock = MockSystemAccess(frontmost: Self.textEdit)
        mock.focusedWindow = "w1"
        let p = SystemFocusPullBack(system: mock) { _ in .raised }
        let anchor = p.remember(Self.textEdit)
        #expect(anchor.windowToken == "w1")
        #expect(p.windowState(anchor) == .same)
        mock.focusedWindow = "w2"; mock.openWindows = ["w1", "w2"]
        #expect(p.windowState(anchor) == .changed)
        mock.openWindows = ["w2"]
        #expect(p.windowState(anchor) == .gone)
        #expect(p.pullBack(anchor) == .windowGone)
        let noToken = PullBackAnchor(focus: Self.textEdit, windowToken: nil)
        #expect(p.windowState(noToken) == .unknown)
        let gone = SystemFocusPullBack(system: mock) { _ in .appGone }
        #expect(gone.pullBack(noToken) == .windowGone)
    }
}
