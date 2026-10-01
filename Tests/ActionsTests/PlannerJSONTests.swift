import Foundation
import Testing
@testable import Actions

/// V5 CU8 — the planner asks for strict JSON and repairs what small local models actually send.
@Suite("CU8 planner JSON parsing + repair")
struct PlannerJSONTests {
    func steps(_ turn: PlannerTurn?) -> [PlanStep] {
        if case .plan(let p)? = turn { return p.steps }
        return []
    }

    @Test("the prompt asks for one JSON object and keeps the safety line")
    func prompt() {
        let s = PlannerPrompt.system(tools: AgentTool.vocabulary)
        #expect(s.contains("ONE JSON object"))
        #expect(s.contains("never guess coordinates"))
        #expect(s.contains("fillField(name, value)"))
    }

    @Test("strict JSON plan")
    func strict() throws {
        let reply = #"{"status":"plan","rationale":"open then type","steps":[{"tool":"focusApp","params":{"target":"Notes"}},{"tool":"typeText","params":{"value":"milk"}}]}"#
        let turn = PlannerJSON.parse(reply, goal: "g")
        guard case .plan(let plan)? = turn else { Issue.record("no plan: \(String(describing: turn))"); return }
        #expect(plan.goal == "g" && plan.rationale == "open then type")
        #expect(plan.steps.map(\.request.kind) == [.focusApp, .typeText])
        #expect(plan.steps[0].request.params == ["target": "Notes"])
        #expect(plan.steps[0].title == "focusApp Notes")
    }

    @Test("done and give-up")
    func doneAndGiveUp() {
        #expect(PlannerJSON.parse(#"{"status":"done","summary":"tab is open"}"#, goal: "g") == .done(summary: "tab is open"))
        #expect(PlannerJSON.parse(#"{"status":"GIVE_UP","reason":"no such window"}"#, goal: "g") == .giveUp(reason: "no such window"))
    }

    @Test("repairs: code fence, think block, prose around it")
    func fencesAndThinking() {
        let reply = """
        <think>The user wants the PR tab. I should click it.</think>
        Sure! Here is the plan:
        ```json
        {"status":"plan","steps":[{"tool":"click","params":{"name":"Pull requests"}}]}
        ```
        Let me know if that works.
        """
        #expect(steps(PlannerJSON.parse(reply, goal: "g")).map(\.request.params) == [["name": "Pull requests"]])
    }

    @Test("repairs: trailing commas, single quotes, bare keys, smart quotes")
    func syntax() {
        #expect(steps(PlannerJSON.parse(#"{"status":"plan","steps":[{"tool":"scroll","params":{"direction":"down",},},],}"#, goal: "g")).count == 1)
        #expect(steps(PlannerJSON.parse("{'status':'plan','steps':[{'tool':'click','params':{'name':'OK'}}]}", goal: "g")).count == 1)
        #expect(steps(PlannerJSON.parse(#"{status:"plan",steps:[{tool:"click",params:{name:"OK"}}]}"#, goal: "g")).count == 1)
        #expect(steps(PlannerJSON.parse("{\u{201C}status\u{201D}:\u{201C}plan\u{201D},\u{201C}steps\u{201D}:[{\u{201C}tool\u{201D}:\u{201C}click\u{201D},\u{201C}params\u{201D}:{\u{201C}name\u{201D}:\u{201C}OK\u{201D}}}]}", goal: "g")).count == 1)
    }

    @Test("repairs: a reply cut off at the token cap keeps its complete steps")
    func truncated() {
        let cut = #"{"status":"plan","steps":[{"tool":"focusApp","params":{"target":"Safari"}},{"tool":"openURL","params":{"url":"https://exa"#
        let s = steps(PlannerJSON.parse(cut, goal: "g"))
        #expect(s.first?.request.kind == .focusApp)
        #expect(!s.isEmpty)
        let cutKey = #"{"status":"plan","steps":[{"tool":"click","params":{"name":"OK"}}],"rationale":"#
        #expect(steps(PlannerJSON.parse(cutKey, goal: "g")).count == 1)
    }

    @Test("tool names: separators and case are tolerated; unknown tools are dropped, never guessed")
    func toolNames() {
        let reply = #"{"status":"plan","steps":[{"tool":"fill_field","params":{"name":"To","value":"Priya"}},{"tool":"rm -rf","params":{}},{"action":"Shortcut","args":{"keys":"cmd+t"}}]}"#
        #expect(steps(PlannerJSON.parse(reply, goal: "g")).map(\.request.kind) == [.fillField, .shortcut])
        #expect(PlannerJSON.parse(#"{"status":"plan","steps":[{"tool":"launchMissiles"}]}"#, goal: "g")
                == .giveUp(reason: "planner reply had no parseable steps"))
    }

    @Test("numbers and booleans become string params; a bare array is a step list")
    func valuesAndArrays() {
        let s = steps(PlannerJSON.parse(#"[{"tool":"scroll","params":{"direction":"down","amount":5}}]"#, goal: "g"))
        #expect(s.first?.request.params["amount"] == "5")
    }

    @Test("no JSON at all → nil (the legacy line format may still apply)")
    func noJSON() {
        #expect(PlannerJSON.parse("DONE all set", goal: "g") == nil)
        #expect(PlannerJSON.parse("1. click(name=Submit)", goal: "g") == nil)
    }

    @Test("garbage that looks like JSON is a give-up, not a crash")
    func garbage() {
        let turn = PlannerJSON.parse("{{{{ ]]] :: ,,", goal: "g")
        if case .plan? = turn { Issue.record("garbage must never become a plan") }
    }
}
