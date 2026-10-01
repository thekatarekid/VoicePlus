import Foundation

// MARK: - V5 CU4 / CU9 · CUA-S1 as the act router's single-step chooser
//
// `ActRouter` asks for one (element, action) per utterance and ends the turn right after the
// decision. With the 16 GB plan the 4B is `.exclusive`: it loads for the act turn and is unloaded
// when the turn ends, so it never sits beside the 4B planner or another exclusive model (CU9).
// With the ≥ 24 GB plan it is kept warm (`keepWarm`), and the idle sweeper unloads it eventually.

public final class CuaS1SingleStep: SingleStepChoosing, @unchecked Sendable {
    public let chooser: CuaS1Chooser
    public let resident: ResidentCuaS1?
    /// ≥ 24 GB plan: leave the model loaded between act turns.
    public let keepWarm: Bool

    public init(chooser: CuaS1Chooser, resident: ResidentCuaS1?, keepWarm: Bool) {
        self.chooser = chooser
        self.resident = resident
        self.keepWarm = keepWarm
    }

    public func choose(goal: String, observation: AXSummary) async throws -> CuaS1Choice {
        try await chooser.choose(goal: goal, observation: observation)
    }

    public func endTurn() async {
        guard !keepWarm else { return }
        await resident?.release()
    }
}
