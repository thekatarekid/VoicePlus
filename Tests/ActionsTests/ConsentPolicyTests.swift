import Foundation
import Testing
@testable import Actions

/// V5 CU1 — consent defaults can only make handling stricter; irreversible always asks.
@Suite("CU1 consent policy")
struct ConsentPolicyTests {
    @Test("defaults: reversible runs, semi offers undo, irreversible asks")
    func defaults() {
        let p = ConsentPolicy.default
        #expect(p.effective(.reversible) == .reversible)
        #expect(p.effective(.semi) == .semi)
        #expect(p.effective(.irreversible) == .irreversible)
    }

    @Test("no combination of settings ever lowers a class")
    func neverLowers() {
        for r in ConsentPolicy.ReversibleHandling.allCases {
            for s in ConsentPolicy.SemiHandling.allCases {
                let p = ConsentPolicy(reversible: r, semi: s)
                for c in [Reversibility.reversible, .semi, .irreversible] {
                    #expect(p.effective(c).rank >= c.rank)
                }
                #expect(p.effective(.irreversible) == .irreversible)
            }
        }
    }

    @Test("ask-first for reversible actions makes the engine wait for confirmation")
    func engineHonoursPolicy() async throws {
        let engine = ConsentEngine()
        engine.policy = ConsentPolicy(reversible: .confirm, semi: .confirm)
        let ran = PolicyCounter()
        let (token, outcome) = try await engine.submit(ConsentRequest(id: "scroll.down", category: .scroll)) { _ in
            ran.hit(); return ExecutionReceipt()
        }
        if case .awaitingConfirmation = outcome {} else { Issue.record("expected a card, got \(outcome)") }
        #expect(ran.count == 0)
        _ = try await engine.confirm(token)
        #expect(ran.count == 1)
    }

    @Test("undo-toast for reversible actions runs and offers undo")
    func undoToastPolicy() async throws {
        let engine = ConsentEngine()
        engine.policy = ConsentPolicy(reversible: .undoToast)
        let (_, outcome) = try await engine.submit(ConsentRequest(id: "scroll.down", category: .scroll)) { _ in ExecutionReceipt() }
        if case .executedWithUndo = outcome {} else { Issue.record("expected an undo toast, got \(outcome)") }
    }

    @Test("plan chips off: only confirmation phases reach the pill")
    func chipsOff() async {
        let planner = ScriptedPlanner([.done(summary: "ok")])
        let agent = NativeAgentBackend(planner: planner, executor: ActionExecutor(system: MockActionSystem()),
                                       consent: ConsentEngine())
        agent.showsPlanChips = false
        let seen = PolicyCounter()
        agent.onChips = { _ in seen.hit() }
        _ = await agent.run(goal: "nothing to do")
        #expect(seen.count == 0)
        agent.showsPlanChips = true
        _ = await agent.run(goal: "nothing to do")
        #expect(seen.count > 0)
    }
}

final class PolicyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
