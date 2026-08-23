import Engine
import Foundation
import Injection
import Pipeline
import Shared

/// `TransformReplaceSink` (Pipeline) → Injection's AX replace-range (P1.8 T5), 1:1 mapping.
public final class InjectionTransformReplaceSink: TransformReplaceSink, @unchecked Sendable {
    private let editor: ReplaceRangeEditor
    public init(system: SystemAccess) { editor = ReplaceRangeEditor(system: system) }
    public func replace(_ request: TransformReplaceRequest) -> TransformReplaceOutcome {
        switch editor.replace(ReplaceRangeRequest(range: request.range, expected: request.expected, replacement: request.replacement)) {
        case .replaced(let v): return .replaced(verified: v)
        case .mismatch(let a): return .mismatch(actual: a)
        case .unavailable(let r): return .unavailable(reason: r)
        }
    }
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
public final class TransformLanding: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case transformed(TransformSession.Step)
        case answered(String, InjectionOutcome)
        case refused(String)
        case notHandled
    }

    public let session: TransformSession
    public let detector: any SelectionDetecting
    public let qa: QuestionAnswerStage
    public let system: SystemAccess
    public let injector: any Injector
    /// Pill events (reduced by `TransformPillReducer`).
    public var onEvent: ((TransformPillReducer.Event) -> Void)?
    public var clock: () -> Date = Date.init
    private var lastInstruction: [TranscriptSpan]?
    private var lastContext: StageContext?

    public init(session: TransformSession, detector: any SelectionDetecting, qa: QuestionAnswerStage, system: SystemAccess, injector: any Injector) {
        self.session = session; self.detector = detector; self.qa = qa; self.system = system; self.injector = injector
    }

    /// Bet 5: a selection (fresh, or the warm one from the previous turn) is the only signal
    /// that turns an utterance into a transform/question.
    public func route(_ decision: GatekeeperDecision) -> TransformRouteDecision {
        let fresh = detector.currentSelection()
        let sel = (fresh?.isMeaningful == true) ? fresh : (session.isWarm ? session.selection : nil)
        return TransformRouter.decide(gatekeeper: decision, selection: sel)
    }

    public func handle(_ spans: [TranscriptSpan], decision: GatekeeperDecision, context: StageContext) async -> Outcome {
        let r = route(decision)
        switch r.route {
        case .transform:
            guard let sel = session.begin(with: r.selection) else { return .notHandled }
            onEvent?(.began(words: sel.wordCount))
            lastInstruction = spans; lastContext = context
            return .transformed(await run(spans, context: context))
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

    private func run(_ spans: [TranscriptSpan], context: StageContext) async -> TransformSession.Step {
        do {
            let step = try await session.run(instruction: spans, context: context, now: clock())
            switch step {
            case .applied(let result, _):
                onEvent?(.applied(instruction: result.request.instructionText, before: result.request.selection.text, after: result.output, diff: result.diff))
            case .noChange: onEvent?(.noChange)
            case .failed(let o): onEvent?(.failed(Self.describe(o)))
            }
            return step
        } catch {
            let why = Self.describe(error)
            onEvent?(.failed(why))
            return .failed(.unavailable(reason: why))
        }
    }

    /// Ghost "↩": put the previous text back.
    @discardableResult
    public func undo() -> TransformReplaceOutcome? {
        let o = session.undoLast()
        if o?.succeeded == true { onEvent?(.undone) }
        return o
    }

    /// Ghost "try again": undo, then re-run the same instruction (providers may answer differently).
    public func tryAgain() async -> TransformSession.Step? {
        guard let spans = lastInstruction, let ctx = lastContext, undo()?.succeeded == true else { return nil }
        onEvent?(.began(words: session.selection?.wordCount ?? 0))
        return await run(spans, context: ctx)
    }

    static func describe(_ o: TransformReplaceOutcome) -> String {
        switch o {
        case .replaced: return "done"
        case .mismatch: return "text changed — not rewritten"
        case .unavailable(let r): return "can't edit here (\(r))"
        }
    }
    static func describe(_ e: Error) -> String {
        if let t = e as? TransformError {
            switch t {
            case .emptySelection: return "nothing selected"
            case .uncertainInstruction(let w): return "didn't catch “\(w.joined(separator: " "))”"
            default: return "no rewrite"
            }
        }
        return "no rewrite"
    }
}
