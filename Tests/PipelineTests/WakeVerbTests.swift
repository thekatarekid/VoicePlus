import Testing
import Foundation
import Shared
@testable import Pipeline

/// P5.2 — wake-verb grammar, pre-route hook, stripping stage, hint model.
@Suite struct WakeVerbTests {
    static let g = WakeVerbGrammar()
    static func hf(_ register: Utterance.Register = .unknown) -> StageContext {
        StageContext(register: register, extra: [WakeVerbPreRoute.modeKey: WakeVerbPreRoute.latchedValue])
    }
    static func spans(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.9, audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    // MARK: K20 — wire value "latched", one-release read-compat for "handsFree"
    @Test func latchedWireValueAndLegacyAlias() {
        #expect(WakeVerbPreRoute.latchedValue == "latched")
        #expect(WakeVerbPreRoute.isLatched(StageContext(extra: [WakeVerbPreRoute.modeKey: "latched"])))
        #expect(WakeVerbPreRoute.isLatched(StageContext(extra: [WakeVerbPreRoute.modeKey: WakeVerbPreRoute.legacyLatchedValue])))
        #expect(!WakeVerbPreRoute.isLatched(StageContext(extra: [WakeVerbPreRoute.modeKey: "hold"])))
        #expect(!WakeVerbPreRoute.isLatched(StageContext()))
    }

    // MARK: Grammar
    @Test func typeVerb() {
        let p = Self.g.parse("Type hello there, World")
        #expect(p?.kind == .type); #expect(p?.payload == "hello there, World"); #expect(p?.verbTokenCount == 1)
    }
    @Test func typeAloneIsNotACommand() { #expect(Self.g.parse("type") == nil) }
    @Test func typeSynonyms() {
        #expect(Self.g.parse("write a note")?.kind == .type)
        #expect(Self.g.parse("dictate the thing")?.payload == "the thing")
    }
    @Test func sendVariants() {
        #expect(Self.g.parse("send")?.kind == .send)
        #expect(Self.g.parse("Send it.")?.verbTokenCount == 2)
        #expect(Self.g.parse("send that")?.payload == "")
    }
    @Test func sendWithPayloadIsNotSend() { #expect(Self.g.parse("send me the report tomorrow") == nil) }
    @Test func appName() {
        let p = Self.g.parse("Slack I'm running late")
        #expect(p?.kind == .app); #expect(p?.appName == "slack"); #expect(p?.payload == "I'm running late")
    }
    @Test func appNameWithPrefix() {
        #expect(Self.g.parse("in Notes buy milk")?.payload == "buy milk")
        #expect(Self.g.parse("tell messages see you soon")?.verbTokenCount == 2)
    }
    @Test func multiWordAppName() {
        let g = WakeVerbGrammar(appNames: ["Visual Studio Code", "code"])
        let p = g.parse("visual studio code open main dot swift")
        #expect(p?.appName == "visual studio code"); #expect(p?.verbTokenCount == 3); #expect(p?.payload == "open main dot swift")
    }
    @Test func appNameAloneIsNotACommand() { #expect(Self.g.parse("slack") == nil) }
    @Test func plainDictationDoesNotParse() {
        #expect(Self.g.parse("hey just checking in about lunch") == nil)
        #expect(Self.g.parse("") == nil)
    }
    @Test func payloadKeepsCasingAndInnerPunctuation() {
        #expect(WakeVerbGrammar.payload("Type: Hi, Bob!", dropping: 1) == "Hi, Bob!")
    }

    // MARK: Pre-route hook
    @Test func hookFiresOnlyWhenLatched() {
        let h = WakeVerbPreRoute()
        #expect(h.preRoute("type hello", context: StageContext()) == nil)
        let d = h.preRoute("type hello", context: Self.hf())
        #expect(d?.route == .dictate); #expect(d?.routeConfidence == 1); #expect(d?.routeSource == .rules)
    }
    @Test func hookDefersOnNonVerb() {
        #expect(WakeVerbPreRoute().preRoute("scratch that", context: Self.hf()) == nil)
    }
    @Test func hookRecordsParseAndCountsUse() {
        let h = WakeVerbPreRoute()
        _ = h.preRoute("type hello", context: Self.hf())
        #expect(h.hints.useCount == 1)
        #expect(h.takeParse(for: "type hello")?.kind == .type)
        #expect(h.takeParse(for: "type hello") == nil)
    }
    @Test func appVerbSetsChatRegister() {
        let d = WakeVerbPreRoute().preRoute("slack on my way", context: Self.hf(.email))
        #expect(d?.register == .chat); #expect(d?.registerSource == .rules)
    }
    @Test func beatsBayesInsidePreRoutingClassifier() {
        let c = PreRoutingClassifier(hooks: [WakeVerbPreRoute()])
        #expect(c.classify("type scratch that", context: Self.hf()).route == .dictate)
        #expect(c.classify("type scratch that", context: Self.hf()).routeSource == .rules)
    }
    @Test func hookLatencyUnderBudget() {
        let h = WakeVerbPreRoute()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1000 { _ = h.preRoute("in slack see you at three", context: Self.hf()) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 1000
        #expect(ms < 1)
    }

    // MARK: Stage
    @Test func stageStripsVerbKeepingRanges() async throws {
        let h = WakeVerbPreRoute()
        let input = Self.spans("type hello world")
        _ = h.preRoute(input.joinedText, context: Self.hf())
        let out = try await WakeVerbStage(preRoute: h).process(input, context: Self.hf())
        #expect(out.map(\.text) == ["", "hello", "world"])
        #expect(out.joinedText.trimmingCharacters(in: .whitespaces) == "hello world")
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out.allSatisfy { $0.provenance.last == .wakeVerb })
    }
    @Test func stageStripsMultiTokenPhrase() async throws {
        let input = Self.spans("in slack on my way")
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: Self.hf())
        #expect(out.map(\.text) == ["", "", "on", "my", "way"])
    }
    @Test func stageSplitsSingleSpan() async throws {
        let input = [TranscriptSpan(text: "type hello world", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: Self.hf())
        #expect(out.map(\.text) == ["hello world"])
    }
    @Test func stageNoOpOutsideLatch() async throws {
        let input = Self.spans("type hello")
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: StageContext())
        #expect(out.map(\.text) == ["type", "hello"])
    }
    @Test func stageLeavesLowConfidenceVerb() async throws {
        var input = Self.spans("type hello")
        input[0].confidence = 0.2
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: Self.hf())
        #expect(out[0].text == "type")
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
    }

    // MARK: Hint model
    @Test func hintFullForFirstTenUses() {
        let m = WakeVerbHintModel()
        for _ in 0..<10 { #expect(m.presentation == .full); m.recordUse() }
        #expect(m.presentation != .full)
    }
    @Test func hintFadesThenHides() {
        let m = WakeVerbHintModel(initialUses: 10)
        var last = 1.0
        for _ in 0..<WakeVerbHintModel.fadeUses {
            guard case .faded(let o) = m.presentation else { Issue.record("expected faded"); return }
            #expect(o < last && o > 0); last = o
            m.recordUse()
        }
        #expect(m.presentation == .hidden)
        #expect(m.hintText == nil)
    }
    @Test func hintPersistsAndResets() {
        var saved: [Int] = []
        let m = WakeVerbHintModel(persist: { saved.append($0) })
        m.recordUse(); m.recordUse(); m.reset()
        #expect(saved == [1, 2, 0]); #expect(m.useCount == 0)
        #expect(WakeVerbHintModel(initialUses: 99).presentation == .hidden)
    }
}
