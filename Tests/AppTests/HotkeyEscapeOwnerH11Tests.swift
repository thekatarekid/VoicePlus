import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H11 (old H8) — one Escape owner for the turn and the edit pill: the system key is registered at
/// most once (Carbon would refuse a second with -9878), the surface on top gets the press, and the
/// turn gets Escape back when the edit preview ends. Stub backend; no real hot key.
@Suite("H11 — one Escape owner")
struct HotkeyEscapeOwnerH11Tests {
    /// Fails a second concurrent install the way Carbon does (-9878).
    final class OneKey {
        var live: Set<Int> = []
        var refusals = 0
        var maxLive = 0
        var backend: EscapeKeyBackend {
            EscapeKeyBackend { token in
                guard self.live.isEmpty else { self.refusals += 1; return nil }
                self.live.insert(token)
                self.maxLive = max(self.maxLive, self.live.count)
                return InstalledHotkeySource(setEnabled: { _ in }, invalidate: { self.live.remove(token) })
            }
        }
    }

    final class Fired { var turn = 0; var edit = 0 }

    private func pair() -> (EscapeHotkey, EscapeHotkey, OneKey, Fired) {
        let key = OneKey()
        let owner = EscapeOwnership()
        let turn = EscapeHotkey(backend: key.backend, ownership: owner)
        let edit = EscapeHotkey(backend: key.backend, ownership: owner)
        let fired = Fired()
        turn.onEscape = { _ in fired.turn += 1 }
        edit.onEscape = { _ in fired.edit += 1 }
        return (turn, edit, key, fired)
    }

    @Test("turn live, then the edit preview claims Escape: one registration, no -9878, Esc cancels the edit")
    func editOnTop() {
        let (turn, edit, key, fired) = pair()
        turn.update(phase: .beforeWrite, turn: TurnID())
        #expect(turn.isRegistered)
        edit.update(phase: .beforeWrite)
        #expect(edit.isRegistered && !turn.isRegistered)
        #expect(turn.isWaitingForEscape)
        #expect(key.refusals == 0 && key.maxLive == 1)
        turn.press(); edit.press()
        #expect(fired.edit == 1 && fired.turn == 0, "Esc cancels the edit preview")
    }

    @Test("the edit preview ends: the turn holds Escape again and its press works")
    func handBack() {
        let (turn, edit, key, fired) = pair()
        turn.update(phase: .beforeWrite, turn: TurnID())
        edit.update(phase: .beforeWrite)
        edit.update(phase: .none)
        #expect(turn.isRegistered && !edit.isRegistered)
        #expect(key.live.count == 1 && key.refusals == 0)
        turn.press()
        #expect(fired.turn == 1)
    }

    @Test("nobody wants it: nothing registered (Escape belongs to the frontmost app)")
    func idleReleases() {
        let (turn, edit, key, _) = pair()
        turn.update(phase: .beforeWrite, turn: TurnID())
        edit.update(phase: .beforeWrite)
        turn.update(phase: .none)
        edit.update(phase: .none)
        #expect(key.live.isEmpty)
        #expect(!turn.isWaitingForEscape && !edit.isWaitingForEscape)
    }

    @Test("a menu over the turn takes Escape from whichever holds it, and gives it back")
    func menuOpen() {
        let (turn, edit, key, _) = pair()
        turn.update(phase: .beforeWrite, turn: TurnID())
        edit.update(phase: .beforeWrite)
        edit.setMenuOpen(true)
        #expect(turn.isRegistered, "the edit row's menu releases it to the turn underneath")
        turn.setMenuOpen(true)
        #expect(key.live.isEmpty)
        turn.setMenuOpen(false); edit.setMenuOpen(false)
        #expect(edit.isRegistered && key.maxLive == 1)
    }

    @Test("Carbon-backed controllers share the app's one owner; test backends get their own")
    func defaults() {
        #expect(EscapeHotkey().ownership === EscapeOwnership.shared)
        let stub = EscapeKeyBackend { _ in nil }
        #expect(EscapeHotkey(backend: stub).ownership !== EscapeOwnership.shared)
    }
}
