import Foundation
import Shared

/// One planner reply.
public enum PlannerTurn: Equatable, Sendable {
    case plan(StepPlan)
    case done(summary: String)
    case giveUp(reason: String)
}

/// Planning brain. Provider-backed implementations (local MLX or API via `Providers`) are injected at
/// integration; they receive the AX summary + tool vocabulary, never pixels.
public protocol PlannerLLM: Sendable {
    func plan(goal: String, observation: AXSummary, history: [StepRecord], tools: [AgentTool]) async throws -> PlannerTurn
}

/// Deterministic scripted planner for tests and the Lab: replays turns in order; the last turn repeats.
public final class ScriptedPlanner: PlannerLLM, @unchecked Sendable {
    private var turns: [PlannerTurn]
    private let lock = NSLock()
    public private(set) var calls: [(goal: String, observation: AXSummary, history: [StepRecord])] = []
    public var delay: Duration = .zero
    public init(_ turns: [PlannerTurn]) { self.turns = turns }
    public func plan(goal: String, observation: AXSummary, history: [StepRecord], tools: [AgentTool]) async throws -> PlannerTurn {
        if delay > .zero { try await Task.sleep(for: delay) }
        lock.lock(); defer { lock.unlock() }
        calls.append((goal, observation, history))
        guard !turns.isEmpty else { return .giveUp(reason: "script exhausted") }
        return turns.count > 1 ? turns.removeFirst() : turns[0]
    }
}

/// Builds the plan prompt for provider planners; kept here so every backend speaks the same contract.
public enum PlannerPrompt {
    public static func system(tools: [AgentTool]) -> String {
        "You control a macOS desktop through the accessibility tree. Tools:\n" +
        tools.map { "- \($0.kind.rawValue)(\($0.params.joined(separator: ", "))): \($0.description)" }.joined(separator: "\n") +
        "\nPlan a short ordered list of tool calls for the goal, or say it is done, or give up. Prefer reversible steps; never guess coordinates.\n" +
        PlannerJSON.contract   // V5 CU8: strict JSON, parsed with repair
    }
    public static func user(goal: String, observation: AXSummary, history: [StepRecord]) -> String {
        let h = history.map { "\($0.step.title): \($0.outcome)" }.joined(separator: "\n")
        return "goal: \(goal)\n\n\(observation.promptText)\n\nhistory:\n\(h.isEmpty ? "(none)" : h)"
    }
}

/// Why a planner could not produce a turn.
///
/// `unavailable` is a *configuration* state, not a failure: no provider is pinned for
/// `act.planner`, the pin points at something that isn't reachable, or the feature is off.
/// Nothing the user said went wrong, so the act path must report it in plain language and
/// must never let it take a dictation turn down with it.
public enum PlannerError: Error, Equatable, Sendable {
    case unavailable(reason: String)
}
