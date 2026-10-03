import Foundation
import Shared

/// Mirror of Injection's `ReplaceRangeRequest` (P1.8 T5) so `Pipeline` stays independent of
/// `Injection`; the app maps it 1:1. Safety rule: replace only if the region still reads
/// exactly as `expected`.
public struct TransformReplaceRequest: Equatable, Sendable {
    public var range: Range<Int>
    public var expected: String
    public var replacement: String
    public var elementToken: String?
    public init(range: Range<Int>, expected: String, replacement: String, elementToken: String? = nil) {
        self.range = range; self.expected = expected; self.replacement = replacement; self.elementToken = elementToken
    }
    /// Where the replacement sits after a successful apply — the selection for a chained turn.
    public var resultingRange: Range<Int> { range.lowerBound..<(range.lowerBound + replacement.utf16.count) }
}

public enum TransformReplaceOutcome: Equatable, Sendable {
    case replaced(verified: Bool)
    case mismatch(actual: String?)
    case unavailable(reason: String)
    public var succeeded: Bool { if case .replaced = self { return true }; return false }
}

/// The injector face the transform engine talks to. Live: adapter over `ReplaceRangeEditor`.
public protocol TransformReplaceSink: Sendable {
    func replace(_ request: TransformReplaceRequest) -> TransformReplaceOutcome
}

/// One "talk to your text" session: keeps the selection warm across chained turns
/// (Kivi pattern) and remembers the last turn so "↩ / try again" can undo it.
public final class TransformSession: @unchecked Sendable {
    public struct Turn: Equatable, Sendable {
        public var instruction: String
        public var before: SelectionSnapshot
        public var after: SelectionSnapshot
        public var diff: WordDiff
        public var source: TransformResult.Source
    }

    private let lock = NSLock()
    public let executor: TransformExecutor
    public let sink: any TransformReplaceSink
    /// Chained-turn window (P2.3: pill stays warm ~8 s).
    public var warmWindow: TimeInterval = 8
    private(set) public var selection: SelectionSnapshot?
    private(set) public var turns: [Turn] = []
    private var lastTurnAt: Date?

    public init(executor: TransformExecutor, sink: any TransformReplaceSink, selection: SelectionSnapshot? = nil) {
        self.executor = executor; self.sink = sink; self.selection = selection
    }

    public var isWarm: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = lastTurnAt, selection != nil else { return false }
        return Date().timeIntervalSince(t) < warmWindow
    }

    /// Use `fresh` if the user selected something new; otherwise reuse the warm selection.
    public func begin(with fresh: SelectionSnapshot?) -> SelectionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        // H9 — after an applied edit the field keeps the result selected, so a fresh read of that
        // same range is the warm selection (turns kept for undo), not a new session.
        if let fresh, fresh.isMeaningful, !fresh.isSameTarget(as: selection) {
            selection = fresh; turns = []; lastTurnAt = nil
            return fresh
        }
        if lastTurnAt == nil { return selection }                       // session just started
        if let t = lastTurnAt, Date().timeIntervalSince(t) < warmWindow { return selection }
        return fresh
    }

    public enum Step: Equatable, Sendable {
        case applied(TransformResult, TransformReplaceOutcome)
        case noChange(TransformResult)
        case failed(TransformReplaceOutcome)
    }

    /// Execute + replace + advance the selection for the next chained turn.
    public func run(instruction: [TranscriptSpan], context: StageContext, now: Date = Date()) async throws -> Step {
        guard let sel = selection else { throw TransformError.emptySelection }
        let history = turns.map(\.instruction)
        let request = TransformRequest(instruction: instruction, selection: sel, context: context, history: history)
        let result = try await executor.execute(request, context: context)
        if result.diff.isIdentity { return .noChange(result) }
        let outcome = sink.replace(result.replace)
        guard outcome.succeeded else { return .failed(outcome) }
        let after = SelectionSnapshot(text: result.output, range: result.replace.resultingRange, before: sel.before, after: sel.after,
                                      bundleID: sel.bundleID, elementToken: sel.elementToken, destination: sel.destination)
        commit(Turn(instruction: request.instructionText, before: sel, after: after, diff: result.diff, source: result.source), at: now)
        return .applied(result, outcome)
    }

    private func commit(_ turn: Turn, at now: Date) {
        lock.lock(); turns.append(turn); selection = turn.after; lastTurnAt = now; lock.unlock()
    }

    /// "↩": put the previous text back (only if the region still reads as what we wrote).
    @discardableResult
    public func undoLast() -> TransformReplaceOutcome? {
        lock.lock()
        guard let turn = turns.last else { lock.unlock(); return nil }
        lock.unlock()
        let outcome = sink.replace(TransformReplaceRequest(range: turn.after.range, expected: turn.after.text,
                                                           replacement: turn.before.text, elementToken: turn.before.elementToken))
        if outcome.succeeded {
            lock.lock(); turns.removeLast(); selection = turn.before; lastTurnAt = Date(); lock.unlock()
        }
        return outcome
    }
}
