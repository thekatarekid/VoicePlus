import Foundation
import Shared

/// Output of one pipeline run.
public struct PipelineResult: Sendable {
    public var spans: [TranscriptSpan]
    public var decision: GatekeeperDecision
    public var metrics: [StageMetrics]
    public var totalLatencyMs: Double
    public var text: String { spans.joinedText }
}

/// P1.7 T9/T10 — composes gatekeeper + stages. Every stage is wrapped in
/// `ContractEnforcingStage` (Bet 9 enforcement + instrumentation). Routing:
/// - `.none`            → spans returned untouched (nothing to type).
/// - `.dictate`         → gatekeeper → every applicable stage for the detected register.
/// - repair / transform / question → gatekeeper only; the caller dispatches to the repair
///   engine (P1.6) / transform engine (P2.x) using `decision`.
public final class PipelineRunner: @unchecked Sendable {
    public let gatekeeper: GatekeeperStage
    public let stages: [any PipelineStage]
    public let providers: any PipelineProviderRouting
    public let sink: any LabSink
    public let policy: ContractPolicy
    /// End-to-end budget from the build doc (≤ 250 ms local). Exceeding it only logs.
    public var budgetMs: Double = 250

    public init(
        gatekeeper: GatekeeperStage = GatekeeperStage(),
        stages: [any PipelineStage],
        providers: any PipelineProviderRouting = LocalOnlyProviderRouting(),
        sink: any LabSink = LogBufferLabSink(),
        policy: ContractPolicy = .fallbackToInput
    ) {
        self.gatekeeper = gatekeeper
        self.stages = stages
        self.providers = providers
        self.sink = sink
        self.policy = policy
    }

    /// Runner over everything in `StageRegistry.allStages()` (gatekeeper always runs first).
    public static func standard(providers: any PipelineProviderRouting = LocalOnlyProviderRouting(),
                                sink: any LabSink = LogBufferLabSink()) -> PipelineRunner {
        let stages = StageRegistry.allStages().filter { $0.id != StageID.gatekeeper }
        return PipelineRunner(stages: stages, providers: providers, sink: sink)
    }

    public func run(_ input: [TranscriptSpan], context: StageContext) async throws -> PipelineResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let collector = CollectingLabSink()
        let fanout = MultiLabSink([collector, sink])

        let decision = await gatekeeper.decide(input, context: context, providers: providers)
        var spans = try await ContractEnforcingStage(gatekeeper, policy: policy, sink: fanout).process(input, context: context)

        var stageContext = context
        stageContext.register = decision.register
        stageContext.extra["gatekeeper.route"] = decision.route.rawValue
        stageContext.extra["gatekeeper.confidence"] = String(decision.routeConfidence)

        if decision.route == .dictate {
            for stage in stages {
                spans = try await ContractEnforcingStage(stage, policy: policy, sink: fanout).process(spans, context: stageContext)
            }
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if total > budgetMs { Log.pipeline.warning("pipeline over budget: \(String(format: "%.1f", total))ms > \(budgetMs)ms") }
        return PipelineResult(spans: spans, decision: decision, metrics: collector.all, totalLatencyMs: total)
    }
}
