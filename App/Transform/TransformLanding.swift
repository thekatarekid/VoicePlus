import Engine
import Foundation
import Injection
import Pipeline
import Shared

/// `TransformReplaceSink` (Pipeline) → Injection's AX replace-range (P1.8 T5), 1:1 mapping.
///
/// S12 — it can also *stage*: while `staging` runs, a replacement the session asks for is recorded
/// and reported as done without touching the field, so the edit can be previewed first and written
/// only after the target is revalidated (`write`). `discarding` lets the session drop a staged turn
/// that was never written (its "undo" writes nothing either).
public final class InjectionTransformReplaceSink: TransformReplaceSink, @unchecked Sendable {
    private enum Mode { case live, stage, discard }

    private let editor: ReplaceRangeEditor
    private let lock = NSLock()
    private var mode: Mode = .live
    private var staged: TransformReplaceRequest?

    public init(system: SystemAccess) { editor = ReplaceRangeEditor(system: system) }

    public func replace(_ request: TransformReplaceRequest) -> TransformReplaceOutcome {
        lock.lock()
        let current = mode
        if current == .stage { staged = request }
        lock.unlock()
        switch current {
        case .stage: return .replaced(verified: false)   // recorded; nothing written
        case .discard: return .replaced(verified: true)   // dropping a turn that was never written
        case .live: return write(request)
        }
    }

    /// The real write, whatever mode the session call is in.
    public func write(_ request: TransformReplaceRequest) -> TransformReplaceOutcome {
        switch editor.replace(ReplaceRangeRequest(range: request.range, expected: request.expected, replacement: request.replacement,
                                                     selectResult: true)) {
        case .replaced(let v): return .replaced(verified: v)
        case .mismatch(let a): return .mismatch(actual: a)
        case .unavailable(let r): return .unavailable(reason: r)
        }
    }

    /// Runs `body` with replacements recorded instead of written; returns the one it recorded.
    func staging<T>(_ body: () async throws -> T) async rethrows -> (T, TransformReplaceRequest?) {
        setMode(.stage)
        defer { setMode(.live) }
        let value = try await body()
        return (value, takeStaged())
    }

    private func takeStaged() -> TransformReplaceRequest? {
        lock.lock(); defer { lock.unlock() }
        let request = staged
        staged = nil
        return request
    }

    /// Runs `body` with replacements reported as done and nothing written.
    func discarding<T>(_ body: () throws -> T) rethrows -> T {
        setMode(.discard)
        defer { setMode(.live) }
        return try body()
    }

    private func setMode(_ m: Mode) { lock.lock(); mode = m; if m == .live { staged = nil }; lock.unlock() }
}

/// `SelectionDetecting` over Injection's `SystemAccess` (mockable; `AXSelectionDetector` in
/// Pipeline reads AX directly and cannot be driven by tests).
public final class SystemAccessSelectionDetector: SelectionDetecting, @unchecked Sendable {
    private let system: SystemAccess
    public init(system: SystemAccess) { self.system = system }
    public func currentSelection() -> SelectionSnapshot? {
        guard let info = try? system.focusedElement(), let value = info.value, let range = info.selectedRange else { return nil }
        let front = system.frontmostApp()
        return SelectionSnapshot.from(value: value, selectedRange: range, bundleID: front?.bundleID, elementToken: front?.elementToken)
    }
}

/// P2.3 — the "talk to your text" landing path: transform (replace in place, chained turns on
/// the warm selection) and question (answer typed below the selection). Returns `.notHandled`
/// for everything else so `UtteranceLander` types as usual.
///
/// S12 — a transform is previewed before it replaces anything (R1), written only after the target
/// is revalidated, and undone only while the edited range still matches, within 5 s (R2). A target
/// that changed is never written; the text goes to recovery instead (`onRecovery`, D10).
public final class TransformLanding: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case transformed(TransformSession.Step)
        case answered(String, InjectionOutcome)
        case refused(String)
        /// H6 — "replace with …" over a selection: the lander formats these spans as dictation and
        /// types them through the normal injector over the (re)selected text — password refusal and
        /// newline-safe landing included.
        case replaceSelection([TranscriptSpan])
        /// H6 — "replace" alone: the notch asks for the new text; the next utterance within the warm
        /// window replaces the selection.
        case awaitingReplacement
        /// H7 — "copy this": the selection went to the clipboard (verified by read-back); text untouched.
        case copied(verified: Bool)
        /// H7 — "undo that" / "put it back" over a selection: the last edit's undo (nil: nothing to undo).
        case undid(TransformReplaceOutcome?)
        case notHandled
    }

    /// H7 — notch lines for the clipboard and undo commands.
    public static let copiedLine = "Copied"
    public static let copyFailedLine = "Couldn't copy · nothing changed"
    public static let nothingToUndoLine = "Nothing to undo"

    public let session: TransformSession
    public let detector: any SelectionDetecting
    public let qa: QuestionAnswerStage
    public let system: SystemAccess
    public let injector: any Injector
    /// Pill events (reduced by `TransformPillReducer`).
    public var onEvent: ((TransformPillReducer.Event) -> Void)?
    /// S12 — text that could not be written or put back safely, for the held-text surface.
    public var onRecovery: ((TransformRecovery) -> Void)?
    public var clock: () -> Date = Date.init
    /// S12 — how long the edited preview stays before the replacement (900 ms; manual review waits).
    public var previewDwell: () -> TransformPreviewDwell = { .standard }
    /// S12 — the preview's own timer. Injected so tests run it instantly; never the wall clock.
    public var sleep: (TimeInterval) async -> Void = { seconds in
        guard seconds > 0 else { await Task.yield(); return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private var lastInstruction: [TranscriptSpan]?
    private var lastContext: StageContext?
    /// H9 — set only by an applied edit (or its undo): follow-ups chain on the result, not after
    /// "no change" or a failure.
    private var lastTurnAt: Date?
    /// H6 — "replace" said alone: the selection waiting for its new text, and when it was asked.
    private var pendingReplace: (selection: SelectionSnapshot, at: Date)?

    private let lock = NSLock()
    private var gate = TransformPreviewGate()
    private var preview: TransformPreview?
    /// R1 before the edit exists: the selection's word count and the instruction.
    private var editing: (words: Int, instruction: String)?
    /// A transform turn is between `began` and its outcome; undo waits for it.
    private var busy = false

    /// Chained-turn window (P2.3, 8 s) measured on `clock` so the pill and tests agree.
    public var isWarm: Bool {
        guard let t = lastTurnAt, session.selection != nil else { return false }
        return clock().timeIntervalSince(t) < session.warmWindow
    }

    public init(session: TransformSession, detector: any SelectionDetecting, qa: QuestionAnswerStage, system: SystemAccess, injector: any Injector) {
        self.session = session; self.detector = detector; self.qa = qa; self.system = system; self.injector = injector
    }

    /// Bet 5: a selection is the only signal that turns an utterance into a transform/question.
    /// H9 — a follow-up edit chains only while the field still has the result selected: after an
    /// applied edit the result *is* the field's selection, so the fresh read finds it (and
    /// `TransformSession.begin` keeps the turns). A moved caret means dictation again.
    public func route(_ decision: GatekeeperDecision) -> TransformRouteDecision {
        let fresh = detector.currentSelection()
        return TransformRouter.decide(gatekeeper: decision, selection: fresh?.isMeaningful == true ? fresh : nil)
    }

    public func handle(_ spans: [TranscriptSpan], decision: GatekeeperDecision, context: StageContext) async -> Outcome {
        // H6 — "replace" said alone earlier: this utterance is the new text, while the selection is
        // still the one we asked about (or nothing else got selected) and within the warm window.
        if decision.route != .none, let pending = takePendingReplace() {
            let fresh = detector.currentSelection()
            if fresh?.isMeaningful != true || fresh!.isSameTarget(as: pending.selection) {
                return await replaceSelection(pending.selection, with: spans)
            }
        }
        let r = route(decision)
        switch r.route {
        case .transform:
            if let sel = r.selection, let command = SelectionReplaceCommand.parse(spans) {
                switch command {
                case .replace(let rest):
                    return await replaceSelection(sel, with: rest)
                case .awaitingText:
                    await settlePendingPreview()
                    sync { pendingReplace = (sel, clock()) }
                    onEvent?(.prompt(SelectionReplaceCommand.promptLine))
                    return .awaitingReplacement
                }
            }
            // H7 — catalogue commands that act outside the text: copy, cut's copy half, undo.
            let surface = context.extra[EditCommandCatalog.surfaceKey].flatMap(SurfaceKind.init(id:))
            if let sel = r.selection, let command = EditCommandCatalog.match(spans.joinedText, selection: sel.text, surface: surface) {
                switch command.action {
                case .copy:
                    await settlePendingPreview()
                    let ok = copyVerified(sel.text)
                    onEvent?(.notice(ok ? Self.copiedLine : Self.copyFailedLine))
                    return .copied(verified: ok)
                case .undo:
                    await settlePendingPreview()
                    let o = undo()
                    if o == nil { onEvent?(.notice(Self.nothingToUndoLine)) }
                    return .undid(o)
                case .cut:
                    // Cut = a verified copy, then the delete runs as an edit (preview, revalidate, write).
                    // A copy that did not stick deletes nothing.
                    guard copyVerified(sel.text) else {
                        onEvent?(.notice(Self.copyFailedLine))
                        return .copied(verified: false)
                    }
                default:
                    break
                }
            }
            guard let stager = session.sink as? InjectionTransformReplaceSink else {
                // Without staging the edit could not be previewed before it replaced the text.
                return .refused("can't preview this edit")
            }
            // A new instruction supersedes an edit still waiting in its preview; one turn at a time.
            await settlePendingPreview()
            guard claim() else { return .refused("finishing the previous edit") }
            guard let sel = session.begin(with: r.selection) else { release(); return .notHandled }
            onEvent?(.began(words: sel.wordCount))
            lastInstruction = spans; lastContext = context
            return .transformed(await run(spans, context: context, stager: stager))
        case .question:
            guard let sel = r.selection else { return .notHandled }
            var ctx = context
            ctx.extra[QuestionAnswerStage.selectionKey] = sel.text
            ctx.extra[QuestionAnswerStage.surroundingKey] = sel.before + " " + sel.after
            guard let out = try? await qa.answer(spans, context: ctx), case .insertBelow = out.intent, let answer = out.answer else {
                return .refused("no answer")
            }
            let end = sel.range.upperBound
            try? system.setFocusedSelectedRange(end..<end)
            let outcome = injector.inject(InjectionRequest(text: out.insertion, utteranceID: nil, expectedFocus: nil))
            return .answered(answer, outcome)
        default:
            return .notHandled
        }
    }

    /// H6 — hands the replacement to the lander's normal dictation path. The selection is made the
    /// field's selection again first (a warm one may have been collapsed by the app), so typing
    /// replaces exactly it. The session ends: its turns describe text that is gone.
    private func replaceSelection(_ sel: SelectionSnapshot, with spans: [TranscriptSpan]) async -> Outcome {
        await settlePendingPreview()
        if (try? system.focusedElement())?.selectedRange != sel.range {
            try? system.setFocusedSelectedRange(sel.range)
        }
        sync { pendingReplace = nil }
        lastTurnAt = nil
        onEvent?(.ended)
        return .replaceSelection(spans)
    }

    /// H7 — writes the text to the clipboard and reads it back; true only when it reads back exactly.
    private func copyVerified(_ text: String) -> Bool {
        system.writePasteboard(string: text)
        let items = system.readPasteboard().items
        guard let data = items.first?.types["public.utf8-plain-text"] ?? items.first?.types["NSStringPboardType"] else { return false }
        return String(data: data, encoding: .utf8) == text
    }

    private func takePendingReplace() -> (selection: SelectionSnapshot, at: Date)? {
        sync {
            defer { pendingReplace = nil }
            guard let p = pendingReplace, clock().timeIntervalSince(p.at) < session.warmWindow else { return nil }
            return p
        }
    }

    // MARK: Preview controls (pill hover, Replace text, Cancel / Escape)

    /// The gate's phase, for the pill and tests.
    public var phase: TransformPreviewGate.Phase { sync { gate.phase } }
    /// The edit being previewed or last written.
    public var currentPreview: TransformPreview? { sync { preview } }
    /// The rows the pill draws for the current phase; nil when no transform is showing.
    public var rows: TransformPreviewRows? {
        sync {
            switch (gate.phase, preview) {
            case (.editing, _): return editing.map { .editing(words: $0.words, instruction: $0.instruction) }
            case (.previewing, let p?), (.replacing, let p?): return .preview(p, manual: gate.dwell.manual)
            case (.updated, let p?): return .updated(p)
            default: return nil
            }
        }
    }

    /// "Replace text" (manual review) — or confirming early.
    public func confirmPreview() { sync { gate.confirm() } }
    /// Escape / Cancel: keep the original. Ignored once the write has started.
    public func cancelPreview() { sync { gate.cancel() } }
    /// Hover / focus / selection on the pill freezes the dwell.
    public func pausePreview(_ on: Bool) { sync { gate.setPaused(on) } }

    // MARK: The turn

    /// Takes the one transform slot; `run` gives it back.
    private func claim() -> Bool { sync { if busy { return false }; busy = true; return true } }
    private func release() { sync { busy = false } }

    /// One claimed turn: stage → preview → revalidate → write. Releases the claim when it ends.
    private func run(_ spans: [TranscriptSpan], context: StageContext, stager: InjectionTransformReplaceSink) async -> TransformSession.Step {
        defer { release() }
        let destination = system.frontmostApp()?.appName
        let dwell = previewDwell()
        let words = session.selection?.wordCount ?? 0
        sync {
            gate = TransformPreviewGate(dwell: dwell); gate.begin(); preview = nil
            editing = (words, spans.joinedText)
        }

        let staged: (TransformSession.Step, TransformReplaceRequest?)
        do {
            staged = try await stager.staging { try await session.run(instruction: spans, context: context, now: clock()) }
        } catch {
            let why = Self.describe(error)
            sync { gate.cancel() }
            onEvent?(.failed(why))
            return .failed(.unavailable(reason: why))
        }

        switch staged.0 {
        case .noChange:
            // H9 — nothing changed: the next hold is dictation unless something is selected.
            lastTurnAt = nil
            sync { gate.cancel() }
            onEvent?(.noChange)
            return staged.0
        case .failed(let o):
            sync { gate.cancel() }
            onEvent?(.failed(Self.describe(o)))
            return staged.0
        case .applied(let result, _):
            guard let request = staged.1, let turn = session.turns.last else {
                rollback(stager)
                onEvent?(.failed(RecoveryCatalog.entry(.T03).headline))   // S11: the original stands
                return .failed(.unavailable(reason: "no rewrite"))
            }
            let p = TransformPreview(instruction: result.request.instructionText, before: result.request.selection.text,
                                     after: result.output, destination: destination)
            let showing = sync { () -> Bool in preview = p; gate.showPreview(); return gate.phase == .previewing }
            if showing { onEvent?(.previewing(instruction: p.instruction, before: p.before, after: p.after, diff: result.diff)) }

            // R1: the preview dwells (pause, cancel, manual confirm) — nothing is written yet.
            guard await waitForPreview() == .commit else {
                rollback(stager)
                onEvent?(.cancelled)
                return .failed(.unavailable(reason: "cancelled"))
            }

            // The last look at the target before the one write.
            let check = TransformTargetCheck.verify(request, selection: turn.before, system: system)
            guard sync({ gate.revalidate(check) }) else {
                rollback(stager)
                if case .held(let why) = sync({ gate.phase }) {
                    hold(.editNotApplied, text: p.after, destination: destination, failure: why)
                    return .failed(.mismatch(actual: nil))
                }
                onEvent?(.cancelled)   // cancelled between the dwell and the check
                return .failed(.unavailable(reason: "cancelled"))
            }

            let outcome = stager.write(request)
            let now = clock()
            sync { gate.replaced(outcome, at: now) }
            guard outcome.succeeded else {
                rollback(stager)
                if case .mismatch = outcome {
                    hold(.editNotApplied, text: p.after, destination: destination, failure: .textChanged)
                } else {
                    onEvent?(.failed(Self.describe(outcome)))
                }
                return .failed(outcome)
            }
            lastTurnAt = now
            // R2: replaced — Undo for 5 s while the range still matches.
            onEvent?(.applied(instruction: p.instruction, before: p.before, after: p.after, diff: result.diff))
            return .applied(result, outcome)
        }
    }

    /// Polls the gate on the preview's own timer until it commits or is cancelled.
    private func waitForPreview() async -> TransformPreviewGate.Decision {
        while true {
            let decision = sync { gate.decision }
            guard case .wait(let dt) = decision else { return decision }
            await sleep(dt)
            sync { gate.advance(by: dt) }
        }
    }

    /// Drops the staged turn the session committed: the field was never written, so its "undo"
    /// writes nothing and only restores the session's selection.
    private func rollback(_ stager: InjectionTransformReplaceSink) {
        stager.discarding { _ = session.undoLast() }
    }

    private func hold(_ kind: TransformRecovery.Kind, text: String, destination: String?, failure: TransformTargetCheck.Failure) {
        let recovery = TransformRecovery(kind: kind, text: text, destination: destination ?? "", failure: failure)
        // The transform row steps aside; the held-text row (Insert here · Copy · Discard) owns it now.
        onEvent?(.held(reason: recovery.heldReason))
        onRecovery?(recovery)
    }

    /// Cancels an edit still in its preview and waits (bounded) for that turn to settle.
    private func settlePendingPreview() async {
        guard sync({ busy }) else { return }
        cancelPreview()
        for _ in 0..<200 where sync({ busy }) { await sleep(0.01) }
    }

    // MARK: Undo / try again

    /// Ghost "↩": put the previous text back — only within 5 s of the replacement, and only when the
    /// same field still reads exactly as what we wrote. A changed range is never overwritten: the
    /// original goes to recovery instead (D10).
    @discardableResult
    public func undo() -> TransformReplaceOutcome? {
        guard !sync({ busy }), let turn = session.turns.last else { return nil }
        let check = TransformTargetCheck.verify(range: turn.after.range, expected: turn.after.text,
                                                bundleID: turn.after.bundleID, elementToken: turn.after.elementToken, system: system)
        let destination = sync { preview?.destination }
        switch sync({ gate.undoVerdict(at: clock(), check: check) }) {
        case .nothingToUndo:
            return nil
        case .expired:
            onEvent?(.undoRefused(TransformPreviewCopy.undoExpiredLine))
            return .unavailable(reason: "undo expired")
        case .stale(let why):
            hold(.undoNotApplied, text: turn.before.text, destination: destination, failure: why)
            return .mismatch(actual: nil)
        case .allowed:
            let o = session.undoLast()
            if o?.succeeded == true {
                sync { gate.undone() }
                lastTurnAt = clock()
                onEvent?(.undone)
            } else if case .mismatch? = o {
                hold(.undoNotApplied, text: turn.before.text, destination: destination, failure: .textChanged)
            }
            return o
        }
    }

    /// Ghost "try again": undo, then re-run the same instruction (providers may answer differently).
    public func tryAgain() async -> TransformSession.Step? {
        guard let spans = lastInstruction, let ctx = lastContext,
              let stager = session.sink as? InjectionTransformReplaceSink, undo()?.succeeded == true,
              claim() else { return nil }
        onEvent?(.began(words: session.selection?.wordCount ?? 0))
        return await run(spans, context: ctx, stager: stager)
    }

    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// S11 — the pill line for an edit that did not land: catalogue copy. A changed range is D10
    /// ("The text has changed"); a write path that is unavailable is D05; the reason goes to the log.
    static func describe(_ o: TransformReplaceOutcome) -> String {
        switch o {
        case .replaced: return "done"
        case .mismatch: return RecoveryCatalog.entry(.D10).headline
        case .unavailable(let r):
            Log.app.error("recovery D05: edit could not be written: \(r)")
            return RecoveryCatalog.entry(.D05).headline
        }
    }
    /// S11 — a rewrite that threw: its catalogue entry (T05 for an instruction it did not catch, T03
    /// otherwise — the original text stands); the error's own text goes to the log.
    static func describe(_ e: Error) -> String {
        RecoveryCatalog.report(e).headline
    }
}
