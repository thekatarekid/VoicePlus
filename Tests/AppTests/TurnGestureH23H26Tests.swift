import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H26 — VoicePlus's own windows skip the window-identity check; no text field → Notes for native
/// apps and our own windows only (Electron keeps N3: delivered). H23-core — Escape after words
/// keeps the partial words for Notes ("Cancelled · Saved to Notes"). Mock system, no live apps.
@Suite("Turn: own windows and no-field Notes (H26), Escape after words (H23)")
struct TurnGestureH23H26Tests {
    typealias T = TurnControllerTests

    static var ownApp: FocusSnapshot {
        FocusSnapshot(pid: OwnProcess.pid, bundleID: Bundle.main.bundleIdentifier ?? "com.voiceplus.app",
                      appName: "VoicePlus", elementToken: "own-1")
    }

    private func land(_ h: T.Harness, _ text: String = "hello there") async throws -> (TurnID, LandingResult) {
        let id = try #require(await h.holdToPreview(T.words(text)))
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
        return (id, try #require(h.events.landed.first))
    }

    @Test("native app, a button focused: nothing typed, saved to Notes · no text field")
    func nativeNoFieldToNotes() async throws {
        let h = T.Harness()
        h.system.field = MockSystemAccess.Field(role: "AXButton", value: "")
        let (id, _) = try await land(h)
        #expect(h.system.postCount == 0)
        #expect(h.focusGuard.heldText(turn: id)?.reason == DeliveryReason.noDestination, "kept for Notes, no text field")
        #expect(h.store.entry(id)?.record.writeAttempted == false)
        #expect(NoteReason.forHeld(reason: DeliveryReason.noDestination) == .noTextField)
    }

    @Test("Electron app, a button focused: still delivered (N3 kept)")
    func electronNoFieldDelivered() async throws {
        let h = T.Harness()
        h.system.field = MockSystemAccess.Field(role: "AXButton", value: "")
        h.system.runtimeByPID[T.textEdit.pid] = .electron
        let (id, _) = try await land(h)
        #expect(h.focusGuard.heldText(turn: id) == nil)
        #expect(h.system.postCount > 0, "web/Electron content is written unverified")
    }

    @Test("native app, an unfamiliar role (custom view): not treated as no field")
    func unknownRoleNotNotes() async throws {
        let h = T.Harness()
        h.system.field = MockSystemAccess.Field(role: "AXGroup", value: "")
        let (id, _) = try await land(h)
        #expect(h.focusGuard.heldText(turn: id)?.reason != DeliveryReason.noDestination)
    }

    @Test("a text field focused: typed as before")
    func textFieldTyped() async throws {
        let h = T.Harness()
        let (id, _) = try await land(h)
        #expect(h.focusGuard.heldText(turn: id) == nil && h.system.postCount > 0)
        #expect(h.field.contains("hello there") || h.field.contains("Hello there"))
    }

    @Test("our own window with no text field: Notes, never keystrokes into our UI")
    func ownWindowNoField() async throws {
        let h = T.Harness()
        h.system.frontmost = Self.ownApp
        h.system.field = MockSystemAccess.Field(role: "AXButton", value: "")
        let (id, _) = try await land(h)
        #expect(h.system.postCount == 0)
        #expect(h.focusGuard.heldText(turn: id)?.reason == DeliveryReason.noDestination)
    }

    @Test("our own windows skip the window-identity check")
    func ownWindowSkipsIdentity() {
        let system = MockSystemAccess(frontmost: Self.ownApp)
        system.focusedWindow = "pill"
        let pullBack = SystemFocusPullBack(system: system) { _ in .raised }
        let anchor = pullBack.remember(Self.ownApp)
        system.focusedWindow = "settings"
        #expect(pullBack.windowState(anchor) == .unknown, "own windows: the in-process writer decides")

        let other = MockSystemAccess(frontmost: T.textEdit)
        other.focusedWindow = "w1"
        other.openWindows = ["w1"]
        let native = SystemFocusPullBack(system: other) { _ in .raised }
        let kept = native.remember(T.textEdit)
        other.focusedWindow = "w2"
        #expect(native.windowState(kept) == .changed, "other apps keep the window check")
    }

    @Test("H23 — Escape after words keeps the partial words for Notes")
    func escapeAfterWords() throws {
        let h = T.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.notePartial("half a thought")
        _ = h.controller.escape()
        let entry = try #require(h.store.entry(id))
        #expect(entry.stage == .cancelled)
        #expect(entry.record.finalText == "half a thought")
    }
}
