import Foundation
import Shared
import Testing
@testable import Engine

/// A mock decision model: fixed answers, counts calls, records the state it saw.
final class MockDecisionModel: DecisionModel, @unchecked Sendable {
    let id: String
    var answers: DecisionAnswers
    var error: Error?
    private(set) var calls = 0
    private(set) var lastState: String?
    private(set) var lastQuestions: [DecisionQuestion] = []

    init(id: String = "mock", answers: DecisionAnswers = DecisionAnswers(), error: Error? = nil) {
        self.id = id; self.answers = answers; self.error = error
    }

    func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        calls += 1; lastState = state; lastQuestions = questions
        if let error { throw error }
        return answers
    }

    static func answers(addressed: Double, capability: UtteranceOwner, capP: Double = 0.8,
                        complete: Double = 0.9, worthNoting: Double = 0.1, needsAgent: Double = 0.1) -> DecisionAnswers {
        var cap: [String: Double] = [:]
        let rest = (1 - capP) / Double(UtteranceOwner.allCases.count - 1)
        for o in UtteranceOwner.allCases { cap[o.rawValue] = o == capability ? capP : rest }
        return DecisionAnswers([
            .addressed: ["no": 1 - addressed, "yes": addressed],
            .continuation: ["no": 0.7, "yes": 0.3],
            .complete: ["no": 1 - complete, "yes": complete],
            .capability: cap,
            .needsAgent: ["no": 1 - needsAgent, "yes": needsAgent],
            .worthNoting: ["no": 1 - worthNoting, "yes": worthNoting],
        ])
    }
}

private func input(_ text: String, explicit: UtteranceDecision? = nil, app: String? = "Slack") -> ArbiterInput {
    let t = Date(timeIntervalSince1970: 1_000)
    return ArbiterInput(utteranceID: "u1", range: t...t.addingTimeInterval(2), explicit: explicit,
                        state: DecisionState(utterance: text, frontmostApp: app))
}

@Suite("V5 O4 IntentArbiter")
struct IntentArbiterTests {
    @Test("Layer 0: an explicit decision short-circuits with confidence 1 and no model call")
    func explicitShortCircuits() async {
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.0, capability: .ignore))
        let arbiter = IntentArbiter(model: { model })
        let r = await arbiter.evaluate(input("hello", explicit: UtteranceDecision(owner: .dictate, confidence: 0.4, reason: "hotkey")))
        #expect(r.layer == .explicit)
        #expect(r.decision.owner == .dictate)
        #expect(r.decision.confidence == 1)
        #expect(r.decision.questionProbabilities.isEmpty)
        #expect(model.calls == 0)
    }

    @Test("Layer 0: the first recogniser that fires wins; later ones and the model are not consulted")
    func recogniserOrder() async {
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.99, capability: .act))
        let wake = ClosureExplicitDecider(id: "wakeVerb") { $0.hasPrefix("note ") ? .explicit(.note, reason: "note") : nil }
        let act = ClosureExplicitDecider(id: "actIntent") { _ in .explicit(.act, reason: "open") }
        let arbiter = IntentArbiter(layer0: [wake, act], model: { model })
        let r = await arbiter.evaluate(input("note buy milk"))
        #expect(r.decision == UtteranceDecision(owner: .note, confidence: 1, reason: "wakeVerb.note"))
        #expect(model.calls == 0)
        let r2 = await arbiter.evaluate(input("open safari"))
        #expect(r2.decision.owner == .act)
        #expect(r2.decision.reason == "actIntent.open")
        #expect(model.calls == 0)
    }

    @Test("Layer 1 asks all six questions in one call")
    func oneCallSixQuestions() async {
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.9, capability: .act))
        let arbiter = IntentArbiter(model: { model })
        let r = await arbiter.evaluate(input("open the calendar"))
        #expect(model.calls == 1)
        #expect(model.lastQuestions == DecisionQuestion.allCases)
        #expect(r.layer == .model)
        #expect(model.lastState?.contains("latest utterance: open the calendar") == true)
    }

    @Test("band mapping: act / ask / note / ignore")
    func bands() async {
        func owner(_ addressed: Double, _ cap: UtteranceOwner, worth: Double = 0.1) async -> UtteranceDecision {
            let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: addressed, capability: cap, worthNoting: worth))
            return await IntentArbiter(model: { model }).evaluate(input("x")).decision
        }
        let act = await owner(0.9, .act)
        #expect(act.owner == .act); #expect(act.band == .act); #expect(act.confidence == 0.9)
        let dictate = await owner(0.86, .dictate)
        #expect(dictate.owner == .dictate); #expect(dictate.band == .act)
        let ask = await owner(0.7, .act)
        #expect(ask.owner == .ask); #expect(ask.band == .ask)
        let note = await owner(0.5, .act)
        #expect(note.owner == .note); #expect(note.band == .note)
        let ignore = await owner(0.2, .act)
        #expect(ignore.owner == .ignore); #expect(ignore.band == .ignore)
        #expect(abs(ignore.confidence - 0.8) < 1e-9)
        let keep = await owner(0.2, .ignore, worth: 0.9)
        #expect(keep.owner == .note); #expect(keep.band == .ignore)
    }

    @Test("an incomplete utterance drops one band")
    func incomplete() async {
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.95, capability: .act, complete: 0.2))
        let d = await IntentArbiter(model: { model }).evaluate(input("open the")).decision
        #expect(d.band == .ask)
        #expect(d.owner == .ask)
        #expect(d.reason == "layer1.mock.incomplete")
    }

    @Test("per-app thresholds: Not-for-you nudges raise the bar only in that app")
    func perAppNudge() {
        var bands = DecisionBands.defaults
        #expect(bands.band(for: 0.86, app: "Zoom") == .act)
        for _ in 0..<10 { bands.nudgeNotForYou(app: "Zoom") }
        #expect(bands.perAppOffset["Zoom"] == DecisionBands.maxOffset)
        #expect(bands.band(for: 0.86, app: "Zoom") == .ask)
        #expect(bands.band(for: 0.86, app: "Slack") == .act)
        #expect(bands.isValid)
        let decoded = try? JSONDecoder().decode(DecisionBands.self, from: JSONEncoder().encode(bands))
        #expect(decoded == bands)
    }

    @Test("no model / a failing model: nothing acts")
    func unavailable() async {
        let none = await IntentArbiter(model: { nil }).evaluate(input("open safari")).decision
        #expect(none.owner == .ignore); #expect(none.reason == "layer1.none")
        let failing = MockDecisionModel(error: DecisionModelError.notInstalled("kev"))
        let d = await IntentArbiter(model: { failing }).evaluate(input("open safari")).decision
        #expect(d.owner == .ignore); #expect(d.confidence == 0); #expect(d.reason == "layer1.mock.unavailable")
    }

    @Test("log record shape: reason code + every question's probability, never text")
    func logShape() async {
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.9, capability: .act))
        let arbiter = IntentArbiter(model: { model })
        var logged: [(UtteranceDecision, String)] = []
        arbiter.onDecision = { d, i in logged.append((d, i.utteranceID)) }
        await arbiter.decide(input("open the secret calendar"))
        let (d, id) = try! #require(logged.first)
        #expect(id == "u1")
        #expect(d.reason == "layer1.mock")
        for q in DecisionQuestion.allCases where q.kind == .yesNo { #expect(d.questionProbabilities[q.rawValue] != nil) }
        for o in UtteranceOwner.allCases { #expect(d.questionProbabilities["capability.\(o.rawValue)"] != nil) }
        let encoded = String(decoding: try! JSONEncoder().encode(d), as: UTF8.self)
        #expect(!encoded.contains("secret"))
    }

    @Test("Layer 2 routes act / note / ask")
    func layer2() async {
        actor Box { var hits: [String] = []; func add(_ s: String) { hits.append(s) } }
        let box = Box()
        let router = Layer2Router(act: { t, agent in await box.add("act:\(t):\(agent)") },
                                  note: { await box.add("note:\($0)") }, ask: { await box.add("ask:\($0)") })
        let model = MockDecisionModel(answers: MockDecisionModel.answers(addressed: 0.95, capability: .act, needsAgent: 0.9))
        let arbiter = IntentArbiter(model: { model })
        arbiter.handoff = router
        await arbiter.decide(input("book a flight"))
        model.answers = MockDecisionModel.answers(addressed: 0.5, capability: .note)
        await arbiter.decide(input("milk"))
        model.answers = MockDecisionModel.answers(addressed: 0.7, capability: .ask)
        await arbiter.decide(input("what time"))
        model.answers = MockDecisionModel.answers(addressed: 0.1, capability: .ignore)
        await arbiter.decide(input("lunch?"))
        #expect(await box.hits == ["act:book a flight:true", "note:milk", "ask:what time"])
    }
}

@Suite("V5 O5 DecisionState")
struct DecisionStateTests {
    @Test("renders every O5 field")
    func fields() {
        let s = DecisionState(utterance: "send it", frontmostApp: "Mail", fieldRole: "emailBody", textFieldFocused: true,
                              meetingActive: true,
                              history: (1...5).map { DecisionHistoryItem(text: "h\($0)", owner: .dictate) },
                              otherVoiceRecently: true, lipActivity: 0.8,
                              prosody: ProsodySummary(snrDB: 25, energySlope: 0.2, speakingRate: 3))
        let r = DecisionStateRenderer().render(s)
        #expect(r.contains("app: Mail"))
        #expect(r.contains("field: emailBody focused"))
        #expect(r.contains("meeting recording: yes"))
        #expect(r.contains("another voice in the last 10 s: yes"))
        #expect(r.contains("lips moving: yes"))
        #expect(r.contains("voice: close and clear, rising energy, normal pace"))
        #expect(!r.contains("h2"))   // only the last three
        #expect(r.contains("- [dictate] h3") && r.contains("h5"))
        #expect(r.hasSuffix("latest utterance: send it"))
    }

    @Test("state string is capped at 384 tokens: history goes first, then the utterance tail")
    func cap() {
        let long = String(repeating: "word ", count: 600)
        let s = DecisionState(utterance: "open the calendar " + long, frontmostApp: "Mail",
                              history: (1...3).map { _ in DecisionHistoryItem(text: long, owner: .ignore) })
        let renderer = DecisionStateRenderer()
        let r = renderer.render(s)
        #expect(renderer.tokenCount(r) <= 384)
        #expect(!r.contains("[ignore]"))
        #expect(r.contains("latest utterance: open the calendar"))
        // Small state is untouched.
        let small = DecisionState(utterance: "hi", history: [DecisionHistoryItem(text: "a", owner: .note)])
        #expect(renderer.render(small).contains("- [note] a"))
        // A custom (real-tokenizer) counter is honoured.
        let tight = DecisionStateRenderer(maxTokens: 20, tokenCount: { $0.split(separator: " ").count })
        #expect(tight.tokenCount(tight.render(s)) <= 20)
    }
}
