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
    /// The value `modeKey` carries while the session is latched. V5 K20 retired the last
    /// `handsFree` wire value: writers now put `"latched"`.
    public static let latchedValue = "latched"
    /// One-release read-compat alias (V5 K20): a context written by a pre-K20 build still says
    /// `"handsFree"`; `isLatched` accepts it. Never written. Remove after the next release.
    public static let legacyLatchedValue = "handsFree"
    public let grammar: WakeVerbGrammar
    public let hints: WakeVerbHintModel
    private let lock = NSLock()
    private var parses: [String: WakeVerbParse] = [:]
    private var noteClaimed = false
    /// V5 N2 — where a latched "note …" goes. Returns true when the payload was stored; the
    /// utterance is then claimed (route `.none`, never typed — `consumeNoteClaim`). With no sink, or
    /// when the sink declines, a note phrase is not a wake verb at all: the words are typed verbatim
    /// (never stripped), exactly as before N2 ("note that the meeting moved" stays a sentence).
    public var noteSink: (@Sendable (WakeVerbParse) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return _noteSink }
        set { lock.lock(); _noteSink = newValue; lock.unlock() }
    }
    private var _noteSink: (@Sendable (WakeVerbParse) -> Bool)?

    public init(grammar: WakeVerbGrammar = WakeVerbGrammar(), hints: WakeVerbHintModel = WakeVerbHintModel()) {
        self.grammar = grammar; self.hints = hints
    }

    public static func isLatched(_ context: StageContext) -> Bool {
        guard let value = context.extra[modeKey] else { return false }
        return value == latchedValue || value == legacyLatchedValue
    }

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard Self.isLatched(context), let p = grammar.parse(text) else { return nil }
        if p.kind == .note {
            guard let sink = noteSink, sink(p) else { return nil }
            lock.lock(); noteClaimed = true; lock.unlock()
            hints.recordUse()
            return GatekeeperDecision(route: .none, register: context.register, routeConfidence: 1, registerConfidence: 0,
                                      routeSource: .rules, registerSource: .fallback)
        }
        lock.lock(); parses[text] = p; lock.unlock()
        hints.recordUse()
        let register = p.kind == .app ? Utterance.Register.chat : context.register
        return GatekeeperDecision(route: .dictate, register: register, routeConfidence: 1, registerConfidence: p.kind == .app ? 0.6 : 0,
                                  routeSource: .rules, registerSource: p.kind == .app ? .rules : .fallback)
    }

    /// V5 N2 — true once after `preRoute` stored a "note …" utterance in Notes (the lander's claim
    /// consumer: the words are never typed).
    public func consumeNoteClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = noteClaimed
        noteClaimed = false
        return was
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
        guard WakeVerbPreRoute.isLatched(context), let p = preRoute.takeParse(for: spans.joinedText) ?? preRoute.grammar.parse(spans.joinedText),
              p.kind != .note   // V5 N2: a note phrase is claimed by the pre-route or typed verbatim, never stripped
        else { return spans.map { $0.touched(by: id) } }
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
