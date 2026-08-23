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
        "\nReply with a short ordered plan of tool calls, DONE <summary>, or GIVEUP <reason>. Prefer reversible steps; never guess coordinates."
    }
    public static func user(goal: String, observation: AXSummary, history: [StepRecord]) -> String {
        let h = history.map { "\($0.step.title): \($0.outcome)" }.joined(separator: "\n")
        return "goal: \(goal)\n\n\(observation.promptText)\n\nhistory:\n\(h.isEmpty ? "(none)" : h)"
    }
}
