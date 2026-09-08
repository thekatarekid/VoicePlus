import Foundation
import Testing
@testable import Actions

/// Regression cover for 1.7.9's "dictation shows an error instead of text".
///
/// A dictation turn reached the act planner (see `ActKeyCollisionTests` for how), the planner
/// threw `disabled(stage: act.planner)` because no provider was pinned, and the pill showed
/// `Agent: failed(reason: "planner: disabled(stage: act.planner)")`.
///
/// Two rules are enforced here: an unconfigured planner is a *state*, not a failure; and no
/// status may ever hand the UI a debug description.
@Suite("planner unavailable never becomes a user-visible failure")
struct PlannerUnavailableTests {
    static let catalog = try! ActionCatalog.load()

    /// Planner that behaves the way `ProviderPlanner` does when nothing is pinned for the stage.
    struct UnconfiguredPlanner: PlannerLLM {
        let error: any Error
        func plan(goal: String, observation: AXSummary, history: [StepRecord],
                  tools: [AgentTool]) async throws -> PlannerTurn {
            throw error
        }
    }

    func agent(throwing error: any Error) -> NativeAgentBackend {
        let sys = DeterministicMockApps.desktop(catalog: Self.catalog, front: "com.apple.Safari")
        return NativeAgentBackend(planner: UnconfiguredPlanner(error: error),
                                  executor: ActionExecutor(system: sys), consent: ConsentEngine())
    }

    @Test("an unconfigured planner reports .unavailable, not .failed")
    func unavailableIsAState() async {
        let report = await agent(throwing: PlannerError.unavailable(reason: "no provider chosen for act.planner"))
            .run(goal: "buy milk on the way home")
        #expect(report.status == .unavailable(reason: "no provider chosen for act.planner"))
        if case .failed = report.status { Issue.record("a disabled stage must never read as a failure") }
    }

    @Test("a genuinely broken planner still fails, but without the error's debug text")
    func realFailuresCarryNoDebugText() async {
        struct Boom: Error { let secret = "disabled(stage: act.planner)" }
        let report = await agent(throwing: Boom()).run(goal: "do the thing")
        guard case .failed(let reason) = report.status else {
            Issue.record("expected a failure for a non-configuration error")
            return
        }
        #expect(!reason.contains("Boom"))
        #expect(!reason.contains("stage:"))
    }

    @Test("no status can leak a raw failed(reason:) / stage id into the pill")
    func userMessagesArePlainLanguage() {
        let statuses: [AgentRunStatus] = [
            .completed(summary: "opened the PR tab"),
            .completed(summary: "   "),
            .stopped, .timedOut, .declined,
            .failed(reason: "planner: disabled(stage: act.planner)"),
            .gaveUp(reason: "planner reply had no parseable steps"),
            .unavailable(reason: "no provider chosen for act.planner"),
        ]
        for status in statuses {
            let message = status.userMessage
            #expect(!message.isEmpty)
            // The exact shapes that leaked in 1.7.9, plus the generic debug-description markers.
            for forbidden in ["failed(", "reason:", "disabled(", "stage:", "act.planner", "Error", "(stage"] {
                #expect(!message.contains(forbidden), "\(status) leaked \"\(forbidden)\" as \"\(message)\"")
            }
            // `String(describing:)` of a payload case always contains the case name and a paren.
            #expect(message != String(describing: status))
        }
        #expect(AgentRunStatus.completed(summary: "   ").userMessage == "Done")
        #expect(AgentRunStatus.unavailable(reason: "x").userMessage.lowercased().contains("settings"))
    }

    @Test("the report exposes the same plain message the pill shows")
    func reportForwardsTheMessage() async {
        let report = await agent(throwing: PlannerError.unavailable(reason: "no provider chosen for act.planner"))
            .run(goal: "g")
        #expect(report.userMessage == report.status.userMessage)
        #expect(!report.userMessage.contains("act.planner"))
    }
}
