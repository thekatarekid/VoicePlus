import Engine
import Foundation
import Shared

// V5 L2 + L4 · ambient speech → mode command → intent arbiter → guarantees → Notes or capability.
//
// Runs on every ambient utterance the capture gate kept (Layer 1 on every ambient utterance, §L4).
// The arbiter settles its decision on the O3 hub (Q13 + recorder tags); this pipeline then asks
// `AmbientGuarantees` where the words may go. Only a `.deliver` disposition reaches `deliver`, and only
// in Listen & act. Since V5 L3 the speaker verdict comes with the utterance (`AmbientListener` runs
// `SpeakerGate.verdict(for:embedder:)` on the segment's own samples); the `verdict` closure is only the
// fallback for callers that have no samples (it defaults to `.unknown`, which notes and delivers nothing).

/// Hands an ambient utterance to a capability (dictate / edit / act / ask). Implemented by the
/// composition root once L3/CU land; nil means nothing is delivered.
public protocol AmbientDelivering: AnyObject, Sendable {
    func deliver(_ text: String, owner: UtteranceOwner, decision: UtteranceDecision) async
}

public final class AmbientDecisionPipeline: @unchecked Sendable {
    public let mode: AmbientModeController
    private let arbiter: () -> IntentArbiter?
    private let verdict: () -> SpeakerGate.Verdict
    private let context: (String) -> DecisionState
    /// Stores a note; true when stored. (`NotesRouter` in the app.)
    public var note: ((String, UtteranceDecision) -> Bool)?
    public weak var delivery: (any AmbientDelivering)?
    /// Told about every handled utterance (pill / diagnostics / tests).
    public var onDisposition: ((AmbientDisposition, UtteranceDecision?) -> Void)?

    private let lock = NSLock()
    private var history: [DecisionHistoryItem] = []

    public init(mode: AmbientModeController,
                arbiter: @escaping () -> IntentArbiter?,
                verdict: @escaping () -> SpeakerGate.Verdict,
                context: @escaping (String) -> DecisionState = { DecisionState(utterance: $0) }) {
        self.mode = mode; self.arbiter = arbiter; self.verdict = verdict; self.context = context
    }

    @discardableResult
    public func handle(_ text: String, utteranceID: String, range: ClosedRange<Date>,
                       verdict heard: SpeakerGate.Verdict? = nil) async -> AmbientDisposition {
        let current = mode.mode
        guard current.listens else { return report(.recordOnly(.modeOff), nil) }
        let voice = heard ?? verdict()
        // Spoken mode switches: anyone may turn listening down; only the user may turn acting back on.
        if let wanted = AmbientModeVoiceCommand.parse(text), wanted != .listenAndAct || voice.isUser {
            mode.set(wanted)
            return report(.recordOnly(.modeCommand), nil)
        }
        guard let arbiter = arbiter() else { return report(.recordOnly(.ignored), nil) }
        var state = context(text)
        state.utterance = text
        state.history = lock.withLock { history }
        // `evaluate`, not `decide`: the arbiter's own Layer 2 handoff is never used for ambient speech —
        // everything leaves through the guarantees below. The decision is still reported (hub, Q13).
        let input = ArbiterInput(utteranceID: utteranceID, range: range, state: state)
        let decision = await arbiter.evaluate(input).decision
        arbiter.onDecision?(decision, input)
        lock.withLock {
            history.append(DecisionHistoryItem(text: text, owner: decision.owner))
            if history.count > DecisionState.historyLimit { history.removeFirst(history.count - DecisionState.historyLimit) }
        }
        let disposition = AmbientGuarantees.disposition(mode: mode.mode, verdict: voice, decision: decision, text: text)
        switch disposition {
        case .note:
            _ = note?(text, decision)
        case .deliver(let owner):
            await delivery?.deliver(text, owner: owner, decision: decision)
        case .recordOnly:
            break
        }
        return report(disposition, decision)
    }

    private var chain: Task<Void, Never>?

    /// Queues `handle` behind every earlier utterance (decisions stay in speaking order; history is
    /// the previous utterances'). The transcript seam is synchronous, so this is how it calls in.
    public func enqueue(_ text: String, utteranceID: String, range: ClosedRange<Date>,
                        verdict heard: SpeakerGate.Verdict? = nil) {
        lock.withLock {
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                await self?.handle(text, utteranceID: utteranceID, range: range, verdict: heard)
            }
        }
    }

    /// Waits for every queued utterance (tests, shutdown).
    public func settle() async {
        while let task = lock.withLock({ chain }) {
            await task.value
            if lock.withLock({ chain }) == task { return }
        }
    }

    private func report(_ d: AmbientDisposition, _ decision: UtteranceDecision?) -> AmbientDisposition {
        onDisposition?(d, decision)
        return d
    }
}
