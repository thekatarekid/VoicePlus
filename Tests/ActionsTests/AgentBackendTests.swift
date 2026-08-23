import Foundation
import Testing
@testable import Actions

@Suite("P4.5 native agent backend")
struct AgentBackendTests {
    static let catalog = try! ActionCatalog.load()

    struct Rig { let sys: MockActionSystem; let consent: ConsentEngine; let planner: ScriptedPlanner; let agent: NativeAgentBackend }
    func rig(_ turns: [PlannerTurn], front: String = "com.apple.Safari", timeout: TimeInterval = 60) -> Rig {
        let sys = DeterministicMockApps.desktop(catalog: Self.catalog, front: front)
        let consent = ConsentEngine(); let planner = ScriptedPlanner(turns)
        var cfg = NativeAgentBackend.Config(); cfg.timeout = timeout
        return Rig(sys: sys, consent: consent, planner: planner, agent: NativeAgentBackend(planner: planner, executor: ActionExecutor(system: sys), consent: consent, config: cfg))
    }
    static func step(_ title: String, _ kind: ActionKind, _ params: [String: String], rev: Reversibility = .reversible, undo: ActionRequest? = nil, id: String? = nil) -> PlanStep {
        PlanStep(id: id ?? title, title: title, request: ActionRequest(kind: kind, params: params, reversibility: rev, catalogID: nil), compensating: undo)
    }
    static let prTab = step("open PR tab", .focusTab, ["target": "Pull Request"])
    static let scrollDown = step("scroll to failing check", .scroll, ["direction": "down", "amount": "5"], undo: ActionRequest(kind: .scroll, params: ["direction": "up", "amount": "5"]))

    @Test func axSummaryIsScreenshotFree() {
        let r = rig([]); let s = AXSummary(system: r.sys)
        #expect(s.app == "Safari"); #expect(!s.elements.isEmpty); #expect(s.elements.count <= AXSummary.maxElements)
        #expect(s.promptText.contains("AXTab \"Overview\" [selected]")); #expect(s.runningApps.contains("Slack"))
        #expect(AgentTool.vocabulary.map(\.kind).count == 12)
        #expect(PlannerPrompt.system(tools: AgentTool.vocabulary).contains("never guess coordinates"))
    }

    @Test func happyPathPlanThenDone() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.prTab, Self.scrollDown])), .done(summary: "on the failing check")])
        let rep = await r.agent.run(goal: "open the PR tab and scroll to the failing check")
        #expect(rep.status == .completed(summary: "on the failing check")); #expect(rep.rounds == 2)
        #expect(rep.records.map(\.outcome) == [.done(verified: true), .done(verified: true)])
        #expect(r.sys.log.contains { $0.contains("Pull Request") }); #expect(r.planner.calls.count == 2)
        #expect(r.planner.calls[1].history.count == 2)                       // re-observe with history
        #expect(r.agent.chips.phase == .finished); #expect(r.agent.chips.chips.allSatisfy { $0.state == .done })
        #expect(!r.agent.isRunning)
    }

    @Test func giveUpAndEmptyPlan() async {
        #expect(await rig([.giveUp(reason: "no idea")]).agent.run(goal: "x").status == .gaveUp(reason: "no idea"))
        #expect(await rig([.plan(StepPlan(goal: "x", steps: []))]).agent.run(goal: "x").status == .gaveUp(reason: "empty plan"))
        #expect(await rig([]).agent.run(goal: "x").status == .gaveUp(reason: "script exhausted"))
    }

    @Test func failedStepHaltsRun() async {
        let bad = Self.step("click ghost", .click, ["name": "Nonexistent Control zzz"])
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.prTab, bad, Self.scrollDown])), .done(summary: "never")])
        let rep = await r.agent.run(goal: "g")
        guard case .failed(let why) = rep.status else { Issue.record("\(rep.status)"); return }
        #expect(why.hasPrefix("click ghost")); #expect(rep.records.count == 2); #expect(r.planner.calls.count == 1)
        #expect(r.agent.chips.chips.map(\.state) == [.done, .failed, .upcoming])
    }

    @Test func maxRoundsBounded() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.scrollDown]))])          // planner never says done
        let rep = await r.agent.run(goal: "g")
        #expect(rep.rounds == r.agent.config.maxRounds); #expect(rep.records.count == r.agent.config.maxRounds)
    }

    @Test func stepsPerRoundCapped() async {
        let steps = (0..<30).map { Self.step("s\($0)", .scroll, ["direction": "down"], id: "s\($0)") }
        let r = rig([.plan(StepPlan(goal: "g", steps: steps)), .done(summary: "d")])
        #expect(await r.agent.run(goal: "g").records.count == r.agent.config.maxStepsPerRound)
    }

    @Test func irreversibleStepWaitsForConfirmationDefaultDeclines() async {
        let danger = Self.step("delete everything", .shortcut, ["keys": "cmd+delete"], rev: .irreversible)
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.prTab, danger, Self.scrollDown])), .done(summary: "d")])
        let rep = await r.agent.run(goal: "g")
        #expect(rep.status == .declined); #expect(rep.records.map(\.outcome) == [.done(verified: true), .skipped])
        #expect(!r.sys.log.contains { $0.hasPrefix("key") }); #expect(r.consent.pendingCard(UUID()) == nil)
        #expect(r.agent.chips.chips.map(\.state) == [.done, .cancelled, .upcoming])
    }

    @Test func irreversibleStepRunsAfterConfirmation() async {
        let danger = Self.step("send it", .shortcut, ["keys": "cmd+enter"], rev: .irreversible)
        let r = rig([.plan(StepPlan(goal: "g", steps: [danger])), .done(summary: "sent")])
        let seen = ABox<[String]>([])
        r.agent.confirmation = { card in seen.mutate { $0.append(card.title) }; return true }
        let rep = await r.agent.run(goal: "g")
        #expect(rep.status == .completed(summary: "sent")); #expect(seen.value == ["send it"])
        #expect(r.sys.log.contains("key cmd+enter"))
    }

    @Test func semiStepGetsUndoToast() async {
        let semi = Self.step("post", .shortcut, ["keys": "enter"], rev: .semi)
        let r = rig([.plan(StepPlan(goal: "g", steps: [semi])), .done(summary: "d")])
        let toasts = ABox<Int>(0); r.consent.onToast = { _, _ in toasts.mutate { $0 += 1 } }
        _ = await r.agent.run(goal: "g")
        #expect(toasts.value == 1); #expect(r.sys.log.contains("key enter"))
    }

    @Test func stopMidFlightDropsQueuedAndRollsBack() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.scrollDown, Self.prTab, Self.scrollDown])), .done(summary: "d")])
        // Stop the moment the first chip goes current → executes step 1, then halts before step 2.
        let agent = r.agent; let fired = ABox(false)
        agent.onChips = { m in if m.chips.first?.state == .done, !fired.value { fired.mutate { $0 = true }; agent.requestStop() } }
        let win = r.sys.snapshot().focusedWindow!; let before = r.sys.scrollPosition(in: win)
        let rep = await agent.run(goal: "g")
        #expect(rep.status == .stopped)
        #expect(rep.records.map(\.outcome) == [.rolledBack])                     // step 1 undone via compensating scroll up
        #expect(r.sys.scrollPosition(in: win) == before)
        #expect(agent.chips.phase == .halted); #expect(agent.chips.chips.map(\.state) == [.rolledBack, .cancelled, .cancelled])
        #expect(!r.sys.log.contains { $0.contains("Pull Request") })
    }

    @Test func stopDuringPlannerWaitCancelsIt() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.prTab]))])
        r.planner.delay = .seconds(5)
        let agent = r.agent
        let t = Task { await agent.run(goal: "g") }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(agent.isRunning)
        let t0 = Date(); await agent.stop()
        let rep = await t.value
        #expect(rep.status == .stopped); #expect(rep.records.isEmpty); #expect(Date().timeIntervalSince(t0) < 2)
        #expect(r.sys.log.isEmpty)
    }

    @Test func hardTimeoutStopsAndRollsBack() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.scrollDown])), .plan(StepPlan(goal: "g", steps: [Self.scrollDown]))], timeout: 0.2)
        r.planner.delay = .milliseconds(150)
        let rep = await r.agent.run(goal: "g")
        #expect(rep.status == .timedOut || rep.status == .stopped)
        #expect(rep.records.allSatisfy { $0.outcome == .rolledBack })
    }

    @Test func stopBeforeRunIsNotSticky() async {
        let r = rig([.done(summary: "d")])
        await r.agent.stop()
        #expect(await r.agent.run(goal: "g").status == .completed(summary: "d"))
    }

    @Test func concurrentRunRejected() async {
        let r = rig([.plan(StepPlan(goal: "g", steps: [Self.prTab])), .done(summary: "d")]); r.planner.delay = .milliseconds(100)
        let a = r.agent
        async let first = a.run(goal: "g")
        try? await Task.sleep(for: .milliseconds(20))
        let second = await a.run(goal: "g2")
        #expect(second.status == .failed(reason: "already running"))
        #expect(await first.status == .completed(summary: "d"))
    }

    @Test func chipsModelSemantics() {
        var m = StepChipsModel(); #expect(m.pillText == "")
        m.phase = .thinking; #expect(m.pillText == "thinking…")
        m.load(StepPlan(goal: "g", steps: [Self.prTab, Self.scrollDown]))
        #expect(m.chips.map(\.state) == [.upcoming, .upcoming]); #expect(m.chips[0].opacity == 0.45)
        m.set("open PR tab", .current); #expect(m.chips[0].glows); #expect(m.pillText == "open PR tab"); #expect(m.chips[0].scale == 1)
        m.set("open PR tab", .done); #expect(m.chips[0].scale == 0.8)
        m.phase = .awaitingConfirmation("send"); #expect(m.pillText == "confirm: send")
        m.cancelUpcoming(); #expect(m.chips.map(\.state) == [.done, .cancelled]); #expect(m.chips[1].opacity == 0.3)
    }

    /// Consent-gating fuzz: random plans mixing classes; irreversible / uncatalogued-unknown steps never reach the executor unconfirmed.
    @Test func consentGatingFuzz() async {
        var rng = SplitMix(seed: 0xC0FFEE)
        var checked = 0
        for i in 0..<300 {
            let n = Int(rng.next() % 5) + 1
            var steps: [PlanStep] = []
            for j in 0..<n {
                switch rng.next() % 4 {
                case 0: steps.append(Self.step("scroll\(j)", .scroll, ["direction": "down"], id: "f\(i)_\(j)"))
                case 1: steps.append(Self.step("danger\(j)", .shortcut, ["keys": "cmd+k"], rev: .irreversible, id: "f\(i)_\(j)"))
                case 2: steps.append(Self.step("semi\(j)", .shortcut, ["keys": "enter"], rev: .semi, id: "f\(i)_\(j)"))
                default: // uncatalogued, unknown id, category unknown → conservative irreversible
                    steps.append(PlanStep(id: "f\(i)_\(j)", title: "unknown\(j)", request: ActionRequest(kind: .shortcut, params: ["keys": "cmd+q"], reversibility: .reversible, catalogID: "mystery.\(j)")))
                }
            }
            let r = rig([.plan(StepPlan(goal: "fuzz", steps: steps)), .done(summary: "d")])
            let confirmAll = rng.next() % 2 == 0
            r.agent.confirmation = { _ in confirmAll }
            let rep = await r.agent.run(goal: "fuzz")
            let dangerous = steps.filter { $0.request.reversibility == .irreversible || ($0.request.catalogID ?? "").hasPrefix("mystery") }
            let dangerKeys = Set(dangerous.map { $0.request.params["keys"]! })
            let firedDanger = r.sys.log.filter { l in dangerKeys.contains { l == "key \($0)" } }.count
            if confirmAll { #expect(firedDanger == dangerous.count) }
            else {
                #expect(firedDanger == 0)
                if let d = dangerous.first { #expect(rep.status == .declined); #expect(rep.records.last?.step.id == d.id) } else { #expect(rep.status == .completed(summary: "d")) }
            }
            checked += 1
        }
        #expect(checked == 300)
    }
}

final class ABox<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.lock(); defer { l.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}

struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}
