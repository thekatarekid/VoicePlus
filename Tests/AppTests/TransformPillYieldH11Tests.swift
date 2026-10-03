import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H11 (pill side) + H3 — the edit pill and the turn share one Escape owner: while an edit runs or
/// is previewed the pill holds the single registration (no -9878) and Escape cancels the edit;
/// a new hold takes the notch back (`yieldToHold`): the edit is cancelled, Escape returns to the
/// turn, and the edit's late outcome never redraws over the listening row. Stub backend only.
@Suite("H11 — edit pill Escape and yield to a new hold")
@MainActor
struct TransformPillYieldH11Tests {
    typealias Box<T> = TransformPreviewGateTests.Box<T>
    static let original = TransformPreviewGateTests.original
    static let edited = TransformPreviewGateTests.edited
    static var diff: Pipeline.WordDiff { .compute(old: original, new: edited) }

    /// Refuses a second concurrent install the way Carbon does (-9878).
    final class OneKey {
        var live: Set<Int> = []
        var refusals = 0
        var backend: EscapeKeyBackend {
            EscapeKeyBackend { token in
                guard self.live.isEmpty else { self.refusals += 1; return nil }
                self.live.insert(token)
                return InstalledHotkeySource(setEnabled: { _ in }, invalidate: { self.live.remove(token) })
            }
        }
    }

    struct Rig {
        let driver: TransformPillDriver
        let pill: PillViewModel
        let turn: EscapeHotkey
        let edit: EscapeHotkey
        let key: OneKey
        let cancels: Box<Int>
        let turnPresses: Box<Int>
    }

    static func rig() -> Rig {
        let key = OneKey()
        let owner = EscapeOwnership()
        let turn = EscapeHotkey(backend: key.backend, ownership: owner)
        let edit = EscapeHotkey(backend: key.backend, ownership: owner)
        let pill = PillViewModel()
        let driver = TransformPillDriver(pill: pill)
        let cancels = Box(0), turnPresses = Box(0)
        driver.onCancel = { cancels.value += 1 }
        driver.escape = edit
        turn.onEscape = { _ in turnPresses.value += 1 }
        return Rig(driver: driver, pill: pill, turn: turn, edit: edit, key: key, cancels: cancels, turnPresses: turnPresses)
    }

    @Test("turn live + edit preview: one registration, no -9878, Esc cancels the edit once; the turn gets Escape back")
    func sharedOwner() {
        let r = Self.rig()
        r.turn.update(phase: .beforeWrite, turn: TurnID())
        r.driver.handle(.began(words: 4))
        r.driver.handle(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        #expect(r.edit.isRegistered && !r.turn.isRegistered)
        #expect(r.key.refusals == 0 && r.key.live.count == 1)
        r.turn.press(); r.edit.press()
        #expect(r.cancels.value == 1 && r.turnPresses.value == 0)
        r.driver.handle(.cancelled)
        #expect(r.turn.isRegistered && !r.edit.isRegistered && r.key.refusals == 0)
        r.turn.press()
        #expect(r.turnPresses.value == 1 && r.cancels.value == 1)
    }

    @Test("a new hold during the preview: the edit is cancelled, Escape returns to the turn, its late outcome is dropped")
    func yieldDuringPreview() {
        let r = Self.rig()
        r.turn.update(phase: .beforeWrite, turn: TurnID())
        r.driver.handle(.began(words: 4))
        r.driver.handle(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        r.driver.yieldToHold()
        #expect(r.cancels.value == 1, "the original stays")
        #expect(r.turn.isRegistered && !r.edit.isRegistered)
        #expect(r.driver.reducer.state == .hidden && !r.driver.reducer.needsTicks)
        // The landing reports the cancellation after the yield: not drawn over the listening row.
        r.driver.handle(.cancelled)
        #expect(r.driver.reducer.state == .hidden)
        if case .transform = r.pill.state { Issue.record("edit row redrawn over the new hold") }
        // The next edit shows as usual.
        r.driver.handle(.began(words: 2))
        #expect(r.driver.reducer.state == .transform(.init(editingWords: 2, stage: .editing)))
        #expect(!r.driver.yieldedEdit)
    }

    @Test("a new hold while the edit is still running drops its preview and failure")
    func yieldWhileRunning() {
        let r = Self.rig()
        r.driver.handle(.began(words: 4))
        r.driver.yieldToHold()
        #expect(r.cancels.value == 1)
        for late: TransformPillReducer.Event in [.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff),
                                                 .failed("no rewrite"), .noChange] {
            r.driver.handle(late)
            #expect(r.driver.reducer.state == .hidden, "\(late) dropped")
            #expect(!r.edit.isRegistered)
        }
    }

    @Test("a new hold over the warm row or a notice: no cancel (nothing in flight), the row just goes")
    func yieldWhenSettled() {
        let r = Self.rig()
        r.driver.handle(.began(words: 4))
        r.driver.handle(.applied(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        r.driver.yieldToHold()
        #expect(r.cancels.value == 0 && !r.driver.yieldedEdit)
        #expect(r.driver.reducer.state == .hidden && !r.driver.reducer.isWarm)
        r.driver.handle(.notice("Copied"))
        r.driver.yieldToHold()
        #expect(r.cancels.value == 0 && r.driver.reducer.state == .hidden)
    }

    @Test("end to end: a hold during the preview keeps the original and shows no cancelled row")
    func endToEnd() async {
        let r = Self.rig()
        let h = TransformPreviewGateTests.harness()
        let pending = Box<[TransformPillReducer.Event]>([])
        h.landing.onEvent = { e in pending.value.append(e) }
        r.driver.onCancel = { [landing = h.landing] in landing.cancelPreview() }
        h.landing.sleep = { _ in
            await MainActor.run {
                for e in pending.value { r.driver.handle(e) }
                pending.value.removeAll()
                if r.driver.reducer.isPreviewing { r.driver.yieldToHold() }
            }
        }
        let out = await TransformPreviewGateTests.instruct(h.landing)
        #expect(out == .transformed(.failed(.unavailable(reason: "cancelled"))))
        #expect(h.system.field.value == Self.original && h.system.postCount == 0)
        for e in pending.value { r.driver.handle(e) }
        #expect(r.driver.reducer.state == .hidden, "no 'cancelled' row over the listening notch")
        #expect(!r.edit.isRegistered)
    }
}
