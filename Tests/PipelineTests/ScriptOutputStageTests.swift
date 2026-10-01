import Testing
@testable import Pipeline
import Shared

/// V5 LANG2 / G3 — the output script at the end of the pipeline.
@Suite struct ScriptOutputStageTests {
    static let hindiWords: Set<String> = ["kal", "hai", "kaam", "namaste", "bahut"]
    static func isHindi(_ w: String) -> Bool { hindiWords.contains(w.lowercased()) }
    static let rules = RuleBasedDevanagari()

    @Test func romanTransliteratesDevanagariAndDropsTheDanda() {
        let out = ScriptOutputStage.apply(.roman, to: "काम है।", backend: Self.rules, isHindiWord: Self.isHindi)
        #expect(!out.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
        #expect(out.hasSuffix("."))
    }

    @Test func mixedKeepsEnglishLatinAndUsesNoDanda() {
        let out = ScriptOutputStage.apply(.mixed, to: "kal meeting hai.", backend: Self.rules, isHindiWord: Self.isHindi)
        #expect(out.contains("meeting"))
        #expect(!out.contains("kal") && !out.contains("hai"))
        #expect(out.hasSuffix("."))
        #expect(!out.contains("।"))
    }

    @Test func devanagariUsesTheDandaAndLeavesEnglishLatinWithoutAModel() {
        let out = ScriptOutputStage.apply(.devanagari, to: "kaam hai.", backend: Self.rules, isHindiWord: Self.isHindi)
        #expect(out == "काम है।")
        let english = ScriptOutputStage.apply(.devanagari, to: "send the deck", backend: Self.rules, isHindiWord: Self.isHindi)
        #expect(english == "send the deck")
    }

    @Test func aRealModelWritesEnglishInDevanagariToo() {
        let xlit = IndicXlitTransliterator(model: { word, script in script == .devanagari ? "<\(word)>" : nil })
        let out = ScriptOutputStage.apply(.devanagari, to: "meeting", backend: xlit, isHindiWord: { _ in false })
        #expect(out == "<meeting>")
    }

    @Test func dandaOnlyAfterADevanagariWord() {
        #expect(ScriptOutputStage.danda(".", after: "है", script: .devanagari) == "।")
        #expect(ScriptOutputStage.danda(".", after: "deck", script: .devanagari) == ".")
        #expect(ScriptOutputStage.danda("।", after: "hai", script: .mixed) == ".")
    }

    @Test func inertWithoutAScriptKey() async throws {
        let spans = [TranscriptSpan(text: "काम है।", confidence: 0.9, audioRange: 0...1)]
        let out = try await ScriptOutputStage().process(spans, context: StageContext())
        #expect(out.map(\.text) == ["काम है।"])
        #expect(out[0].provenance.last == ScriptOutputStage.stageID)
    }

    @Test func rewritesThroughTheContextAndHonoursLowConfidence() async throws {
        var ctx = StageContext()
        ctx.extra[ScriptOutputStage.Keys.script] = OutputScript.devanagari.rawValue
        let stage = ScriptOutputStage(backends: [RuleBasedDevanagari()], isHindiWord: Self.isHindi)
        let spans = [TranscriptSpan(text: "kaam", confidence: 0.9, audioRange: 0...0.5),
                     TranscriptSpan(text: "hai.", confidence: 0.2, audioRange: 0.5...1)]
        let out = try await stage.process(spans, context: ctx)
        #expect(out[0].text == "काम")
        #expect(out[1].text == "hai.")          // Bet 9: flagged, not rewritten
        #expect(out[1].needsRepair)
        #expect(ConfidenceContract.verify(input: spans, output: out).isEmpty)
    }

    @Test func registeredLastAfterStyle() {
        #expect(StageRegistry.allStages().last?.id == ScriptOutputStage.stageID)
    }

    @Test func itnLocaleFromLanguages() {
        #expect(ITNLocale.from(languages: ["en"], hindiScript: nil, spelling: "en-US") == .en)
        #expect(ITNLocale.from(languages: ["en"], hindiScript: nil, spelling: "en-IN") == .enIN)
        #expect(ITNLocale.from(languages: ["en", "hi"], hindiScript: .roman, spelling: "en-US") == .hiEn)
        #expect(ITNLocale.from(languages: ["hi-IN"], hindiScript: .devanagari, spelling: nil) == .hi)
    }

    // MARK: G3 — script policy over Hinglish ASR output (Srota writes Hindi in Devanagari, English in Latin)

    static let srota = "इस tutorial में हम यह सीखेंगे।"
    static let xlit = IndicXlitTransliterator(model: { word, script in
        guard script == .latin else { return nil }
        return ["ऑफिस": "office", "कल": "kal", "है": "hai", "में": "mein"][word]
    })
    static func isEnglish(_ w: String) -> Bool { ["office", "meeting", "tutorial"].contains(w.lowercased()) }

    @Test func g3RomanIsTheDefaultAndLeavesNoDevanagari() {
        #expect(OutputScript.default == .roman)
        let out = ScriptOutputStage.apply(.roman, to: Self.srota, backend: Self.rules, isHindiWord: Self.isHindi, isEnglishWord: Self.isEnglish)
        #expect(!out.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
        #expect(out.contains("tutorial") && out.hasSuffix(".") && !out.contains("।"))
    }

    @Test func g3MixedKeepsEnglishLatinEvenWhenTheASRWroteItInDevanagari() {
        let out = ScriptOutputStage.apply(.mixed, to: "कल ऑफिस में meeting है।", backend: Self.xlit,
                                          isHindiWord: Self.isHindi, isEnglishWord: Self.isEnglish)
        #expect(out == "कल office में meeting है.")
        // Hindi that happens to romanise to an English word stays Devanagari when it is Hindi.
        let hindi = ScriptOutputStage.apply(.mixed, to: "है", backend: Self.xlit, isHindiWord: { $0 == "hai" },
                                            isEnglishWord: { _ in true })
        #expect(hindi == "है")
        // Srota's own mixed output is already the policy: unchanged but for the danda.
        let srota = ScriptOutputStage.apply(.mixed, to: Self.srota, backend: Self.rules, isHindiWord: Self.isHindi,
                                            isEnglishWord: { _ in false })
        #expect(srota == "इस tutorial में हम यह सीखेंगे.")
    }

    @Test func g3DevanagariKeepsTheDevanagariWordAndTheDanda() {
        let out = ScriptOutputStage.apply(.devanagari, to: "कल ऑफिस है।", backend: Self.xlit,
                                          isHindiWord: Self.isHindi, isEnglishWord: Self.isEnglish)
        #expect(out == "कल ऑफिस है।")
    }

    @Test func g3StageUsesTheInjectedEnglishTest() async throws {
        var ctx = StageContext()
        ctx.extra[ScriptOutputStage.Keys.script] = OutputScript.mixed.rawValue
        let stage = ScriptOutputStage(backends: [Self.xlit], isHindiWord: Self.isHindi, isEnglishWord: Self.isEnglish)
        let out = try await stage.process([TranscriptSpan(text: "ऑफिस", confidence: 0.9, audioRange: 0...1)], context: ctx)
        #expect(out.map(\.text) == ["office"])
    }
}
