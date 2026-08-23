import Foundation
import Shared

public extension StageID {
    /// P5.2 — wake-verb stripping.
    static let wakeVerb: StageID = "wakeVerb"
}

/// P5.2 — `GatekeeperPreRouting` hook. Active only in hands-free mode
/// (`context.extra[WakeVerbPreRoute.modeKey] == "handsFree"`). Records the parse for the stage and
/// bumps the usage counter that drives the in-pill hint.
public final class WakeVerbPreRoute: GatekeeperPreRouting, @unchecked Sendable {
    public static let modeKey = "input.mode"
    public static let handsFreeValue = "handsFree"
    public let grammar: WakeVerbGrammar
    public let hints: WakeVerbHintModel
    private let lock = NSLock()
    private var parses: [String: WakeVerbParse] = [:]

    public init(grammar: WakeVerbGrammar = WakeVerbGrammar(), hints: WakeVerbHintModel = WakeVerbHintModel()) {
        self.grammar = grammar; self.hints = hints
    }

    public static func isHandsFree(_ context: StageContext) -> Bool {
        context.extra[modeKey] == handsFreeValue
    }

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard Self.isHandsFree(context), let p = grammar.parse(text) else { return nil }
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
public struct WakeVerbStage: PipelineStage {
    public let id: StageID = .wakeVerb
    public let preRoute: WakeVerbPreRoute

    public init(preRoute: WakeVerbPreRoute) { self.preRoute = preRoute }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard WakeVerbPreRoute.isHandsFree(context), let p = preRoute.takeParse(for: spans.joinedText) ?? preRoute.grammar.parse(spans.joinedText) else { return spans }
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
