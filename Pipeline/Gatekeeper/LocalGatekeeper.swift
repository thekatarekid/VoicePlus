import Foundation
import Shared

/// P1.7 T1 — deterministic, feature-based gatekeeper: keyword/grammar rules first, a
/// naive-Bayes model over the built-in seed corpus for the rest. Falls back to `.dictate`
/// below `routeThreshold`. Runs in microseconds (budget ≤ 15 ms).
public struct LocalGatekeeper: GatekeeperClassifying {
    public static let shared = LocalGatekeeper()

    public var routeThreshold: Double = 0.6
    public var registerThreshold: Double = 0.55
    /// Commands, transforms and questions are short. Past this many words the Bayes route
    /// model is not consulted (its posterior saturates on long narration — P1.12 chaos finding);
    /// long utterances are dictation unless an explicit rule fires.
    public static let maxCommandWords = 40

    private let routeModel: NaiveBayesClassifier<Utterance.Route>
    private let registerModel: NaiveBayesClassifier<Utterance.Register>

    public init(routeThreshold: Double = 0.6, registerThreshold: Double = 0.55) {
        self.routeThreshold = routeThreshold
        self.registerThreshold = registerThreshold
        routeModel = NaiveBayesClassifier(examples: GatekeeperSeedCorpus.routes)
        registerModel = NaiveBayesClassifier(examples: GatekeeperSeedCorpus.registers)
    }

    public func classify(_ text: String, context: StageContext) -> GatekeeperDecision {
        let start = DispatchTime.now().uptimeNanoseconds
        let words = GatekeeperTokenizer.words(text)

        var route: Utterance.Route
        var routeConf: Float
        var routeSource: GatekeeperDecision.Source
        if let hit = RouteRules.evaluate(words) {
            route = hit.route; routeConf = hit.confidence; routeSource = .rules
        } else if words.count <= Self.maxCommandWords, let best = routeModel.best(text), best.probability >= routeThreshold {
            route = best.label; routeConf = Float(best.probability); routeSource = .bayes
        } else {
            route = .dictate; routeConf = Float(routeModel.posterior(text)?[.dictate] ?? 0); routeSource = .fallback
        }
        // Commands and transforms are disabled when voice repair is flagged off: everything is dictation.
        if route == .repairCommand, !context.isEnabled(.voiceRepair) { route = .dictate; routeSource = .fallback }

        let (register, regConf, regSource) = classifyRegister(text, context: context)
        let latency = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return GatekeeperDecision(route: route, register: register, routeConfidence: routeConf, registerConfidence: regConf,
                                  routeSource: routeSource, registerSource: regSource, latencyMs: latency)
    }

    func classifyRegister(_ text: String, context: StageContext) -> (Utterance.Register, Float, GatekeeperDecision.Source) {
        if context.register != .unknown { return (context.register, 1, .context) }
        if let bundle = context.appBundleID?.lowercased(), let reg = GatekeeperSeedCorpus.bundleRegisters[bundle] {
            return (reg, 0.9, .context)
        }
        if let best = registerModel.best(text), best.probability >= registerThreshold {
            return (best.label, Float(best.probability), .bayes)
        }
        return (.unknown, 0, .fallback)
    }
}

/// The `PipelineStage` face of the gatekeeper. `process` only stamps provenance (the
/// gatekeeper never rewrites text); `decide` returns the routing decision the runner uses.
public struct GatekeeperStage: PipelineStage {
    public let id: StageID = .gatekeeper
    public let local: any GatekeeperClassifying
    /// Optional provider-backed classifier (T10). Consulted only when the provider hook says
    /// the gatekeeper stage is enabled; any failure or `nil` defers to `local`.
    public let provider: (any ProviderGatekeeperClassifying)?
    /// Hard budget from the build doc; exceeding it logs and forces the fallback decision.
    public var budgetMs: Double = 15

    public init(local: any GatekeeperClassifying = LocalGatekeeper.shared, provider: (any ProviderGatekeeperClassifying)? = nil) {
        self.local = local
        self.provider = provider
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        spans.map { $0.touched(by: id) }
    }

    /// Synchronous local decision.
    public func decide(_ spans: [TranscriptSpan], context: StageContext) -> GatekeeperDecision {
        var decision = local.classify(spans.joinedText, context: context)
        if decision.latencyMs > budgetMs {
            Log.pipeline.warning("gatekeeper over budget: \(decision.latencyMs)ms; falling back to dictate")
            let register = decision.register
            decision = .fallback(register: register)
        }
        return decision
    }

    /// Decision with the optional provider hook in front of the local classifier.
    public func decide(_ spans: [TranscriptSpan], context: StageContext, providers: any PipelineProviderRouting) async -> GatekeeperDecision {
        if let provider, providers.isProviderEnabled(for: id, context: context) {
            let start = DispatchTime.now().uptimeNanoseconds
            if var d = try? await provider.classify(spans.joinedText, context: context) {
                d.latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                d.routeSource = .provider
                return d
            }
        }
        return decide(spans, context: context)
    }
}
