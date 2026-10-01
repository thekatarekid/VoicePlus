import Testing
import Foundation
import Shared
@testable import Pipeline

/// V5 P1/P3/P5/P6 — the public-dictionary stages: goldens, Bet 9, registry order, licence notices.
@Suite struct PublicDictionaryStageTests {
    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        [TranscriptSpan(text: text, confidence: confidence, audioRange: 0...1, provenance: [.asr])]
    }

    static func run(_ stage: any PipelineStage, _ text: String, register: Utterance.Register = .prose,
                    confidence: Float = 0.9, extra: [String: String] = [:]) async throws -> TranscriptSpan {
        let input = spans(text, confidence: confidence)
        let out = try await stage.process(input, context: StageContext(register: register, extra: extra))
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out.count == 1)
        return out[0]
    }

    // MARK: P1 — Text Replacements

    static let replacements = StaticTextReplacements(["omw": "On my way!", "addr": "221B Baker Street", "brb soon": "be right back"])

    @Test func textReplacementGoldens() async throws {
        let stage = TextReplacementStage(source: Self.replacements)
        let cases: [(String, String)] = [
            ("omw", "On my way!"),
            ("OMW.", "On my way!"),                       // case-insensitive; no "!." doubling
            ("I'm omw, see you", "I'm On my way!, see you"),
            ("send it to addr please", "send it to 221B Baker Street please"),
            ("ok brb soon", "ok be right back"),            // multi-word shortcut
            ("omwx is not a shortcut", "omwx is not a shortcut"),
            ("brb, soon", "brb, soon"),                     // punctuation inside a multi-word shortcut breaks it
        ]
        for (input, expected) in cases {
            let out = try await Self.run(stage, input)
            #expect(out.text == expected, "\(input)")
            #expect(out.provenance.last == .textReplacement)
        }
    }

    @Test func textReplacementVerbatimRegistersLowConfidenceAndOptOut() async throws {
        let stage = TextReplacementStage(source: Self.replacements)
        #expect(try await Self.run(stage, "cd omw", register: .terminal).text == "cd omw")
        #expect(try await Self.run(stage, "let omw = 1", register: .code).text == "let omw = 1")
        let low = try await Self.run(stage, "omw", confidence: 0.2)
        #expect(low.text == "omw" && low.needsRepair)
        #expect(try await Self.run(stage, "omw", extra: [TextReplacementStage.enabledKey: "false"]).text == "omw")
    }

    @Test func systemReplacementItemsParse() {
        let table = SystemTextReplacements.parse([
            ["replace": "omw", "with": "On my way!", "on": 1],
            ["replace": "off", "with": "disabled", "on": 0],
            ["replace": "sig", "with": "— A"],
            ["with": "no shortcut"],
        ])
        #expect(table == ["omw": "On my way!", "sig": "— A"])
    }

    @Test func defaultSourceIsInertUntilTheAppOptsIn() async throws {
        let dictionaries = PublicDictionaries()
        #expect(dictionaries.textReplacementSource.replacements().isEmpty)
        dictionaries.setTextReplacements(Self.replacements)
        #expect(dictionaries.textReplacementSource.replacements()["omw"] == "On my way!")
    }

    // MARK: P3 — casing

    static let lexicon = CasingLexicon(["GitHub", "iPhone", "PostgreSQL", "macOS", "JavaScript"])

    @Test func casingGoldens() async throws {
        let stage = CasingStage(lexicon: Self.lexicon)
        let cases: [(String, String)] = [
            ("i pushed it to github", "i pushed it to GitHub"),
            ("Github and postgresql.", "GitHub and PostgreSQL."),
            ("two iphones", "two iPhones"),
            ("github's api", "GitHub's api"),
            ("(MACOS)", "(macOS)"),
            ("open github.com", "open github.com"),       // inner punctuation: not a token match
            ("githubber", "githubber"),                   // exact tokens only
            ("JavaScript stays", "JavaScript stays"),
        ]
        for (input, expected) in cases {
            #expect(try await Self.run(stage, input).text == expected, "\(input)")
        }
        #expect(try await Self.run(stage, "git push github", register: .terminal).text == "git push github")
        #expect(try await Self.run(stage, "github", confidence: 0.2).text == "github")
    }

    @Test func bundledCasingListIsLargeAndHoldsNoCommonWords() {
        let bundled = CasingLexicon.bundled
        #expect(bundled.count > 10_000)
        for name in ["github", "iphone", "macos", "javascript", "postgresql", "youtube", "kubernetes", "tiktok"] {
            #expect(bundled.canonicalForm(of: name) != nil, "\(name)")
        }
        #expect(bundled.canonicalForm(of: "github") == "GitHub")
        for word in ["apple", "swift", "ruby", "go", "word", "slack", "notion", "windows", "batteries", "focused", "zen", "max"] {
            #expect(bundled.canonicalForm(of: word) == nil, "common word \(word) must not be re-cased")
        }
    }

    @Test func fixtureAndBundledListsAgree() throws {
        let url = try #require(AppPaths.fixturesDirectory()?.appendingPathComponent("dictionaries/casing.txt"))
        let fixture = CasingLexicon(text: try String(contentsOf: url, encoding: .utf8))
        #expect(fixture == CasingLexicon.bundled, "re-run generate_casing.py --swift-only")
    }

    // MARK: P5 — likely entities

    static let vocabulary = WordVocabulary(words: ["the", "build", "is", "down", "call", "tomorrow", "about", "ask", "meeting", "deploy"])

    @Test func outOfVocabularyTokensAreLikelyEntities() {
        #expect(LikelyEntity.tokens(in: "ask Kothari about kubectl tomorrow", vocabulary: Self.vocabulary) == ["Kothari", "kubectl"])
        #expect(LikelyEntity.isLikelyEntity("iPhone", vocabulary: WordVocabulary(words: ["iphone"])))   // inner capital
        #expect(LikelyEntity.isLikelyEntity("gpt-4o", vocabulary: Self.vocabulary))
        #expect(!LikelyEntity.isLikelyEntity("Meetings,", vocabulary: Self.vocabulary))                // inflection
        #expect(!LikelyEntity.isLikelyEntity("a", vocabulary: Self.vocabulary))
        #expect(Self.spans("ask Kothari")[0].isLikelyEntity(vocabulary: Self.vocabulary))
        #expect(!Self.spans("the build")[0].isLikelyEntity(vocabulary: Self.vocabulary))
    }

    @Test func wordListParsingSkipsScowlHeaderAndProperNouns() {
        let text = "Custom wordlist\nCopyright Kevin Atkinson\n---\napple\nAaron\nbuild\n"
        let v = WordVocabulary(listText: text)
        #expect(v.contains("apple") && v.contains("builds") && v.contains("email"))
        #expect(!v.contains("aaron") && !v.contains("copyright"))
    }

    @Test func styleNeverLowercasesALikelyEntity() async throws {
        var profile = StyleProfile.coldStart(appBundleID: "com.example.chat", category: .chat)
        profile.capitalizationRate = 0   // this user writes lowercase sentence starts
        let extra = [StyleStage.profileJSONKey: try profile.encodedJSON()]
        let guardOnly = EntityGuard(vocabulary: Self.vocabulary, casing: nil)
        let guarded = EntityProtectingStage(StyleStage(), guard: { guardOnly })
        #expect(guarded.id == .style)
        #expect(try await Self.run(StyleStage(), "Kothari is down", extra: extra).text == "kothari is down")
        #expect(try await Self.run(guarded, "Kothari is down", extra: extra).text == "Kothari is down")
        #expect(try await Self.run(guarded, "The build is down", extra: extra).text == "the build is down")
    }

    @Test func guardReportsCorrectionsOfEntities() {
        let g = EntityGuard(vocabulary: Self.vocabulary, casing: nil)
        let found = g.corrections(original: "call Kothari tomorrow", rewritten: "call Kotari tomorrow")
        #expect(found.count == 1 && found[0].from == "Kothari" && found[0].to == "Kotari")
        #expect(g.corrections(original: "call the build", rewritten: "call a build").isEmpty)
        #expect(g.restore(original: "ask priya", rewritten: "ask Priya") == "ask Priya")  // capitalising is allowed
        #expect(g.restore(original: "ask PRIYA", rewritten: "ask Priya") == "ask PRIYA")  // lowering is not
        #expect(g.restore(original: "ask Priya", rewritten: "ask priya.") == "ask Priya.")
    }

    // MARK: P6 — transliteration

    @Test func ruleBasedDevanagariGoldens() {
        let t = RuleBasedDevanagari()
        #expect(t.transliterate("नमस्ते", to: .latin) == "namaste")
        #expect(t.transliterate("काम", to: .latin) == "kaam")
        #expect(t.transliterate("क्या", to: .latin) == "kyaa")
        #expect(t.transliterate("है", to: .latin) == "hai")
        #expect(t.transliterate("ज़रूर", to: .latin) == "zaroor")
        #expect(t.transliterate("namaste", to: .devanagari) == "नमस्ते")
        #expect(t.transliterate("kaam", to: .devanagari) == "काम")
        #expect(t.transliterate("kya", to: .devanagari) == "क्या")
        #expect(t.transliterate("hai", to: .devanagari) == "है")
        #expect(t.transliterate("gaya", to: .devanagari) == "गया")
        #expect(t.transliterate("hello", to: .latin) == nil)          // already Latin
        #expect(t.transliterate("नमस्ते", to: .devanagari) == nil)     // already Devanagari
    }

    @Test func transliterationStageIsOffUnlessAskedAndPrefersIndicXlit() async throws {
        let stage = TransliterationStage()
        #expect(try await Self.run(stage, "काम हो गया").text == "काम हो गया")
        let latin = try await Self.run(stage, "काम हो गया, ok?", extra: [TransliterationStage.targetKey: "latin"])
        #expect(latin.text == "kaam ho gayaa, ok?")
        #expect(!IndicXlitTransliterator().isAvailable)
        let xlit = IndicXlitTransliterator(model: { word, _ in word == "kaam" ? "काम" : nil })
        let model = TransliterationStage(backends: [xlit, RuleBasedDevanagari()])
        #expect(try await Self.run(model, "kaam done", extra: [TransliterationStage.targetKey: "devanagari"]).text == "काम done")
        let low = try await Self.run(stage, "काम", confidence: 0.2, extra: [TransliterationStage.targetKey: "latin"])
        #expect(low.text == "काम" && low.needsRepair)
    }

    // MARK: Registry + notices

    @Test func dictionaryStagesRunAfterFormattersAndBeforeStyle() {
        let ids = StageRegistry.allStages().map(\.id)
        let replacement = ids.firstIndex(of: .textReplacement)
        let casing = ids.firstIndex(of: .casing)
        let style = ids.firstIndex(of: .style)
        let lastFormatter = ids.lastIndex { [.formatterProse, .formatterEmail, .formatterChat, .formatterCode, .formatterTerminal].contains($0) }
        #expect(replacement != nil && casing != nil && style != nil && lastFormatter != nil)
        if let replacement, let casing, let style, let lastFormatter {
            #expect(lastFormatter < replacement && replacement < casing && casing < style)
        }
    }

    @Test func everyListCarriesItsLicenceNotice() {
        for entry in PublicDictionaryCatalog.all {
            #expect(!entry.licence.isEmpty && !entry.attribution.isEmpty, "\(entry.id)")
        }
        let notices = PublicDictionaryCatalog.notices
        for needle in ["CC0", "BSD-2-Clause", "Carnegie Mellon", "Kevin Atkinson", "MIT", "Apache-2.0", "Public domain"] {
            #expect(notices.contains(needle), "\(needle)")
        }
        #expect(Set(PublicDictionaryCatalog.all.map(\.item)) == ["P1", "P3", "P4", "P5", "P6", "P7"])
        #expect(PublicDictionaryCatalog.all.filter { $0.delivery == .download }.allSatisfy { $0.approximateBytes < PublicDictionaryFetcher.maxBytes })
    }
}
