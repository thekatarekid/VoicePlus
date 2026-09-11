import Foundation
import Shared

public extension StageID {
    /// P5.2 — wake-verb stripping.
    static let wakeVerb: StageID = "wakeVerb"
}

/// P5.2 — `GatekeeperPreRouting` hook. Active only while latched
/// (`context.extra[WakeVerbPreRoute.modeKey] == WakeVerbPreRoute.latchedValue`). Records the parse
/// for the stage and bumps the usage counter that drives the in-pill hint.
public final class WakeVerbPreRoute: GatekeeperPreRouting, @unchecked Sendable {
    public static let modeKey = "input.mode"
    /// The value `modeKey` carries while the session is latched. The **string** is deliberately
    /// still `"handsFree"`: it is the wire value of an in-process context key, and every reader
    /// goes through this constant, so renaming the symbol costs nothing while renaming the value
    /// would be a data change for no user-visible gain (V3 §4.7 renames code names, not payloads).
    public static let latchedValue = "handsFree"
    public let grammar: WakeVerbGrammar
    public let hints: WakeVerbHintModel
    private let lock = NSLock()
    private var parses: [String: WakeVerbParse] = [:]

    public init(grammar: WakeVerbGrammar = WakeVerbGrammar(), hints: WakeVerbHintModel = WakeVerbHintModel()) {
        self.grammar = grammar; self.hints = hints
    }

    public static func isLatched(_ context: StageContext) -> Bool {
        context.extra[modeKey] == latchedValue
    }

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard Self.isLatched(context), let p = grammar.parse(text) else { return nil }
        lock.lock(); parses[text] = p; lock.unlock()
        hints.recordUse()
        let register = p.kind == .app ? Utterance.Register.chat : context.register
        return GatekeeperDecision(route: .dictate, register: register, routeConfidence: 1, registerConfidence: p.kind == .app ? 0.6 : 0,
                                  routeSource: .rules, registerSource: p.kind == .app ? .rules : .fallback)
    }

    /// Parse recorded by `preRoute` for this exact text (consumed once).
    public func takeParse(for text: String) -> WakeVerbParse? {
        lock.lock(); defer { lock.unlock() }
        return parses.removeValue(forKey: text)
    }
}

/// Strips the wake phrase from the spans (text → "", audioRange/confidence kept) so downstream
/// formatters see only the payload. Only acts when the pre-route recorded a parse for the utterance.
///
/// R4.1a: every returned span records that the stage ran, including the (overwhelmingly common)
/// pass-through where the session is not latched or the utterance carries no wake verb. Returning the input
/// array unchanged looked harmless but broke the `PipelineStage` contract — `ConfidenceContract`
/// read the missing provenance as "this stage invented spans", so `ContractEnforcingStage` logged a
/// violation on every dictation and fell back to the input, i.e. the stage could never ship a strip.
public struct WakeVerbStage: PipelineStage {
    public let id: StageID = .wakeVerb
    public let preRoute: WakeVerbPreRoute

    public init(preRoute: WakeVerbPreRoute) { self.preRoute = preRoute }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard WakeVerbPreRoute.isLatched(context), let p = preRoute.takeParse(for: spans.joinedText) ?? preRoute.grammar.parse(spans.joinedText) else { return spans.map { $0.touched(by: id) } }
        var remaining = p.verbTokenCount
        return spans.map { span in
            let words = WakeVerbGrammar.tokens(span.text).count
            guard remaining > 0, words > 0, span.confidence >= TranscriptSpan.lowConfidenceThreshold else { return span.touched(by: id) }
            let drop = min(words, remaining)
            remaining -= drop
            return span.rewritten(drop == words ? "" : WakeVerbGrammar.payload(span.text, dropping: drop), by: id)
        }
    }
}
