import Foundation
import Testing
@testable import Pipeline
import Shared

/// D2 (V4.1) model punctuation is provisional · D3 (V4.2, V4.4) continuation table ·
/// D6 (V4.17) spacing modes · the StyleStage caret gate.
@Suite struct CaretFormattingTests {
    static let notes = "com.apple.Notes"

    /// One span per word, 0.3 s each, exactly as written (the recogniser's casing and punctuation).
    static func heard(_ words: String) -> [TranscriptSpan] {
        words.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.95,
                           audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), provenance: [.asr])
        }
    }

    static func field(_ caret: CaretState, app: String = notes, role: String = "AXTextArea",
                      preferences: FormattingPreferences = .default) -> FieldContext {
        var f = FieldContext(appBundleID: app, axRole: role, caret: caret)
        f.preferences = preferences
        return f
    }

    static func land(_ words: String, _ caret: CaretState, app: String = notes, role: String = "AXTextArea",
                     preferences: FormattingPreferences = .default) async throws -> String {
        try await FieldRoleFormatter().format(heard(words), field: field(caret, app: app, role: role,
                                                                         preferences: preferences)).text
    }

    static let prose = FieldRules(category: .prose, autoCapitalize: true, trailingPeriod: true,
                                  allowSubmit: false, allowParagraphBreak: true, preserveIdentifiers: false)
    static let terminal = FieldRules(category: .terminal, autoCapitalize: false, trailingPeriod: false,
                                     allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: true)

    // MARK: - D2 matrix

    @Test("D2: mid-sentence after a word — lowercase, a space, no period (model capital and period dropped)")
    func midSentenceWord() async throws {
        let caret = CaretState.endOfField(before: "I think")
        #expect(try await Self.land("Maybe tomorrow.", caret) == " maybe tomorrow")
        #expect(try await Self.land("The report is ready.", caret) == " the report is ready")
        #expect(try await Self.land("the report is ready", caret) == " the report is ready")
    }

    @Test("D2: text after the caret strips the model period and adds a trailing space")
    func textAfterCaret() async throws {
        let caret = CaretState.known(before: "The ", after: "cat sat.")
        #expect(try await Self.land("Big.", caret) == "big ")
        // After a sentence end but with the sentence continuing on the line: still no period.
        let mid = CaretState.known(before: "Done. ", after: "and more")
        #expect(try await Self.land("Next up.", mid) == "Next up ")
    }

    @Test("D2: after '.' + space — capital, no leading space, period kept or added")
    func afterSentenceEnd() async throws {
        let caret = CaretState.endOfField(before: "It was late. ")
        #expect(try await Self.land("we left early", caret) == "We left early.")
        #expect(try await Self.land("We left early.", caret) == "We left early.")
        // "." with no space yet: a space, then a capital.
        #expect(try await Self.land("we left", CaretState.endOfField(before: "It was late.")) == " We left.")
    }

    @Test("D2: a space after a non-terminal lowercases the model capital")
    func spaceAfterNonTerminal() async throws {
        #expect(try await Self.land("Maybe later.", .endOfField(before: "Well, ")) == "maybe later")
        #expect(try await Self.land("Maybe later.", .endOfField(before: "Well,")) == " maybe later")
    }

    @Test("D2: empty field — capital; a model period needs ≥ 3 words, an added one ≥ 4")
    func emptyField() async throws {
        let empty = CaretState.endOfField(before: "")
        #expect(try await Self.land("Send the report.", empty) == "Send the report.")          // model, 3 words
        #expect(try await Self.land("send the report today", empty) == "Send the report today.") // added, 4 words
        #expect(try await Self.land("send the report", empty) == "Send the report")             // added, 3 words
        #expect(try await Self.land("Sounds good.", empty) == "Sounds good")                    // model, 2 words
        #expect(try await Self.land("yes", empty) == "Yes")
    }

    @Test("D2: a spoken period is kept even mid-sentence; ? and ! are never touched")
    func spokenMarksKept() async throws {
        let mid = CaretState.endOfField(before: "I think")
        #expect(try await Self.land("that is all full stop", mid) == " that is all.")
        #expect(try await Self.land("that is all period", mid) == " that is all.")
        #expect(try await Self.land("Is that all?", mid) == " is that all?")
        let unknown = try await Self.land("the report is ready full stop", .unknown,
                                          preferences: FormattingPreferences(unknownCaretStyle: .asSpoken))
        #expect(unknown == "the report is ready.")
    }

    @Test("D2: spans carrying a dictated mark are marked .spoken; an added period is .stage")
    func originsAreMarked() async throws {
        let field = Self.field(.endOfField(before: ""))
        let spoken = try await FieldRoleFormatter().format(Self.heard("hello comma world full stop"), field: field)
        #expect(spoken.spans.contains { $0.punctuationOrigin == .spoken && $0.text.hasSuffix(",") })
        #expect(spoken.spans.contains { $0.punctuationOrigin == .spoken && $0.text.hasSuffix(".") })
        let added = try await FieldRoleFormatter().format(Self.heard("send the report today"), field: field)
        #expect(added.spans.contains { $0.punctuationOrigin == .stage && $0.text.hasSuffix(".") })
        #expect(!added.spans.contains { $0.punctuationOrigin == .spoken })
        let heard = try await FieldRoleFormatter().format(Self.heard("Send the report today."), field: field)
        #expect(heard.spans.allSatisfy { $0.punctuationOrigin == .model })
    }

    @Test("D2: proper-noun shapes keep their capital mid-sentence")
    func properNounShapes() async throws {
        let mid = CaretState.endOfField(before: "I met")
        #expect(try await Self.land("NASA engineers.", mid) == " NASA engineers")
        #expect(try await Self.land("Monday morning.", mid) == " Monday morning")
        #expect(try await Self.land("I did.", mid) == " I did")
    }

    @Test("D2: an abbreviation's dot is not a sentence period")
    func abbreviationDotStays() async throws {
        #expect(try await Self.land("and so on etc.", .endOfField(before: "I think")) == " and so on etc.")
    }

    @Test("D2: code and terminal roles keep their formatter's casing and the heard punctuation")
    func codeRolesUntouched() async throws {
        // No inner formatter, so only the field-role decisions act on the heard text.
        let bare = FieldRoleFormatter(stage: FieldRoleFormatterStage(formatter: { _ in nil }))
        let caret = CaretState.endOfField(before: "let x: ")
        let code = try await bare.format(Self.heard("String."), field: Self.field(caret, app: "com.microsoft.VSCode"))
        #expect(code.text == "String.")
        let prose = try await bare.format(Self.heard("String."), field: Self.field(caret))
        #expect(prose.text == "string")
    }

    // MARK: - D3 unknown caret

    @Test("D3: unknown — never a leading space, ≥ 3 words keep the model's casing and period")
    func unknownSentenceStyle() async throws {
        #expect(try await Self.land("The report is ready.", .unknown) == "The report is ready.")
        #expect(try await Self.land("send the report", .unknown) == "send the report")   // formatter's capital and period undone
        #expect(try await Self.land("Sounds good.", .unknown) == "sounds good")          // 1–2 words stripped
        #expect(try await Self.land("Yes.", .unknown) == "yes")
    }

    @Test("D3: unknown + asSpoken — no capital or period that was not dictated")
    func unknownAsSpoken() async throws {
        let asSpoken = FormattingPreferences(unknownCaretStyle: .asSpoken)
        #expect(try await Self.land("The report is ready.", .unknown, preferences: asSpoken) == "the report is ready")
        #expect(try await Self.land("Sounds good.", .unknown, preferences: asSpoken) == "sounds good")
    }

    @Test("D3: unknown never produces a leading space", arguments: [SpacingPreference.automatic, .never])
    func unknownNeverLeadingSpace(spacing: SpacingPreference) async throws {
        for words in ["hello", "Hello there.", "the report is ready", "um okay"] {
            for style in UnknownCaretStyle.allCases {
                let prefs = FormattingPreferences(spacing: spacing, unknownCaretStyle: style)
                for app in [Self.notes, "com.apple.Terminal", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap"] {
                    let text = try await Self.land(words, .unknown, app: app, preferences: prefs)
                    #expect(!text.hasPrefix(" "), "\(words) in \(app) (\(style), \(spacing)) → \(text)")
                    #expect(!text.hasSuffix(" "))
                }
            }
        }
        for rules in [Self.prose, Self.terminal] {
            let plan = ContinuationPlanner.plan(caret: .unknown, rules: rules,
                                                preferences: FormattingPreferences(spacing: spacing))
            #expect(plan.leading.isEmpty)
            #expect(plan.trailing.isEmpty)
            #expect(plan.capitalizeFirstWord == false)
        }
    }

    @Test("D3: an unknown caret invents no period in the field rules either")
    func unknownRules() {
        let rules = FieldRules.rules(for: Self.field(.unknown))
        #expect(rules.trailingPeriod == false)
        #expect(FieldRules.rules(for: Self.field(.endOfField(before: "Done. "))).trailingPeriod)
    }

    // MARK: - D3 the full table

    struct Row: CustomStringConvertible, Sendable {
        var caret: CaretState
        var leading: String
        var trailing: String
        var capitalize: Bool
        var lowercaseModel: Bool
        var period: PeriodRule
        var description: String { "\(caret)" }
    }

    static let table: [Row] = [
        // after [.!?] + space → capital, no leading space
        Row(caret: .endOfField(before: "It was cold. "), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .keep),
        Row(caret: .endOfField(before: "Really? "), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .keep),
        Row(caret: .endOfField(before: "Stop! "), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .keep),
        // after [.!?], no space yet → a space and a capital
        Row(caret: .endOfField(before: "It was cold."), leading: " ", trailing: "", capitalize: true, lowercaseModel: false, period: .keep),
        // after a word → " " + lowercase + no period
        Row(caret: .endOfField(before: "The number is"), leading: " ", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        Row(caret: .endOfField(before: "Hello,"), leading: " ", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        Row(caret: .endOfField(before: "Hello, "), leading: "", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        // before a word → trailing " ", no period
        Row(caret: .known(before: "", after: "world"), leading: "", trailing: " ", capitalize: true, lowercaseModel: false, period: .strip),
        Row(caret: .known(before: "The ", after: "cat"), leading: "", trailing: " ", capitalize: false, lowercaseModel: true, period: .strip),
        // after a word, before a word
        Row(caret: .known(before: "The", after: "cat"), leading: "", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        // inside a word → no spaces at all
        Row(caret: .known(before: "un", after: "able"), leading: "", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        // before punctuation → no trailing space
        Row(caret: .known(before: "is", after: ", really"), leading: " ", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        // empty → capital, a full clause only
        Row(caret: .endOfField(before: ""), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .fullClause),
        Row(caret: .known(before: "", after: "  "), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .fullClause),
        // a new line after a sentence; text on later lines does not make it mid-sentence
        Row(caret: .known(before: "Done.\n", after: "\nNext line"), leading: "", trailing: "", capitalize: true, lowercaseModel: false, period: .keep),
        // openers glue
        Row(caret: .endOfField(before: "(see "), leading: "", trailing: "", capitalize: false, lowercaseModel: true, period: .strip),
        Row(caret: .endOfField(before: "He said \""), leading: "", trailing: "", capitalize: false, lowercaseModel: false, period: .strip),
        // unknown
        Row(caret: .unknown, leading: "", trailing: "", capitalize: false, lowercaseModel: false, period: .unknownCaret),
    ]

    @Test("D3: the continuation table", arguments: CaretFormattingTests.table)
    func continuationTable(row: Row) {
        let plan = ContinuationPlanner.plan(caret: row.caret, rules: Self.prose)
        #expect(plan.leading == row.leading)
        #expect(plan.trailing == row.trailing)
        #expect(plan.capitalizeFirstWord == row.capitalize)
        #expect(plan.lowercaseModelCapital == row.lowercaseModel)
        #expect(plan.period == row.period)
        #expect(plan.caretKind == row.caret.kind)
    }

    @Test("D3: resolved decisions by word count")
    func resolvedByWordCount() {
        let empty = ContinuationPlanner.plan(caret: .endOfField(before: ""), rules: Self.prose)
        #expect(empty.resolved(wordCount: 2) == .init(firstWord: .capitalize, keepModelPeriod: false, keepAddedPeriod: false))
        #expect(empty.resolved(wordCount: 3) == .init(firstWord: .capitalize, keepModelPeriod: true, keepAddedPeriod: false))
        #expect(empty.resolved(wordCount: 4) == .init(firstWord: .capitalize, keepModelPeriod: true, keepAddedPeriod: true))
        let unknown = ContinuationPlanner.plan(caret: .unknown, rules: Self.prose)
        #expect(unknown.resolved(wordCount: 2) == .init(firstWord: .lowercase, keepModelPeriod: false, keepAddedPeriod: false))
        #expect(unknown.resolved(wordCount: 3) == .init(firstWord: .lowercaseAddedOnly, keepModelPeriod: true, keepAddedPeriod: false))
        let spoken = ContinuationPlanner.plan(caret: .unknown, rules: Self.prose,
                                              preferences: FormattingPreferences(unknownCaretStyle: .asSpoken))
        #expect(spoken.resolved(wordCount: 9) == .init(firstWord: .lowercase, keepModelPeriod: false, keepAddedPeriod: false))
        // Code/terminal roles: the formatter's output stands.
        #expect(unknown.resolved(wordCount: 1, textRole: false).firstWord == .lowercaseAddedOnly)
    }

    // MARK: - D6 spacing

    @Test("D6: automatic follows the table")
    func spacingAutomatic() {
        let prefs = FormattingPreferences(spacing: .automatic)
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "word"), rules: Self.prose, preferences: prefs).leading == " ")
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "word "), rules: Self.prose, preferences: prefs).leading == "")
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "("), rules: Self.prose, preferences: prefs).leading == "")
        #expect(ContinuationPlanner.plan(caret: .unknown, rules: Self.prose, preferences: prefs).leading == "")
    }

    @Test("D6: always adds a leading space except where one is already there")
    func spacingAlways() {
        let prefs = FormattingPreferences(spacing: .always)
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "word"), rules: Self.prose, preferences: prefs).leading == " ")
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "("), rules: Self.prose, preferences: prefs).leading == " ")
        #expect(ContinuationPlanner.plan(caret: .known(before: "un", after: "able"), rules: Self.prose, preferences: prefs).leading == " ")
        #expect(ContinuationPlanner.plan(caret: .known(before: "un", after: "able"), rules: Self.prose, preferences: prefs).trailing == " ")
        #expect(ContinuationPlanner.plan(caret: .unknown, rules: Self.prose, preferences: prefs).leading == " ")
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "word "), rules: Self.prose, preferences: prefs).leading == "")
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: ""), rules: Self.prose, preferences: prefs).leading == "")
    }

    @Test("D6: never adds a space on either side")
    func spacingNever() {
        let prefs = FormattingPreferences(spacing: .never)
        #expect(ContinuationPlanner.plan(caret: .endOfField(before: "word"), rules: Self.prose, preferences: prefs).leading == "")
        #expect(ContinuationPlanner.plan(caret: .known(before: "The", after: " cat"), rules: Self.prose, preferences: prefs).leading == "")
        #expect(ContinuationPlanner.plan(caret: .known(before: "The ", after: "cat"), rules: Self.prose, preferences: prefs).trailing == "")
        #expect(ContinuationPlanner.plan(caret: .unknown, rules: Self.prose, preferences: prefs).leading == "")
    }

    @Test("D6: the three modes end to end, and the setting survives the StageContext trip")
    func spacingEndToEnd() async throws {
        let caret = CaretState.endOfField(before: "I think")
        #expect(try await Self.land("we should go", caret, preferences: .init(spacing: .automatic)) == " we should go")
        #expect(try await Self.land("we should go", caret, preferences: .init(spacing: .always)) == " we should go")
        #expect(try await Self.land("we should go", caret, preferences: .init(spacing: .never)) == "we should go")
        #expect(try await Self.land("we should go", .unknown, preferences: .init(spacing: .always)) == " we should go")

        var context = StageContext()
        Self.field(.unknown, preferences: FormattingPreferences(spacing: .never, unknownCaretStyle: .asSpoken)).write(into: &context)
        let decoded = FieldContext(stageContext: context)
        #expect(decoded.caret == .unknown)
        #expect(decoded.spacing == .never)
        #expect(decoded.unknownCaretStyle == .asSpoken)
    }

    @Test("D1: a context without a caret key reads the text keys as a caret the caller saw")
    func legacyContext() {
        var context = StageContext()
        context.extra[FieldContext.Keys.textBefore] = "Hello"
        #expect(FieldContext(stageContext: context).caret == .endOfField(before: "Hello"))
        context.extra[FieldContext.Keys.textAfter] = "x"
        #expect(FieldContext(stageContext: context).caret == .known(before: "Hello", after: "x"))
        context.extra[FieldContext.Keys.caret] = "unknown"
        #expect(FieldContext(stageContext: context).caret == .unknown)
        #expect(FieldContext(stageContext: context).textBeforeCursor == "")
    }

    // MARK: - StyleStage gate (D2)

    static func styleContext(caret: String?, before: String = "") throws -> StageContext {
        var ctx = StageContext(register: .prose, appBundleID: notes)
        var profile = StyleProfile.coldStart(appBundleID: notes, category: .prose)
        profile.capitalizationRate = 1
        profile.terminalPeriodRate = 1
        ctx.extra[StyleStage.profileJSONKey] = try profile.encodedJSON()
        if let caret { ctx.extra[FieldContext.Keys.caret] = caret }
        ctx.extra[FieldContext.Keys.textBefore] = before
        return ctx
    }

    static func styled(_ ctx: StageContext) async throws -> String {
        try await StyleStage().process(heard("we left"), context: ctx).renderedText
    }

    @Test("D2: StyleStage runs only at endOfField after a terminal")
    func styleStageGate() async throws {
        #expect(try await Self.styled(Self.styleContext(caret: "endOfField", before: "Done. ")) == "We left.")
        #expect(try await Self.styled(Self.styleContext(caret: "endOfField", before: "Really?")) == "We left.")
        #expect(try await Self.styled(Self.styleContext(caret: "endOfField", before: "")) == "we left")
        #expect(try await Self.styled(Self.styleContext(caret: "endOfField", before: "Dear Sam,\n")) == "we left")
        #expect(try await Self.styled(Self.styleContext(caret: "endOfField", before: "I think")) == "we left")
        #expect(try await Self.styled(Self.styleContext(caret: "known", before: "Done. ")) == "we left")
        #expect(try await Self.styled(Self.styleContext(caret: "unknown")) == "we left")
        // No caret reading at all (the Lab, a run without a field): unchanged behaviour.
        #expect(try await Self.styled(Self.styleContext(caret: nil)) == "We left.")
    }

    @Test("D2: a learned no-period style never strips a dictated period")
    func styleKeepsSpokenPeriod() async throws {
        var ctx = StageContext(register: .chat, appBundleID: "com.tinyspeck.slackmacgap")
        var profile = StyleProfile.coldStart(appBundleID: "com.tinyspeck.slackmacgap", category: .chat)
        profile.terminalPeriodRate = 0
        ctx.extra[StyleStage.profileJSONKey] = try profile.encodedJSON()
        var spoken = Self.heard("see you then.")
        spoken[2].punctuationOrigin = .spoken
        #expect(try await StyleStage().process(spoken, context: ctx).renderedText.hasSuffix("then."))
        // H22: a learned no-period rate no longer strips a written period either.
        #expect(try await StyleStage().process(Self.heard("see you then."), context: ctx).renderedText.hasSuffix("then."))
    }

    @Test("D2: the field role path turns StyleStage off at an unknown caret")
    func fieldContextWritesTheGate() async throws {
        var ctx = try Self.styleContext(caret: nil)
        Self.field(.unknown).write(into: &ctx)
        #expect(try await Self.styled(ctx) == "we left")
        var end = try Self.styleContext(caret: nil)
        Self.field(.endOfField(before: "Done. ")).write(into: &end)
        #expect(try await Self.styled(end) == "We left.")
    }
}
