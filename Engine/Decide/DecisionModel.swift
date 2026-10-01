import Foundation
import Shared

// V5 O4 · Layer 1 behind one protocol, so any model swaps by §V result.
//
// `DecisionModel.decide(state:questions:)` answers every question about one state in one call.
// The three FluidUse families (Kev, Intern-Decision, Laya) implement it in
// `FluidUseDecisionModels.swift`; tests use a mock. Which one runs is `DecisionModelChoice` (setting
// `decide.model`, default Kev); HW2 picks Laya on an 8 GB Mac and HW3 swaps Kev → Laya under critical
// memory pressure through `ModelResidency.preferredKey(for:)`.

public protocol DecisionModel: Sendable {
    /// Stable id logged in the decision reason ("kev", "intern", "laya", "mock").
    var id: String { get }
    /// One call: every question about `state`. Answers keyed per `DecisionQuestion.Kind`
    /// (`"no"`/`"yes"`, or capability owner raw values).
    func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers
}

public enum DecisionModelError: Error, Equatable, Sendable {
    /// The weights are not on this Mac (nothing downloads implicitly).
    case notInstalled(String)
    /// The model answered in a shape we do not understand.
    case invalidOutput(String)
}

/// Which Layer 1 model decides. Raw values persist under `DecisionModelChoice.settingsKey`.
public enum DecisionModelChoice: String, CaseIterable, Codable, Sendable {
    /// Kev-0.8B CoreML (FluidUse `KevFastManager`, GPU) — first candidate.
    case kev
    /// Intern-Decision-0.8B CoreML.
    case intern
    /// Laya (multilingual mmBERT, e8) — the light model; HW2/HW3 fallback.
    case laya

    public static let settingsKey = "decide.model"
    public static let `default`: DecisionModelChoice = .kev

    /// The residency key this choice registers under.
    public var residencyKey: String {
        switch self {
        case .kev: return ResidencyKey.decisionKev
        case .intern: return DecisionResidencyKey.intern
        case .laya: return ResidencyKey.decisionLaya
        }
    }

    public init?(residencyKey: String) {
        guard let c = Self.allCases.first(where: { $0.residencyKey == residencyKey }) else { return nil }
        self = c
    }

    public var displayName: String {
        switch self {
        case .kev: return "Kev"
        case .intern: return "Intern-Decision"
        case .laya: return "Laya"
        }
    }

    /// Approximate resident size with the buckets we load (HW1 budget arithmetic).
    public var estimatedBytes: Int64 {
        switch self {
        case .kev: return 1_700_000_000
        case .intern: return 1_500_000_000
        case .laya: return 700_000_000
        }
    }

    /// The stored choice, or the HW2 plan's default for this Mac (Laya on 8 GB, Kev otherwise).
    /// A stored heavy choice on a Mac whose plan cannot hold it falls back to the plan's model.
    public static func resolve(stored: String?, plan: ResidencyPlan) -> DecisionModelChoice {
        let planned = DecisionModelChoice(residencyKey: plan.decisionKey) ?? .default
        guard let stored, let choice = DecisionModelChoice(rawValue: stored) else { return planned }
        if planned == .laya, choice != .laya { return .laya }
        return choice
    }
}

/// Residency keys `ResidencyPlan` does not name (it names Kev and Laya).
public enum DecisionResidencyKey {
    public static let intern = "decide.intern-0.8b"
}
