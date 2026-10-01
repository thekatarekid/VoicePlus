import Foundation
import Engine
import Shared

/// V5 O2 + O3 — where the one decision per utterance is settled.
///
/// Whoever decides what an utterance is — lane 5b's `IntentArbiter` (`.arbiter`), or until it lands
/// the landing route (`.landing`, derived in `decision(for:)`) — hands the decision here. The hub:
///
/// 1. keeps it to **one decision per utterance**: a second decision for the same utterance id is
///    dropped, and a provisional landing-derived decision is dropped when an arbiter decision
///    already covers an overlapping stretch of time (the arbiter is the authority, §10);
/// 2. logs it to Q13 diagnostics (`TurnDiagnosticsEvent.decision`) — owner, confidence, band, reason
///    code, question probabilities; never text;
/// 3. fans an `UtteranceTag` out to every running **recorder** (meeting session, ambient timeline)
///    so each renders the span it already holds as "dictated" / "command" / "note" (O2).
///
/// Thread-safe. Recorders are held weakly and keyed, so re-registering (a second container in
/// tests, a new meeting coordinator) replaces rather than accumulates.
public final class UtteranceDecisionHub: @unchecked Sendable {
    /// Who produced a decision.
    public enum Source: String, Sendable {
        /// The intent arbiter (5b). Authoritative.
        case arbiter
        /// Derived from the landing route, before / without an arbiter. Provisional.
        case landing
    }

    /// The app's hub. `AppContainer` registers the recorders and the diagnostics sink on it;
    /// `SessionCoordinator` settles landings on it by default.
    public static let app = UtteranceDecisionHub()

    /// Q13 sink: (event, turn id). Set by the composition root; nil drops diagnostics.
    public var diagnostics: ((TurnDiagnosticsEvent, String) -> Void)? {
        get { lock.withLock { _diagnostics } }
        set { lock.withLock { _diagnostics = newValue } }
    }
    /// Every settled decision with its tag (pill / notes / tests).
    public var onSettled: ((UtteranceDecision, UtteranceTag) -> Void)? {
        get { lock.withLock { _onSettled } }
        set { lock.withLock { _onSettled = newValue } }
    }

    private struct WeakRecorder { weak var value: (any UtteranceTagRecording)? }
    private struct Settled { var id: String; var source: Source; var range: ClosedRange<Date> }

    private let lock = NSLock()
    private var _diagnostics: ((TurnDiagnosticsEvent, String) -> Void)?
    private var _onSettled: ((UtteranceDecision, UtteranceTag) -> Void)?
    private var recorders: [String: WeakRecorder] = [:]
    private var settled: [Settled] = []
    /// How many settled utterances are remembered for the one-decision rule.
    static let memory = 256

    public init() {}

    // MARK: Recorders

    /// Registers (or with nil, removes) the recorder under `key` ("meeting", "ambient").
    public func setRecorder(_ recorder: (any UtteranceTagRecording)?, for key: String) {
        lock.withLock { recorders[key] = recorder.map { WeakRecorder(value: $0) } }
    }

    public var recorderKeys: [String] {
        lock.withLock { recorders.filter { $0.value.value != nil }.keys.sorted() }
    }

    // MARK: Settling

    /// Settles `decision` for utterance `id`, spoken over `range` (wall clock). Returns false when
    /// the utterance already had its one decision. `turn` names the Q13 row (defaults to `id`).
    @discardableResult
    public func settle(_ decision: UtteranceDecision, utterance id: String, range: ClosedRange<Date>,
                       source: Source = .arbiter, turn: String? = nil) -> Bool {
        let (accepted, sinks, log, observer) = lock.withLock { () -> (Bool, [any UtteranceTagRecording], ((TurnDiagnosticsEvent, String) -> Void)?, ((UtteranceDecision, UtteranceTag) -> Void)?) in
            if settled.contains(where: { $0.id == id }) { return (false, [], nil, nil) }
            if source == .landing, settled.contains(where: { $0.source == .arbiter && Self.overlaps($0.range, range) }) {
                return (false, [], nil, nil)
            }
            settled.append(Settled(id: id, source: source, range: range))
            if settled.count > Self.memory { settled.removeFirst(settled.count - Self.memory) }
            recorders = recorders.filter { $0.value.value != nil }
            return (true, recorders.keys.sorted().compactMap { recorders[$0]?.value }, _diagnostics, _onSettled)
        }
        guard accepted else { return false }
        log?(.decision(Self.diagnosticsDecision(decision, source: source)), turn ?? id)
        let tag = UtteranceTag(utteranceID: id, owner: decision.owner, range: range)
        if decision.owner != .ignore { sinks.forEach { $0.record(tag) } }
        observer?(decision, tag)
        return true
    }

    static func overlaps(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }

    /// O3 → Q13: the decision as the diagnostics store records it. The reason code is prefixed with
    /// its source so a provisional decision is never mistaken for the arbiter's.
    public static func diagnosticsDecision(_ d: UtteranceDecision, source: Source = .arbiter) -> TurnDiagnosticsEvent.Decision {
        TurnDiagnosticsEvent.Decision(owner: d.owner.rawValue, confidence: d.confidence, band: d.band?.rawValue,
                                      reason: "\(source.rawValue):\(d.reason)",
                                      questionProbabilities: d.questionProbabilities)
    }

    // MARK: Provisional decisions from the landing route

    /// What a landing says the utterance was, when no arbiter decided. Every hold-to-talk landing is
    /// Layer 0 (the user pressed the key): confidence 1.
    public static func decision(for landing: LandingResult) -> UtteranceDecision {
        if landing.transform != nil { return .explicit(.edit, reason: "transform") }
        switch landing.route {
        case .dictate: return .explicit(.dictate, reason: "route.dictate")
        case .repairCommand: return .explicit(.edit, reason: "route.repairCommand")
        case .transform: return .explicit(.edit, reason: "route.transform")
        case .question: return .explicit(.ask, reason: "route.question")
        // A route-.none landing is an act or note claim, or fillers only; the claimant (act session,
        // NotesRouter) does not reach this layer, so it stays `ignore` until the arbiter decides.
        case .none: return .explicit(.ignore, reason: "route.none")
        }
    }
}
