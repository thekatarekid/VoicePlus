import Actions
import Engine
import Foundation
import Pipeline
import Shared

// V5 O4 + L4 · builds the intent arbiter from the app's parts.
//
// Engine's `IntentArbiter` cannot import Pipeline or Actions, so the Layer 0 recognisers are adapted
// here: `WakeVerbGrammar` (type / send / app / note), `ActIntentParser` (deterministic or agentic act)
// and the local `GatekeeperStage` classifier (rule-matched repair / transform commands, questions).
// Layer 1 is the `DecisionModelRegistry`: the chosen model (`decide.model`, HW2 plan default) and its
// HW3 lighter alternative are registered with `ModelResidency` at launch — nothing loads until the
// first ambient utterance, and nothing downloads (`DecisionModelInstaller.install` is a user click).
// Every decision is settled on `UtteranceDecisionHub` as an `.arbiter` decision (Q13 log + recorder
// tags).

/// Layer 0 — the latched wake-verb grammar.
public struct WakeVerbDecider: ExplicitDecider {
    public let id = "wakeVerb"
    public let grammar: WakeVerbGrammar
    public init(grammar: WakeVerbGrammar = WakeVerbGrammar()) { self.grammar = grammar }

    public func decide(_ text: String) -> UtteranceDecision? {
        guard let parse = grammar.parse(text) else { return nil }
        switch parse.kind {
        case .type: return .explicit(.dictate, reason: "type")
        case .app: return .explicit(.dictate, reason: "app")
        case .send: return .explicit(.act, reason: "send")
        case .note: return .explicit(.note, reason: "note")
        }
    }
}

/// Layer 0 — the act-domain parser (only when the act domain is active; it is inert otherwise).
public struct ActIntentDecider: ExplicitDecider {
    public let id = "actIntent"
    public let parser: ActIntentParser
    public init(parser: ActIntentParser) { self.parser = parser }

    public func decide(_ text: String) -> UtteranceDecision? {
        guard let route = parser.preRoute(text, appBundleID: nil) else { return nil }
        return .explicit(.act, reason: route.isAgentic ? "agentic" : "deterministic")
    }
}

/// Layer 0 — the local gatekeeper, rule hits only (a Bayes guess is not "explicit"). Repair and
/// transform commands are edits; a rule-matched question is an ask. Dictation is never decided here.
public struct GatekeeperDecider: ExplicitDecider {
    public let id = "gatekeeper"
    public let classifier: any GatekeeperClassifying
    public init(classifier: any GatekeeperClassifying = LocalGatekeeper.shared) { self.classifier = classifier }

    public func decide(_ text: String) -> UtteranceDecision? {
        let d = classifier.classify(text, context: StageContext())
        guard d.routeSource == .rules else { return nil }
        switch d.route {
        case .repairCommand, .transform: return .explicit(.edit, reason: d.route.rawValue)
        case .question: return .explicit(.ask, reason: d.route.rawValue)
        case .dictate, .none: return nil
        }
    }
}

public enum ArbiterWiring {
    /// The Layer 0 recognisers, in precedence order.
    public static func layer0(actParser: ActIntentParser?) -> [any ExplicitDecider] {
        var out: [any ExplicitDecider] = [WakeVerbDecider()]
        if let actParser { out.append(ActIntentDecider(parser: actParser)) }
        out.append(GatekeeperDecider())
        return out
    }

    /// Registers the decision model(s) with the residency (HW1) and builds the arbiter. Decisions are
    /// settled on `hub` (Q13 + recorder tags).
    public static func make(settings: (any SettingsStore)?, actParser: ActIntentParser?,
                            residency: ModelResidency = .shared,
                            plan: ResidencyPlan = .for(.detect()),
                            hub: UtteranceDecisionHub = .app,
                            makeModel: @escaping (DecisionModelChoice) -> ResidentDecisionModel = {
                                ResidentDecisionModel.fluidUse($0)
                            }) async -> IntentArbiter {
        let choice = DecisionModelChoice.resolve(stored: settings?.string(DecisionModelChoice.settingsKey), plan: plan)
        let registry = DecisionModelRegistry(residency: residency, chosen: choice)
        await registry.install(choice, plan: plan, make: makeModel)
        let bandsStore = DecisionBandsSettings(settings: settings)
        let arbiter = IntentArbiter(layer0: layer0(actParser: actParser), registry: registry,
                                    bands: { bandsStore.bands })
        arbiter.onDecision = settle(on: hub)
        return arbiter
    }

    /// The `onDecision` that settles on the hub as the authoritative (`.arbiter`) decision.
    public static func settle(on hub: UtteranceDecisionHub) -> (UtteranceDecision, ArbiterInput) -> Void {
        { [weak hub] decision, input in
            hub?.settle(decision, utterance: input.utteranceID, range: input.range, source: .arbiter)
        }
    }
}

/// `DecisionBands`, persisted as JSON under `decide.bands` (O-b 5). Reads fresh every time, so a
/// "Not for you" nudge applies to the next utterance.
public final class DecisionBandsSettings: @unchecked Sendable {
    public static let key = "decide.bands"
    private weak var settings: (any SettingsStore)?
    private let lock = NSLock()

    public init(settings: (any SettingsStore)?) { self.settings = settings }

    public var bands: DecisionBands {
        lock.withLock {
            guard let json = settings?.string(Self.key), let data = json.data(using: .utf8),
                  let b = try? JSONDecoder().decode(DecisionBands.self, from: data), b.isValid else { return .defaults }
            return b
        }
    }

    public func save(_ bands: DecisionBands) {
        guard bands.isValid, let data = try? JSONEncoder().encode(bands) else { return }
        lock.withLock { settings?.set(String(decoding: data, as: UTF8.self), for: Self.key) }
    }

    /// "Not for you" in `app` (bundle id or name): raise that app's thresholds one step.
    public func notForYou(app: String) {
        var b = bands
        b.nudgeNotForYou(app: app)
        save(b)
    }
}

/// "Not for you" → per-app band nudge (O-b 5). Wraps whatever teacher `NotYouCorrection` already
/// feeds, and raises the frontmost app's thresholds when the user says an utterance was not for the
/// computer.
public final class BandNudgingTeacher: DirectedSpeechTeacher, @unchecked Sendable {
    private let inner: (any DirectedSpeechTeacher)?
    private let bands: DecisionBandsSettings
    private let frontmostApp: @Sendable () -> String?

    public init(inner: (any DirectedSpeechTeacher)?, bands: DecisionBandsSettings,
                frontmostApp: @escaping @Sendable () -> String?) {
        self.inner = inner; self.bands = bands; self.frontmostApp = frontmostApp
    }

    public func learn(_ example: DirectedSpeechExample) {
        inner?.learn(example)
        if example.label == .notDirected, example.reason == .notTalkingToYou, let app = frontmostApp() {
            bands.notForYou(app: app)
        }
    }
}
