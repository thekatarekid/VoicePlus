import Foundation
import Testing
import Shared
@testable import Pipeline

/// V5 D1 + K7 — the one ITN implementation (`ITNStage`): goldens, en-IN, field-role policy, the
/// NeMo residual mapping (against a stub backend — the real one is `NemoITN` in Engine, exercised by
/// `Tests/AppTests/ITNAgreementTests.swift`), and text path == span path.
struct ITNStageTests {
    static let formatter = ProseListFormatter()

    static func spans(_ text: String, gap: Double = 0.05) -> [TranscriptSpan] {
        NumbersTimingTests.timed(text, gap: gap)
    }

    static func final(_ text: String, _ config: ITNStage.Config = .init(), gap: Double = 0.05) -> String {
        formatter.format(spans(text, gap: gap), itn: config).renderedText
    }

    // MARK: Goldens (build doc §D1)

    @Test func goldens() {
        #expect(Self.final("five thousand one hundred and fifty") == "5150.")
        #expect(Self.final("one two three four") == "1234.")                 // digits said without pauses
        #expect(Self.final("meet me at three thirty p.m.") == "Meet me at 3:30 PM.")
        #expect(Self.final("three thirty pm") == "3:30 PM.")
    }

    @Test func enINLakhCrore() {
        let inr = ITNStage.Config(locale: .enIN)
        #expect(Self.final("twelve lakh", inr) == "12,00,000.")
        #expect(Self.final("the flat costs two crore fifty lakh", inr) == "The flat costs 2,50,00,000.")
        #expect(Self.final("five lakh rupees", inr) == "₹5,00,000.")
        #expect(Self.final("the invoice total is two thousand three hundred forty rupees", inr) == "The invoice total is ₹2,340.")
        #expect(Self.final("two lakh fifty thousand.", inr) == "2,50,000.")
        // en-IN is additive: plain numbers are what `en` writes.
        #expect(Self.final("about one hundred and twenty guests", inr) == "About 120 guests.")
        // `en` leaves lakh alone apart from the number.
        #expect(Self.final("twelve lakh") == "12 lakh.")
    }

    @Test func enINDayFirstDates() {
        let inr = ITNStage.Config(locale: .enIN)
        #expect(Self.final("due on march fifth", inr) == "Due on 5 March.")
        #expect(Self.final("due on the fifth of march twenty twenty four", inr) == "Due on the 5 March 2024.")
        #expect(Self.final("march twenty first", inr) == "21 March.")
        #expect(!Self.final("you may first ask", inr).contains("1"))      // "may" the verb
        #expect(IndianNumbers.grouped(1_234_567) == "12,34,567")
        #expect(IndianNumbers.grouped(999) == "999")
        #expect(IndianNumbers.grouped(1_000) == "1,000")
    }

    @Test func localeTags() {
        #expect(ITNLocale(tag: "en_IN") == .enIN)
        #expect(ITNLocale(tag: "en-in") == .enIN)
        #expect(ITNLocale(tag: "en_US") == .en)
        #expect(ITNLocale(tag: "hi") == .hi)
        #expect(ITNLocale(tag: "hi_IN") == .hi)
        #expect(ITNLocale(tag: "hi_en") == .hiEn)
        #expect(ITNLocale(tag: "C") == .en)
        #expect(ITNLocale.hi.backendLanguage == "hi")
        #expect(ITNLocale.hiEn.backendLanguage == "en")
    }

    // MARK: Punctuation-tolerant + timing (the E1/E2 rules now live behind ITNStage)

    @Test func punctuationTolerant() {
        #expect(Self.final("five thousand one hundred and fifty.") == "5150.")
        #expect(Self.final("we sold one hundred and fifty, then stopped") == "We sold 150, then stopped.")
    }

    @Test func digitSequenceByTiming() {
        #expect(Self.final("one two three four", gap: 0.05) == "1234.")
        #expect(Self.final("one two three four", gap: 0.4) == "1, 2, 3, 4.")
        #expect(Self.final("one two", gap: 0.05) == "One two.")              // < 3 digits
    }

    // MARK: Field-role policy

    @Test func policyFromRole() {
        #expect(ITNPolicy(fieldRole: "codeEditor") == .never)
        #expect(ITNPolicy(fieldRole: "terminal") == .never)
        #expect(ITNPolicy(fieldRole: "spreadsheetCell") == .always)
        #expect(ITNPolicy(fieldRole: "multilineText") == .prose)
        #expect(ITNPolicy(fieldRole: nil) == .prose)
    }

    @Test func neverInCodeOrTerminal() async throws {
        let s = Self.spans("set the timeout to two hundred and fifty")
        for role in ["codeEditor", "terminal"] {
            let ctx = StageContext(register: .prose, extra: [ITNStage.Keys.fieldRole: role])
            let out = try await Self.formatter.process(s, context: ctx).renderedText
            #expect(out == "Set the timeout to two hundred and fifty.", "\(role)")
            let itnOut = try await ITNStage().process(s, context: ctx)
            #expect(itnOut.map(\.text) == s.map(\.text))
        }
        // Read off the AX keys too: VS Code's integrated terminal.
        let ax = StageContext(register: .prose, appBundleID: "com.microsoft.VSCode",
                              extra: [FieldContext.Keys.axRole: "AXTextArea", FieldContext.Keys.hints: "Terminal input"])
        #expect(ITNStage.config(for: ax).policy == .never)
    }

    @Test func alwaysInSpreadsheetCell() async throws {
        let ctx = StageContext(register: .prose, extra: [ITNStage.Keys.fieldRole: "spreadsheetCell"])
        let out = try await Self.formatter.process(Self.spans("five"), context: ctx).renderedText
        #expect(out == "5.")
        #expect(Self.final("five") == "Five.")
    }

    @Test func localeFromContext() async throws {
        let ctx = StageContext(register: .prose, extra: [ITNStage.Keys.locale: "en_IN"])
        let out = try await Self.formatter.process(Self.spans("twelve lakh"), context: ctx)
        #expect(out.renderedText == "12,00,000.")
    }

    // MARK: Contract

    @Test func keepsSpansAndConfidence() async throws {
        let s = Self.spans("pay five thousand one hundred and fifty <now> please")
        let out = try await ITNStage().process(s, context: StageContext())
        #expect(out.count == s.count)
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
        #expect(out.renderedText == "pay 5150 now please")
        #expect(out.allSatisfy { $0.provenance.last == ITNStage.stageID })
    }

    // MARK: Text path == span path (what the preview runs)

    static let agreement = [
        "about one hundred and twenty guests", "five thousand one hundred and fifty", "twelve hundred and five",
        "a hundred and fifty", "one thousand and five", "twenty and thirty", "rock and roll",
        "the total is two thousand three hundred forty", "meet at three thirty pm", "fifty percent",
        "five dollars", "march fifth twenty twenty four", "order two of the large ones",
    ]

    @Test(arguments: agreement)
    func textPathMatchesSpanPath(_ spoken: String) {
        for locale in [ITNLocale.en, .enIN] {
            let config = ITNStage.Config(locale: locale)
            let spanPath = ITNStage.normalizeSpans(Self.spans(spoken, gap: 0.4), config: config)
            #expect(ITNStage.normalize(text: spoken, config: config) == spanPath, "\(locale)")
        }
    }

    // MARK: NeMo residual (stub backend)

    struct StubBackend: ITNBackend {
        let table: [String: String]
        func supports(_ language: String) -> Bool { language == "en" || language == "hi" }
        func normalizeSentence(_ text: String, language: String) -> String? {
            var out = text
            for (k, v) in table { out = out.replacingOccurrences(of: k, with: v) }
            return out
        }
    }

    @Test func residualMapsBackOntoTokens() {
        var toks = Tokenizer.tokens(from: Self.spans("it was five dollars and fifty cents, really"))
        NemoResidual.apply(&toks, backend: StubBackend(table: ["five dollars and fifty cents": "$5.50"]),
                           language: "en", policy: .prose)
        #expect(toks.map(\.text) == ["it", "was", "$5.50,", "really"])
        #expect(toks[2].span == 2)
    }

    /// Only a single currency / decimal / percent token is taken from NeMo (D1 LibriSpeech run).
    @Test func residualTakesOnlyWhatSwiftCannotWrite() {
        var toks = Tokenizer.tokens(from: Self.spans("and one more"))
        NemoResidual.apply(&toks, backend: StubBackend(table: ["and one": "1"]), language: "en", policy: .always)
        #expect(toks.map(\.text) == ["and", "one", "more"])
        toks = Tokenizer.tokens(from: Self.spans("from four to five fathoms"))
        NemoResidual.apply(&toks, backend: StubBackend(table: ["four to five": "04:56"]), language: "en", policy: .prose)
        #expect(toks.map(\.text) == ["from", "four", "to", "five", "fathoms"])
        #expect(NemoResidual.accepts(["$5.50"], language: "en"))
        #expect(NemoResidual.accepts(["2.5"], language: "en"))
        #expect(NemoResidual.accepts(["12.5%"], language: "en"))
        #expect(!NemoResidual.accepts(["100", "$50"], language: "en"))
        #expect(!NemoResidual.accepts(["7"], language: "en"))
        #expect(!NemoResidual.accepts(["2", "h"], language: "en"))
        #expect(NemoResidual.accepts(["१२००"], language: "hi"))
    }

    @Test func residualSkipsClausesWithoutNumberWords() {
        struct Exploding: ITNBackend {
            func supports(_ language: String) -> Bool { true }
            func normalizeSentence(_ text: String, language: String) -> String? { Issue.record("called for \(text)"); return nil }
        }
        var toks = Tokenizer.tokens(from: Self.spans("hello there, general kenobi"))
        NemoResidual.apply(&toks, backend: Exploding(), language: "en", policy: .prose)
        #expect(toks.map(\.text) == ["hello", "there,", "general", "kenobi"])
    }

    /// NeMo goes first: "five dollars and fifty cents" must reach it whole, not as "$5 and 50 cents".
    @Test func residualRunsBeforeSwiftRules() {
        var toks = Tokenizer.tokens(from: Self.spans("it was five dollars and fifty cents"))
        ITNStage.apply(&toks, spans: [], config: .init(), backend: StubBackend(table: ["five dollars and fifty cents": "$5.50"]))
        #expect(toks.map(\.text) == ["it", "was", "$5.50"])
        toks = Tokenizer.tokens(from: Self.spans("a hundred and fifty dollars"))
        ITNStage.apply(&toks, spans: [], config: .init(), backend: StubBackend(table: ["a hundred and fifty dollars": "100 $50"]))
        #expect(toks.map(\.text) == ["$150"])
    }

    /// D1 LibriSpeech findings fixed in the Swift rules: spoken years anywhere, "a hundred and fifty".
    @Test func spokenYearsAndArticleHundreds() {
        #expect(Self.final("in eighteen sixty two, a law was enacted", gap: 0.4) == "In 1862, a law was enacted.")
        #expect(Self.final("installed in eighteen eighty three", gap: 0.4) == "Installed in 1883.")
        #expect(Self.final("on august twenty seventh, eighteen thirty seven", gap: 0.4) == "On August 27, 1837.")
        #expect(Self.final("a cheque for a hundred and fifty", gap: 0.4) == "A cheque for 150.")
        #expect(Self.final("a hundred people", gap: 0.4) == "A hundred people.")
        #expect(Self.final("my flight lands at eleven forty five", gap: 0.4) == "My flight lands at 11 45.")
    }

    /// Verify fix: "may"/"march" as ordinary words are not capitalised as months.
    @Test func ambiguousMonthsStayWordsOutsideDates() {
        #expect(Self.final("you may first ask") == "You may first ask.")
        #expect(Self.final("we march on") == "We march on.")
        #expect(Self.final("meet me on may fifth") == "Meet me on May fifth.")
        #expect(Self.final("due on march fifth") == "Due on March 5.")
        #expect(Self.final("due on the fifth of march", ITNStage.Config(locale: .enIN)) == "Due on the 5 March.")
        #expect(Self.final("see you in june") == "See you in June.")
    }
}
