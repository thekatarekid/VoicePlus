import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Records Escape registrations instead of taking Escape from the whole machine.
private final class FakeEscapeKey {
    private(set) var installed: [Int] = []
    private(set) var invalidated: [Int] = []
    var live: [Int] { installed.filter { !invalidated.contains($0) } }
    var backend: EscapeKeyBackend {
        EscapeKeyBackend { token in
            self.installed.append(token)
            return InstalledHotkeySource(setEnabled: { _ in }, invalidate: {
                if !self.invalidated.contains(token) { self.invalidated.append(token) }
            })
        }
    }
}

/// S12 — the controls around the transform preview (R1): the Settings dwell it uses, Escape that
/// keeps the original, hover that freezes the dwell — each only while nothing has been written.
@Suite("S12 — transform preview controls")
@MainActor
struct TransformPreviewControlsTests {
    typealias Box<T> = TransformPreviewGateTests.Box<T>
    static let original = TransformPreviewGateTests.original
    static let edited = TransformPreviewGateTests.edited
    static var diff: Pipeline.WordDiff { .compute(old: original, new: edited) }

    // MARK: Dwell from Settings

    @Test func previewDwellFollowsTheSettingsChoice() {
        #expect(TransformPreviewDwell.fromSetting(seconds: 0.6) == TransformPreviewDwell(seconds: 0.6))
        #expect(TransformPreviewDwell.fromSetting(seconds: 0.9) == .standard)
        #expect(TransformPreviewDwell.fromSetting(seconds: 1.5) == TransformPreviewDwell(seconds: 1.5))
        // Manual ("Until I insert"): waits for the pill's Replace text, never replaces on time alone.
        let manual = TransformPreviewDwell.fromSetting(seconds: nil)
        #expect(manual == .manualReview && manual.manual)
        var gate = TransformPreviewGate(dwell: manual)
        gate.begin(); gate.showPreview(); gate.advance(by: 600)
        #expect(!gate.isDue, "no timed replacement in manual review")
        gate.confirm()
        #expect(gate.isDue)
    }

    /// Settings › "Until I insert" read the way AppContainer reads it: the preview rows carry
    /// Replace text / Cancel, the pill draws them, and nothing is replaced until Replace text.
    @Test func manualSettingShowsReplaceTextAndWaitsForIt() async {
        let settings = InMemorySettingsStore()
        TurnSettings.setPreviewDwell(.manual, store: settings)
        let h = TransformPreviewGateTests.harness()
        h.landing.previewDwell = { TransformPreviewDwell.fromSetting(seconds: TurnSettings.previewDwell(settings).seconds) }
        let sleeps = Box(0), seen = Box<[String]>([]), rows = Box<TransformPreviewRows?>(nil)
        let stayed = Box(true)
        h.landing.sleep = { [landing = h.landing, system = h.system] _ in
            sleeps.value += 1
            seen.value.append(system.field.value)
            if sleeps.value == 1 { rows.value = landing.rows }
            // Every slice before Replace text: still R1's manual preview, the same rows.
            if landing.phase != .previewing || landing.rows != rows.value { stayed.value = false }
            if sleeps.value == 300 { landing.confirmPreview() }
        }
        _ = await TransformPreviewGateTests.instruct(h.landing)
        #expect(sleeps.value == 300, "300 slices (15 s of 50 ms) and still waiting until Replace text")
        #expect(stayed.value, "the preview stays `.preview(_, manual: true)` until Replace text")
        #expect(seen.value.allSatisfy { $0 == Self.original }, "nothing replaced before Replace text")
        #expect(h.system.field.value == Self.edited)
        let preview = try? #require(rows.value)
        if let p = h.landing.currentPreview { #expect(preview == .preview(p, manual: true)) }
        #expect(preview?.buttons.map(\.label) == [TransformPreviewCopy.replaceButton, TransformPreviewCopy.cancelButton])
        #expect(preview?.buttons.first?.primary == true)
        // The pill draws those buttons over the edited preview (W3H `drawingTransform`).
        let drawn = PillContent.make(.transform(.init(editingWords: 4, stage: .notice("Preview"))), context: PillTurnContext())
            .drawingTransform(preview)
        #expect(drawn.buttons.map(\.label) == [TransformPreviewCopy.replaceButton, TransformPreviewCopy.cancelButton])
    }

    @Test func landingReadsTheDwellEachTurn() async {
        let h = TransformPreviewGateTests.harness()
        let slept = Box<TimeInterval>(0)
        h.landing.sleep = { dt in slept.value += dt }
        h.landing.previewDwell = { .fromSetting(seconds: 1.5) }
        _ = await TransformPreviewGateTests.instruct(h.landing)
        #expect(abs(slept.value - 1.5) < 0.001)
        #expect(h.system.field.value == Self.edited)
    }

    // MARK: Escape

    private func driver() -> (TransformPillDriver, FakeEscapeKey, EscapeHotkey, Box<Int>) {
        let driver = TransformPillDriver(pill: PillViewModel())
        let key = FakeEscapeKey()
        let escape = EscapeHotkey(backend: key.backend)
        let cancels = Box(0)
        driver.onCancel = { cancels.value += 1 }
        driver.escape = escape
        return (driver, key, escape, cancels)
    }

    @Test func escapeIsBorrowedOnlyWhileTheEditAwaitsItsOutcome() {
        let (d, key, escape, _) = driver()
        #expect(key.live.isEmpty, "idle: Escape belongs to the frontmost app")
        d.handle(.began(words: 4))
        #expect(key.live.count == 1 && escape.phase == .beforeWrite)
        d.handle(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        #expect(key.live.count == 1 && key.installed.count == 1, "one registration for the whole of R1")
        d.handle(.applied(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        #expect(key.live.isEmpty, "written: Undo is the way back, not Escape")
        for outcome: TransformPillReducer.Event in [.cancelled, .held(reason: "target text changed"), .noChange, .failed("no rewrite")] {
            d.handle(.began(words: 4))
            #expect(key.live.count == 1)
            d.handle(outcome)
            #expect(key.live.isEmpty, "\(outcome) gives Escape back")
        }
    }

    @Test func escapeDuringThePreviewCancelsOnce() {
        let (d, _, escape, cancels) = driver()
        d.handle(.began(words: 4))
        d.handle(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        escape.press()
        escape.press()
        #expect(cancels.value == 1, "a double Escape cancels once")
        d.handle(.cancelled)
        escape.press()
        #expect(cancels.value == 1, "after the outcome Escape is not ours")
    }

    @Test func escapeInThePreviewKeepsTheOriginalEndToEnd() async {
        let (d, _, escape, _) = driver()
        let h = TransformPreviewGateTests.harness()
        let pending = Box<[TransformPillReducer.Event]>([])
        h.landing.onEvent = { e in pending.value.append(e) }
        d.onCancel = { [landing = h.landing] in landing.cancelPreview() }
        h.landing.sleep = { _ in
            await MainActor.run {
                for e in pending.value { d.handle(e) }
                pending.value.removeAll()
                escape.press()
            }
        }
        let out = await TransformPreviewGateTests.instruct(h.landing)
        #expect(out == .transformed(.failed(.unavailable(reason: "cancelled"))))
        #expect(h.system.field.value == Self.original && h.system.postCount == 0)
        for e in pending.value { d.handle(e) }
        #expect(d.reducer.state == .transform(.init(editingWords: 4, stage: .notice(TransformPreviewCopy.cancelledLine))))
        #expect(!escape.isRegistered)
    }

    // MARK: Hover

    @Test func hoverFreezesOnlyThePreview() {
        let pill = PillViewModel()
        let d = TransformPillDriver(pill: pill)
        let pauses = Box<[Bool]>([])
        d.onPause = { pauses.value.append($0) }

        d.handle(.began(words: 4))
        pill.setPointerInside(true)
        #expect(pauses.value.isEmpty, "no dwell runs while the model is editing")
        d.handle(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        #expect(pauses.value == [true], "a preview that opens under the pointer starts frozen")
        pill.setPointerInside(false)
        pill.setPointerInside(true)
        #expect(pauses.value == [true, false, true])
        d.handle(.applied(instruction: "i", before: Self.original, after: Self.edited, diff: Self.diff))
        #expect(pauses.value == [true, false, true, false], "the preview is over")
        pill.setPointerInside(false)
        #expect(pauses.value.count == 4, "hover on the Undo row freezes nothing")
    }

    @Test func hoverOverThePillHoldsTheReplacementEndToEnd() async {
        let h = TransformPreviewGateTests.harness()
        let slices = Box(0)
        h.landing.sleep = { [landing = h.landing, system = h.system] _ in
            slices.value += 1
            if slices.value == 1 { landing.pausePreview(true) }
            #expect(system.field.value == Self.original)
            if slices.value == 400 { landing.pausePreview(false) }
        }
        _ = await TransformPreviewGateTests.instruct(h.landing)
        #expect(slices.value > 400, "held for as long as the pointer stayed")
        #expect(h.system.field.value == Self.edited)
    }
}
