import Testing
import Shared
@testable import Pipeline

/// P1.7 T5 — golden cases for `ProseListFormatter`.
struct ProseFormatterTests {
    static let formatter = ProseListFormatter()

    /// One span per word, 0.2 s each, confidence 0.95 unless the word is wrapped in `<…>`
    /// (low confidence 0.3).
    static func spans(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            let low = w.hasPrefix("<") && w.hasSuffix(">")
            let word = low ? String(w.dropFirst().dropLast()) : String(w)
            return TranscriptSpan(text: word, confidence: low ? 0.3 : 0.95,
                                  audioRange: Double(i) * 0.2...Double(i + 1) * 0.2, provenance: [.asr])
        }
    }

    static func run(_ text: String, register: Utterance.Register = .prose) -> String {
        formatter.format(spans(text), register: register).renderedText
    }

    // MARK: Golden cases (input, expected)

    static let golden: [(String, String)] = [
        // Capitalization + terminal punctuation
        ("hello world", "Hello world."),
        ("i think i'll go", "I think I'll go."),
        ("we meet on friday in march", "We meet on Friday in March."),
        ("is it ready question mark", "Is it ready?"),
        ("great job exclamation mark", "Great job!"),
        ("that is done. next we ship", "That is done. Next we ship."),
        // Fillers
        ("um i think uh we should go", "I think we should go."),
        ("so it's erm basically done hmm", "So it's basically done."),
        ("it was you know pretty good", "It was pretty good."),
        ("you know what i mean", "You know what I mean."),
        // Spoken punctuation
        ("hello comma world period", "Hello, world."),
        ("first line new line second line", "First line\nSecond line."),
        ("one paragraph new paragraph another one", "One paragraph\n\nAnother one."),
        ("she said open quote hi there close quote", "She said \"hi there\"."),
        ("wait open paren maybe close paren no", "Wait (maybe) no."),
        ("he said open quote fine close quote and left", "He said \"fine\" and left."),
        ("to john comma i mean to jane comma hello", "To jane, hello."),
        ("send it to John no wait Jane", "Send it to Jane."),
        ("the first time was great second time too", "The first time was great second time too."),
        ("items colon apples semicolon pears", "Items: apples; pears."),
        ("well dash maybe", "Well — maybe."),
        ("sure full stop", "Sure."),
        // Self-correction
        ("let's meet on friday no thursday", "Let's meet on Thursday."),
        ("let's meet on friday no wait thursday at noon", "Let's meet on Thursday at noon."),
        ("send it to john i mean jane tonight", "Send it to jane tonight."),
        ("i need three no four apples", "I need four apples."),
        ("it costs twenty five no twenty six dollars", "It costs $26."),
        ("the deadline is march fifth sorry march sixth", "The deadline is March 6."),
        ("call me tomorrow scratch that call me tonight", "Call me tonight."),
        ("there is no way", "There is no way."),
        ("no i don't think so", "No I don't think so."),
        ("the red one no the blue one", "The red one no the blue one."),
        // Numbers / dates / times
        ("there were twenty five people", "There were 25 people."),
        ("i have three cats", "I have three cats."),
        ("about one hundred and twenty guests", "About 120 guests."),
        ("two thousand five hundred units", "2500 units."),
        ("it grew fifteen percent", "It grew 15%."),
        ("that's five dollars", "That's $5."),
        ("see you at three pm", "See you at 3 pm."),
        ("the call is at nine thirty am", "The call is at 9:30 am."),
        ("born in nineteen ninety five", "Born in 1995."),
        ("due march fifth twenty twenty four", "Due March 5, 2024."),
        ("on the fifth of march", "On the 5th of March."),
        ("july twenty first", "July 21."),
        ("i have one more thing", "I have one more thing."),
        // Lists
        ("first buy milk second buy eggs third call mom", "1. Buy milk\n2. Buy eggs\n3. Call mom"),
        ("here's the plan first buy milk second buy eggs", "Here's the plan:\n1. Buy milk\n2. Buy eggs"),
        ("first comma buy milk comma second comma buy eggs", "1. Buy milk\n2. Buy eggs"),
        ("first of all i disagree", "First of all I disagree."),
        ("at first i thought it was fine", "At first I thought it was fine."),
        ("things to pack bullet socks bullet shoes bullet point hat", "Things to pack:\n- Socks\n- Shoes\n- Hat"),
        ("number one sleep number two eat", "1. Sleep\n2. Eat"),
        ("first prepare second deliver finally celebrate", "1. Prepare\n2. Deliver\n3. Celebrate"),
    ]

    @Test(arguments: golden)
    func golden(_ input: String, _ expected: String) {
        #expect(Self.run(input) == expected, "input: \(input)")
    }

    // MARK: List register

    @Test func listRegisterPromotesSingleOrdinal() {
        #expect(Self.run("first buy milk", register: .list) == "1. Buy milk")
        #expect(Self.run("first buy milk", register: .prose) == "First buy milk.")
    }

    // MARK: Confidence contract

    @Test func lowConfidenceSpanSurvivesVerbatim() {
        let input = Self.spans("i'll ping <kothari> after lunch")
        let out = Self.formatter.format(input)
        let violations = ConfidenceContract.verify(input: input, output: out)
        #expect(violations.isEmpty, "\(violations)")
        #expect(out[2].text == "kothari")
        #expect(out[2].confidence == 0.3)
        #expect(out[2].provenance == [.asr, .formatterProse])
        #expect(out.renderedText == "I'll ping kothari after lunch.")
    }

    @Test func lowConfidenceFillerIsFlaggedNotRemoved() {
        let input = Self.spans("i <um> agree")
        let out = Self.formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out[1].text == "um")
        #expect(out[1].needsRepair)
        #expect(out.renderedText == "I um agree.")
    }

    @Test func lowConfidenceBlocksSelfCorrection() {
        let input = Self.spans("on <friday> no thursday")
        let out = Self.formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out[1].text == "friday")
        #expect(out.renderedText == "On friday no Thursday.")
    }

    @Test func punctuationAfterLowConfidenceStaysInOwnSpan() {
        let input = Self.spans("hi <priya> comma thanks")
        let out = Self.formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out[1].text == "priya")
        #expect(out[2].text == ",")
    }

    @Test func poisonedSpanWalk() {
        for (input, _) in Self.golden {
            var spans = Self.spans(input)
            let mid = spans.count / 2
            spans[mid].confidence = 0.1
            let out = Self.formatter.format(spans)
            let violations = ConfidenceContract.verify(input: spans, output: out)
            #expect(violations.isEmpty, "\(input): \(violations)")
            #expect(out.count == spans.count)
            #expect(out[mid].text == spans[mid].text)
        }
    }

    // MARK: Span bookkeeping

    @Test func preservesAudioRangesConfidenceAndAlternates() async throws {
        var input = Self.spans("hello comma world")
        input[2].alternates = [Alternate(text: "word", score: 0.2, source: .beam)]
        let out = try await Self.formatter.process(input, context: StageContext(register: .prose))
        #expect(out.count == 3)
        for (i, s) in out.enumerated() {
            #expect(s.audioRange == input[i].audioRange)
            #expect(s.confidence == input[i].confidence)
            #expect(s.alternates == input[i].alternates)
            #expect(s.provenance.last == .formatterProse)
        }
        #expect(out.map(\.text) == ["Hello,", "", "world."])
    }

    @Test func emptyInput() {
        #expect(Self.formatter.format([]).isEmpty)
    }

    @Test func multiWordSpan() {
        let span = TranscriptSpan(text: "um let's meet friday no thursday comma okay", confidence: 0.9,
                                  audioRange: 0...2, provenance: [.asr])
        let out = Self.formatter.format([span])
        #expect(out.count == 1)
        #expect(out[0].text == "Let's meet Thursday, okay.")
    }

    @Test func optionsDisableTerminalPeriod() {
        var opts = ProseListFormatter.Options()
        opts.addTerminalPeriod = false
        let f = ProseListFormatter(options: opts)
        #expect(f.format(Self.spans("hello world")).renderedText == "Hello world")
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.stage(for: .formatterProse) is ProseListFormatter)
        #expect(StageRegistry.formatter(for: .list)?.id == .formatterProse)
        #expect(StageRegistry.formatter(for: .prose)?.id == .formatterProse)
    }
}
