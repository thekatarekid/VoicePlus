import Foundation
import Shared

/// P2.6 — a deterministic check consulted *before* rules/Bayes. The first hook that returns a
/// decision wins; `nil` defers to the wrapped classifier. Used for exact-match snippet triggers,
/// which must beat every other route ("scratch that" may legitimately be a snippet trigger).
public protocol GatekeeperPreRouting: Sendable {
    func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision?
}

/// Wraps any `GatekeeperClassifying` with an ordered list of pre-route hooks. Drop-in for
/// `GatekeeperStage(local:)`; no other gatekeeper code changes.
public struct PreRoutingClassifier: GatekeeperClassifying {
    public let hooks: [any GatekeeperPreRouting]
    public let fallback: any GatekeeperClassifying

    public init(hooks: [any GatekeeperPreRouting], fallback: any GatekeeperClassifying = LocalGatekeeper.shared) {
        self.hooks = hooks
        self.fallback = fallback
    }

    public func classify(_ text: String, context: StageContext) -> GatekeeperDecision {
        let start = DispatchTime.now().uptimeNanoseconds
        for hook in hooks {
            if var d = hook.preRoute(text, context: context) {
                d.latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                return d
            }
        }
        return fallback.classify(text, context: context)
    }
}
