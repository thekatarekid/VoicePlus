import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// S12 — selected-text transforms: before / after preview, replacement only after target
/// revalidation, range-safe Undo (design_v1 §6 R1 / R2, §8.8). Everything runs on
/// `MockSystemAccess`; the preview's timer is injected, so no test sleeps.
@Suite("S12 — transform preview gate")
struct TransformPreviewGateTests {
    static let mail = FocusSnapshot(pid: 100, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-1")
    static let original = "Can we meet Friday"
    static let edited = "Can we meet on Friday?"

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    struct Harness {
        let landing: TransformLanding
        let system: MockSystemAccess
        let events: Box<[TransformPillReducer.Event]>
        let recoveries: Box<[TransformRecovery]>
        let clock: Box<Date>
    }

    static func harness(output: String = edited) -> Harness {
        let system = MockSystemAccess(frontmost: mail)
        system.field = .init(value: original, selection: 0..<original.utf16.count)
        let provider = ScriptedRewriter()
        provider.script = [(instruction: "friday", output: output)]
        let session = TransformSession(executor: TransformExecutor(providers: provider), sink: InjectionTransformReplaceSink(system: system))
        let landing = TransformLanding(session: session, detector: SystemAccessSelectionDetector(system: system),
                                       qa: QuestionAnswerStage(answerer: HeuristicAnswerer()), system: system,
                                       injector: TextInjector(system: system))
        let h = Harness(landing: landing, system: system, events: Box([]), recoveries: Box([]),
                        clock: Box(Date(timeIntervalSince1970: 50_000)))
        landing.onEvent = { [events = h.events] in events.value.append($0) }
        landing.onRecovery = { [recoveries = h.recoveries] in recoveries.value.append($0) }
        landing.clock = { [clock = h.clock] in clock.value }
        landing.sleep = { _ in }
        return h
    }

    static func instruct(_ landing: TransformLanding, _ text: String = "fix the friday question") async -> TransformLanding.Outcome {
        await landing.handle(TransformLandingTests.spans(text), decision: .fallback(), context: StageContext())
    }

    static func kinds(_ events: [TransformPillReducer.Event]) -> [String] {
        events.map { e in
            switch e {
            case .began: return "began"
            case .previewing: return "previewing"
            case .applied: return "applied"
            case .noChange: return "noChange"
            case .failed: return "failed"
            case .cancelled: return "cancelled"
            case .held: return "held"
            case .undoRefused: return "undoRefused"
            case .undone: return "undone"
            case .tick: return "tick"
            case .ended: return "ended"
            }
        }
    }

    // MARK: The pure gate

    @Test func replacementIsReachableOnlyThroughAPreviewThatRanItsDwell() {
        var g = TransformPreviewGate(dwell: .standard)
        g.begin()
        #expect(g.phase == .editing && !g.isDue)
        let early = g.revalidate(.valid)
        #expect(!early, "no replacement while the model is still editing")
        #expect(g.phase == .editing)
        g.showPreview()
        #expect(g.phase == .previewing && g.decision == .wait(TransformPreviewGate.slice))
        g.advance(by: 0.5)
        #expect(!g.isDue && !g.revalidate(.valid), "no replacement before the dwell ends")
        g.advance(by: 0.4)
        #expect(g.isDue && g.decision == .commit)
        #expect(g.revalidate(.valid) && g.phase == .replacing)
        g.replaced(.replaced(verified: true), at: Date(timeIntervalSince1970: 10))
        #expect(g.phase == .updated(at: Date(timeIntervalSince1970: 10)))
    }

    @Test func aChangedTargetIsHeldNeverReplaced() {
        for why in [TransformTargetCheck.Failure.appChanged, .fieldChanged, .textChanged, .unreadable] {
            var g = TransformPreviewGate(dwell: TransformPreviewDwell(seconds: 0))
            g.begin(); g.showPreview()
            #expect(g.isDue)
            let replaced = g.revalidate(.changed(why))
            #expect(!replaced)
            #expect(g.phase == .held(why))
            g.replaced(.replaced(verified: true), at: Date())
            #expect(g.phase == .held(why), "a held edit can never turn into a replacement")
        }
    }

    @Test func pauseFreezesTheDwellAndCancelKeepsTheOriginal() {
        var g = TransformPreviewGate(dwell: .standard)
        g.begin(); g.showPreview()
        g.setPaused(true)
        g.advance(by: 30)
        #expect(!g.isDue && g.decision == .wait(TransformPreviewGate.slice), "hover freezes the dwell")
        g.setPaused(false)
        g.advance(by: 0.9)
        #expect(g.isDue)
        g.cancel()
        #expect(g.phase == .cancelled && g.decision == .cancel && !g.revalidate(.valid))
    }

    @Test func manualReviewWaitsForReplaceText() {
        var g = TransformPreviewGate(dwell: .manualReview)
        g.begin(); g.showPreview()
        g.advance(by: 3600)
        #expect(!g.isDue, "manual review never replaces on time alone")
        g.confirm()
        #expect(g.isDue && g.revalidate(.valid))
    }

    @Test func undoIsOpenForFiveSecondsAndOnlyWhileTheRangeMatches() {
        let t0 = Date(timeIntervalSince1970: 100)
        var g = TransformPreviewGate(dwell: TransformPreviewDwell(seconds: 0))
        #expect(g.undoVerdict(at: t0, check: .valid) == .nothingToUndo)
        g.begin(); g.showPreview(); _ = g.revalidate(.valid); g.replaced(.replaced(verified: true), at: t0)
        #expect(g.undoVerdict(at: t0 + 4.9, check: .valid) == .allowed)
        #expect(g.undoVerdict(at: t0 + 5, check: .valid) == .expired)
        #expect(g.undoVerdict(at: t0 + 1, check: .changed(.textChanged)) == .stale(.textChanged))
        g.undone()
        #expect(g.phase == .undone && g.undoVerdict(at: t0 + 1, check: .valid) == .nothingToUndo)
    }

    // MARK: Target revalidation

    @Test func targetCheckComparesAppFieldAndText() {
        let system = MockSystemAccess(frontmost: Self.mail)
        system.field = .init(value: "alpha beta gamma", selection: 6..<10)
        func check() -> TransformTargetCheck.Result {
            TransformTargetCheck.verify(range: 6..<10, expected: "beta", bundleID: "com.apple.mail", elementToken: "el-1", system: system)
        }
        #expect(check() == .valid)
        system.field.value = "alpha BETA gamma"
        #expect(check() == .changed(.textChanged))
        system.field.value = "alpha"
        #expect(check() == .changed(.textChanged), "a range past the end is changed, not a crash")
        system.field.value = "alpha beta gamma"
        system.axReadable = false
        #expect(check() == .changed(.unreadable), "unreadable is never treated as unchanged")
        system.axReadable = true
        system.frontmost = FocusSnapshot(pid: 100, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-2")
        #expect(check() == .changed(.fieldChanged))
        system.frontmost = FocusSnapshot(pid: 200, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "el-1")
        #expect(check() == .changed(.appChanged))
        #expect(TransformTargetCheck.Failure.appChanged.heldReason == DeliveryReason.destinationChanged)
        #expect(RecoveryCatalog.entry(forDeliveryReason: TransformTargetCheck.Failure.textChanged.heldReason).id == .D01)
    }

    // MARK: The landing: preview → revalidate → replace → undo

    @Test func previewShowsBeforeAndAfterWhileTheFieldIsUntouched() async {
        let h = Self.harness()
        let during = Box<[String]>([]), phases = Box<[TransformPreviewGate.Phase]>([]), rows = Box<[TransformPreviewRows]>([])
        let slept = Box<TimeInterval>(0)
        h.landing.sleep = { [landing = h.landing, system = h.system] dt in
            during.value.append(system.field.value)
            phases.value.append(landing.phase)
            if let r = landing.rows { rows.value.append(r) }
            slept.value += dt
        }
        let out = await Self.instruct(h.landing)
        guard case .transformed(.applied(_, .replaced)) = out else { Issue.record("expected applied, got \(out)"); return }
        #expect(!during.value.isEmpty && during.value.allSatisfy { $0 == Self.original }, "nothing replaced during the preview")
        #expect(phases.value.allSatisfy { $0 == .previewing })
        #expect(abs(slept.value - TransformPreviewDwell.standard.seconds) < 0.001, "the 900 ms dwell, on the preview's own timer")
        #expect(h.system.field.value == Self.edited)
        #expect(Self.kinds(h.events.value) == ["began", "previewing", "applied"])
        if case .previewing(_, let before, let after, let diff) = h.events.value[1] {
            #expect(before == Self.original && after == Self.edited && !diff.isIdentity)
        }
        // The pill rows of the preview: before and after, R1's helper, the destination named.
        let preview = rows.value.first
        #expect(preview?.designStateKey == "editing" && preview?.status == "Ready for Mail")
        #expect(preview?.before == Self.original && preview?.text == Self.edited)
        #expect(preview?.helper == PillCopy.editingHelper && preview?.buttons.isEmpty == true)
        // R2 afterwards.
        #expect(h.landing.rows == .updated(TransformPreview(instruction: "fix the friday question", before: Self.original,
                                                            after: Self.edited, destination: "Mail")))
        #expect(h.landing.session.turns.count == 1)
    }

    @Test func textEditedDuringThePreviewIsNeverOverwritten() async {
        let h = Self.harness()
        h.landing.sleep = { [system = h.system] _ in system.field.value = "Can we meet Monday" }
        let out = await Self.instruct(h.landing)
        guard case .transformed(.failed(.mismatch)) = out else { Issue.record("expected held, got \(out)"); return }
        #expect(h.system.field.value == "Can we meet Monday", "the user's own edit stays")
        #expect(h.system.postCount == 0, "nothing was posted into the field")
        #expect(Self.kinds(h.events.value) == ["began", "previewing", "held"])
        #expect(h.recoveries.value == [TransformRecovery(kind: .editNotApplied, text: Self.edited, destination: "Mail", failure: .textChanged)])
        #expect(h.recoveries.value.first?.entry.id == .D10)
        #expect(h.landing.session.turns.isEmpty, "the staged turn is dropped")
        #expect(h.landing.session.selection?.text == Self.original)
        #expect(h.landing.phase == .held(.textChanged))
    }

    @Test func switchingAppOrFieldDuringThePreviewHoldsTheEdit() async {
        for (front, why) in [(FocusSnapshot(pid: 200, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "el-1"), TransformTargetCheck.Failure.appChanged),
                             (FocusSnapshot(pid: 100, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-7"), .fieldChanged)] {
            let h = Self.harness()
            h.landing.sleep = { [system = h.system] _ in system.frontmost = front }
            _ = await Self.instruct(h.landing)
            #expect(h.system.field.value == Self.original && h.system.postCount == 0)
            #expect(h.recoveries.value.map(\.failure) == [why])
            #expect(h.recoveries.value.first?.heldReason == why.heldReason)
        }
    }

    @Test func cancelDuringThePreviewKeepsTheOriginal() async {
        let h = Self.harness()
        h.landing.sleep = { [landing = h.landing] _ in landing.cancelPreview() }
        let out = await Self.instruct(h.landing)
        #expect(out == .transformed(.failed(.unavailable(reason: "cancelled"))))
        #expect(h.system.field.value == Self.original && h.system.postCount == 0)
        #expect(Self.kinds(h.events.value) == ["began", "previewing", "cancelled"])
        #expect(h.recoveries.value.isEmpty && h.landing.session.turns.isEmpty)
    }

    @Test func manualReviewReplacesOnlyAfterReplaceText() async {
        let h = Self.harness()
        h.landing.previewDwell = { .manualReview }
        let sleeps = Box(0), seen = Box<[String]>([]), buttons = Box<[TransformPreviewRows.Button]>([])
        h.landing.sleep = { [landing = h.landing, system = h.system] _ in
            sleeps.value += 1
            seen.value.append(system.field.value)
            if sleeps.value == 1 { buttons.value = landing.rows?.buttons ?? [] }
            if sleeps.value == 200 { landing.confirmPreview() }
        }
        _ = await Self.instruct(h.landing)
        #expect(sleeps.value == 200 && seen.value.allSatisfy { $0 == Self.original })
        #expect(h.system.field.value == Self.edited)
        #expect(buttons.value.map(\.label) == ["Replace text", "Cancel"] && buttons.value.first?.primary == true)
    }

    @Test func undoWithinFiveSecondsRestoresTheOriginal() async {
        let h = Self.harness()
        _ = await Self.instruct(h.landing)
        h.clock.value += 4
        #expect(h.landing.undo() == .replaced(verified: true))
        #expect(h.system.field.value == Self.original)
        #expect(Self.kinds(h.events.value).last == "undone" && h.landing.phase == .undone)
        #expect(h.landing.undo() == nil, "one undo per replacement")
    }

    @Test func undoAfterFiveSecondsIsRefusedAndWritesNothing() async {
        let h = Self.harness()
        _ = await Self.instruct(h.landing)
        let posts = h.system.postCount
        h.clock.value += 5
        #expect(h.landing.undo() == .unavailable(reason: "undo expired"))
        #expect(h.system.field.value == Self.edited && h.system.postCount == posts)
        #expect(h.events.value.last == .undoRefused(TransformPreviewCopy.undoExpiredLine))
    }

    @Test func undoOnAChangedRangeGoesToRecoveryInstead() async {
        let h = Self.harness()
        _ = await Self.instruct(h.landing)
        let posts = h.system.postCount
        h.system.field.value = "Could we meet on Friday?"   // the user edited inside the replaced range
        h.clock.value += 1
        #expect(h.landing.undo() == .mismatch(actual: nil))
        #expect(h.system.field.value == "Could we meet on Friday?" && h.system.postCount == posts, "a stale range is never overwritten")
        #expect(h.recoveries.value == [TransformRecovery(kind: .undoNotApplied, text: Self.original, destination: "Mail", failure: .textChanged)])
        #expect(Self.kinds(h.events.value).last == "held")
    }

    @Test func undoAfterSwitchingAppGoesToRecovery() async {
        let h = Self.harness()
        _ = await Self.instruct(h.landing)
        h.system.frontmost = FocusSnapshot(pid: 200, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "el-1")
        #expect(h.landing.undo() == .mismatch(actual: nil))
        #expect(h.recoveries.value.map(\.failure) == [.appChanged])
    }

    @Test func aNewInstructionSupersedesAPendingPreview() async {
        let h = Self.harness()
        // Real (1 ms) sleeps so the two turns genuinely overlap; the first waits in manual review.
        h.landing.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        h.landing.previewDwell = { .manualReview }
        async let first = Self.instruct(h.landing)
        var spins = 0
        while h.landing.phase != .previewing, spins < 5_000 { spins += 1; try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(h.landing.phase == .previewing)
        h.landing.previewDwell = { .standard }
        let second = await Self.instruct(h.landing)
        let firstOut = await first
        #expect(firstOut == .transformed(.failed(.unavailable(reason: "cancelled"))), "the superseded preview replaces nothing")
        guard case .transformed(.applied) = second else { Issue.record("second instruction: \(second)"); return }
        #expect(h.system.field.value == Self.edited, "the newer instruction's edit is the one written, once")
        #expect(h.landing.session.turns.count == 1)
    }

    // MARK: Copy — the verified prototype's R1 / R2 rows

    private struct PillEntry: Decodable {
        struct Button: Decodable { let label: String; let action: String; let primary: Bool }
        let status: String
        let strings: [String]
        let buttons: [Button]
        // `idle` / `ready` carry only a hint; they decode to empty rows.
        private enum Keys: String, CodingKey { case status, strings, buttons }
        init(from decoder: any Swift.Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            strings = try c.decodeIfPresent([String].self, forKey: .strings) ?? []
            buttons = try c.decodeIfPresent([Button].self, forKey: .buttons) ?? []
        }
    }
    private struct CopyFixture: Decodable {
        struct Err: Decodable { let id, headline, consequence, action: String }
        let pill: [String: PillEntry]
        let errors: [Err]
    }

    @Test func rowsMatchTheDesignCopy() throws {
        let dir = try #require(AppPaths.fixturesDirectory())
        let copy = try JSONDecoder().decode(CopyFixture.self, from: Data(contentsOf: dir.appendingPathComponent("design/design_copy.json")))
        let editing = try #require(copy.pill["editing"]), undo = try #require(copy.pill["undo"])

        let r1 = TransformPreviewRows.editing(words: 18, instruction: "Make the selected text more concise")
        #expect(r1.status == editing.status && r1.status == editing.strings[0])
        #expect(r1.text == editing.strings[1] && r1.helper == editing.strings[2] && r1.buttons.isEmpty && editing.buttons.isEmpty)

        let p = TransformPreview(instruction: "shorter", before: "Could we perhaps meet on Friday?", after: "Can we meet on Friday?", destination: "Mail")
        let r2 = TransformPreviewRows.updated(p)
        #expect(r2.designStateKey == "undo")
        #expect(r2.status == undo.status && r2.text == undo.strings[1] && r2.helper == undo.strings[2])
        #expect(r2.buttons.map(\.label) == undo.buttons.map(\.label) && r2.buttons.map(\.action) == undo.buttons.map(\.action))
        #expect(r2.buttons.map(\.primary) == undo.buttons.map(\.primary))
        #expect(TransformPreviewCopy.editingStatus(words: 1) == "Editing 1 word…")

        let d10 = try #require(copy.errors.first { $0.id == "D10" })
        #expect(TransformPreviewCopy.stale.headline == d10.headline && TransformPreviewCopy.stale.consequence == d10.consequence)
        #expect(TransformPreviewCopy.stale.action == d10.action)
    }

    @Test func compactLineShowsRemovedThenAddedWords() {
        let p = TransformPreview(instruction: "x", before: "churn was 4 percent", after: "churn was 4%")
        #expect(TransformPreviewCopy.compactLine(p) == "Preview · 4 percent → 4%")
        #expect(TransformPreviewCopy.compactLine(TransformPreview(instruction: "x", before: "a b", after: "a b c")) == "Preview · + c")
        #expect(TransformPreviewCopy.compactLine(TransformPreview(instruction: "x", before: "a b c", after: "a b")) == "Preview · − c")
        let long = TransformPreview(instruction: "x", before: "one", after: String(repeating: "word ", count: 20))
        #expect(TransformPreviewCopy.compactLine(long, limit: 10).hasSuffix("word word…"))
    }

    // MARK: The transform row

    @Test func pillReducerPreviewThenUpdatedThenClosingNotices() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var r = TransformPillReducer(warmWindow: 8, ghostLifetime: 5)
        r.reduce(.began(words: 4), now: t0)
        let diff = Pipeline.WordDiff.compute(old: Self.original, new: Self.edited)
        let s = r.reduce(.previewing(instruction: "i", before: Self.original, after: Self.edited, diff: diff), now: t0)
        #expect(s == .transform(.init(editingWords: 4, stage: .notice("Preview · Friday → on Friday?"))))
        #expect(r.morph != nil && r.ghost == nil && !r.isWarm, "nothing written yet: no undo ghost, no warm countdown")
        #expect(r.reduce(.tick, now: t0 + 30) == s, "the preview does not time out on the row")
        let done = r.reduce(.applied(instruction: "i", before: Self.original, after: Self.edited, diff: diff), now: t0)
        guard case .transform(let info) = done, case .done = info.stage else { Issue.record("expected done, got \(done)"); return }
        #expect(r.ghost?.after == Self.edited && r.isWarm)

        var c = TransformPillReducer()
        c.reduce(.began(words: 4), now: t0)
        #expect(c.reduce(.cancelled, now: t0) == .transform(.init(editingWords: 4, stage: .notice(TransformPreviewCopy.cancelledLine))))
        #expect(c.needsTicks)
        #expect(c.reduce(.tick, now: t0 + 1) != .hidden)
        #expect(c.reduce(.tick, now: t0 + TransformPillReducer.closingNotice) == .hidden && !c.needsTicks)

        var held = TransformPillReducer()
        held.reduce(.began(words: 4), now: t0)
        #expect(held.reduce(.held(reason: "target text changed"), now: t0) == .hidden, "the held row takes over")
    }
}
