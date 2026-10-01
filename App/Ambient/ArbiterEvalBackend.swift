import Engine
import Foundation
import Lab
import Shared

// V5 L6 — the decision layer as a V1 eval backend: `lab eval --set ambient-commands --stage decide
// --model decide-kev` (or `ami-decide`, `notsofar1-decide`). Text in (`input` or `reference`), the
// arbiter's owner out as the label; accuracy is scored by `PublicEval` per condition tag (one tag per
// capability on the scripted set).
//
// The arbiter is evaluated (`IntentArbiter.evaluate`): nothing is reported to the hub and no Layer 2
// handoff runs. Layer 1 models are registered with `ModelResidency` through `DecisionModelRegistry`,
// exactly as the app does (HW1), and are never downloaded here — a model that is not installed answers
// `ignore` (`layer1.<id>.unavailable`), which the report's per-item labels make visible.

public final class ArbiterEvalBackend: EvalBackend, @unchecked Sendable {
    public let modelID: String
    private let make: @Sendable () async -> IntentArbiter
    private let lock = NSLock()
    private var arbiter: IntentArbiter?

    public init(modelID: String, make: @escaping @Sendable () async -> IntentArbiter) {
        self.modelID = modelID; self.make = make
    }

    public func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput {
        guard stage == .decide else { throw EvalError.stageUnsupported("\(modelID) does \(EvalStage.decide.rawValue) only") }
        let arbiter: IntentArbiter
        if let built = lock.withLock({ self.arbiter }) { arbiter = built }
        else {
            arbiter = await make()
            lock.withLock { self.arbiter = arbiter }
        }
        let text = item.input ?? item.reference
        let now = Date()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = await arbiter.evaluate(ArbiterInput(utteranceID: item.id, range: now...now, state: DecisionState(utterance: text)))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        return EvalOutput(text: result.decision.reason, label: result.decision.owner.rawValue, latencyMs: ms,
                          metrics: ["confidence": result.decision.confidence, "layer": Double(result.layer.rawValue)])
    }

    /// Model ids: `decide-layer0` (explicit recognisers only, no model) and `decide-<choice>` per
    /// `DecisionModelChoice` (Layer 0 + that Layer 1 model).
    public static func register(_ registry: inout LabRegistry, residency: ModelResidency = .shared) {
        registry.evalBackends["decide-layer0"] = {
            ArbiterEvalBackend(modelID: "decide-layer0") {
                IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), model: { nil })
            }
        }
        for choice in DecisionModelChoice.allCases {
            let id = "decide-\(choice.rawValue)"
            registry.evalBackends[id] = {
                ArbiterEvalBackend(modelID: id) {
                    let plan = ResidencyPlan.for(.detect())
                    let models = DecisionModelRegistry(residency: residency, chosen: choice)
                    await models.install(choice, plan: plan, make: { ResidentDecisionModel.fluidUse($0) })
                    return IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), registry: models)
                }
            }
        }
    }
}
