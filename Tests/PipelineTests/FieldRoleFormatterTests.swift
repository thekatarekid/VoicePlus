import Foundation
import Testing
@testable import Pipeline
import Shared

/// R4.2 — unit tests for the decisions the goldens then pin down end to end.
struct FieldRoleFormatterTests {

    static func field(_ bundle: String?, role: String? = nil, subrole: String? = nil, hints: [String] = [],
                      before: String = "", after: String = "", multiline: Bool? = nil,
                      submits: Bool? = nil, paragraph: Bool = false) -> FieldContext {
        FieldContext(appBundleID: bundle, axRole: role, axSubrole: subrole, hints: hints,
                     isMultiline: multiline, submitsOnReturn: submits,
                     textBeforeCursor: before, textAfterCursor: after, paragraphIntent: paragraph)
    }

    static func spans(_ words: String) -> [TranscriptSpan] {
        words.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.95,
                           audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), provenance: [.asr])
        }
    }

    // MARK: - Role beats app

    @Test("a terminal role inside an editor gets terminal rules")
    func terminalInsideEditor() {
        let vsCodeTerminal = Self.field("com.microsoft.VSCode", role: "AXTextArea", hints: ["Terminal input"])
        let rules = FieldRules.rules(for: vsCodeTerminal)
        #expect(rules.role == .terminal)
        #expect(rules.category == .terminal)
        #expect(rules.autoCapitalize == false)
        #expect(rules.trailingPeriod == false)
        #expect(rules.allowSubmit == false)
        #expect(rules.preserveIdentifiers)

        // Same app, the editor surface: code rules.
        let editor = Self.field("com.microsoft.VSCode", role: "AXTextArea", hints: ["Monaco editor"])
        #expect(FieldRules.rules(for: editor).role == .codeEditor)
        #expect(FieldRules.rules(for: editor).category == .code)
    }

    @Test("a terminal is never submitted, even when the caller says the field submits on Return")
    func terminalNeverSubmits() {
        for hint in ["Terminal input", "xterm-screen", "Console", "swift repl", "shell prompt"] {
            let f = Self.field("com.microsoft.VSCode", role: "AXTextArea", hints: [hint], submits: true)
            let rules = FieldRules.rules(for: f)
            #expect(rules.role == .terminal, "\(hint) should read as a terminal")
            #expect(rules.allowSubmit == false, "\(hint) must never submit")
        }
    }

    @Test("app class still decides for ordinary text fields")
    func appClassForPlainFields() {
        #expect(FieldRules.rules(for: Self.field("com.apple.mail", role: "AXTextArea")).category == .mail)
        #expect(FieldRules.rules(for: Self.field("com.tinyspeck.slackmacgap", role: "AXTextField", multiline: false)).category == .chat)
        #expect(FieldRules.rules(for: Self.field("com.apple.Notes", role: "AXTextArea")).category == .prose)
        #expect(FieldRules.rules(for: Self.field("com.apple.Terminal", role: "AXTextArea")).role == .terminal)
        // A find field in an IDE is a one-line field, not the code surface.
        #expect(FieldRules.rules(for: Self.field("com.microsoft.VSCode", role: "AXTextField")).role == .singleLineText)
    }

    @Test("a secure field refuses dictation")
    func secureFieldRefuses() async throws {
        let f = Self.field("com.apple.Safari", role: "AXTextField", subrole: "AXSecureTextField")
        let rules = FieldRules.rules(for: f)
        #expect(rules.refusesDictation)
        let result = try await FieldRoleFormatter().format(Self.spans("hunter two"), field: f)
        #expect(result.spans.map(\.text) == ["hunter", "two"])   // untouched
        #expect(result.text.isEmpty)                             // and nothing to inject
        #expect(result.allowSubmit == false)
    }

    @Test("chat composers are the one role allowed to submit")
    func chatMaySubmit() {
        #expect(FieldRules.rules(for: Self.field("com.tinyspeck.slackmacgap", role: "AXTextField", multiline: false)).allowSubmit)
        #expect(FieldRules.rules(for: Self.field("com.apple.Safari", role: "AXSearchField")).allowSubmit)
        #expect(FieldRules.rules(for: Self.field("com.apple.mail", role: "AXTextArea", submits: true)).allowSubmit == false)
    }

    // MARK: - Continuation

    static let prose = FieldRules(category: .prose, autoCapitalize: true, trailingPeriod: true,
                                  allowSubmit: false, allowParagraphBreak: true, preserveIdentifiers: false)

    @Test("mid-sentence insertion gets a space and no capital")
    func midSentence() {
        let plan = ContinuationPlanner.plan(before: "The number that matters is", rules: Self.prose)
        #expect(plan.leading == " ")
        #expect(plan.capitalizeFirstWord == false)
        #expect(plan.paragraphBreak == false)
    }

    @Test("after a sentence end the first word is capitalized")
    func afterSentenceEnd() {
        #expect(ContinuationPlanner.plan(before: "It was cold. ", rules: Self.prose).capitalizeFirstWord)
        #expect(ContinuationPlanner.plan(before: "It was cold.", rules: Self.prose).leading == " ")
        #expect(ContinuationPlanner.plan(before: "It was cold.", rules: Self.prose).capitalizeFirstWord)
        #expect(ContinuationPlanner.plan(before: "He said \"go.\"", rules: Self.prose).capitalizeFirstWord)
        #expect(ContinuationPlanner.plan(before: "", rules: Self.prose).capitalizeFirstWord)
        #expect(ContinuationPlanner.plan(before: "", rules: Self.prose).leading == "")
    }

    @Test("an abbreviation's period does not start a sentence")
    func abbreviations() {
        for tail in ["for the cache, e.g.", "spoke to Dr.", "and so on, etc"] {
            #expect(ContinuationPlanner.plan(before: tail, rules: Self.prose).capitalizeFirstWord == false, Comment(rawValue: tail))
        }
        #expect(ContinuationPlanner.endsSentence("and so on, etc.") == false)
        #expect(ContinuationPlanner.endsSentence("signed, J.") == false)
        #expect(ContinuationPlanner.endsSentence("that is the point!"))
    }

    @Test("line starts and openers")
    func lineStartsAndOpeners() {
        #expect(ContinuationPlanner.plan(before: "first line\n", rules: Self.prose).leading == "")
        #expect(ContinuationPlanner.plan(before: "first line\n", rules: Self.prose).capitalizeFirstWord)
        // `--save` + `dev` must not become `-- save dev`.
        let terminal = FieldRules(category: .terminal, autoCapitalize: false, trailingPeriod: false,
                                  allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: true)
        #expect(ContinuationPlanner.plan(before: "npm install --", rules: terminal).leading == "")
        #expect(ContinuationPlanner.plan(before: "cd ~/", rules: terminal).leading == "")
        #expect(ContinuationPlanner.plan(before: "cd ~/Dev", rules: terminal).leading == " ")
    }

    @Test("a paragraph break is a blank line, and is not doubled up")
    func paragraphBreak() {
        #expect(ContinuationPlanner.plan(before: "Done.", paragraphIntent: true, rules: Self.prose).leading == "\n\n")
        #expect(ContinuationPlanner.plan(before: "Done.\n", paragraphIntent: true, rules: Self.prose).leading == "\n")
        #expect(ContinuationPlanner.plan(before: "Done.\n\n", paragraphIntent: true, rules: Self.prose).leading == "")
        // A single-line field never gets a newline.
        let chat = FieldRules(category: .chat, autoCapitalize: true, trailingPeriod: false,
                              allowSubmit: true, allowParagraphBreak: false, preserveIdentifiers: false)
        #expect(ContinuationPlanner.plan(before: "Done.", paragraphIntent: true, rules: chat).leading == " ")
    }

    @Test("a trailing space is added only when text follows the caret")
    func trailingSpace() {
        #expect(ContinuationPlanner.plan(before: "is", after: "on the first request.", rules: Self.prose).trailing == " ")
        #expect(ContinuationPlanner.plan(before: "is", after: " on the first request.", rules: Self.prose).trailing == "")
        #expect(ContinuationPlanner.plan(before: "is", after: "", rules: Self.prose).trailing == "")
        #expect(ContinuationPlanner.plan(before: "is", after: ", really", rules: Self.prose).trailing == "")
    }

    @Test("no trailing period when inserting into the middle of a sentence")
    func noPeriodMidSentence() {
        let f = Self.field("com.apple.mail", role: "AXTextArea", before: "The number is", after: "on first load.")
        #expect(FieldRules.rules(for: f).trailingPeriod == false)
        let atEnd = Self.field("com.apple.mail", role: "AXTextArea", before: "Hello. ")
        #expect(FieldRules.rules(for: atEnd).trailingPeriod)
    }

    // MARK: - Identifiers

    @Test("identifier shapes are recognised, ordinary words are not")
    func identifierDetection() {
        for id in ["user_session_token", "camelCase", "--hidden", "-m", "Fixtures/transcripts",
                   "$HOME", "std::vector", "AppPaths.swift", "NSURLSession"] {
            #expect(CodeIdentifier.looksLikeIdentifier(id), Comment(rawValue: id))
        }
        for word in ["cache", "cold", "Thursday", "OK", "I", "yes,", "cold.", "hello!"] {
            #expect(CodeIdentifier.looksLikeIdentifier(word) == false, Comment(rawValue: word))
        }
    }

    @Test("the terminal formatter's lowercasing does not damage identifiers")
    func identifiersSurviveTerminal() async throws {
        let f = Self.field("com.apple.Terminal", role: "AXTextArea")
        let input = Self.spans("rg camelCase user_session_token Fixtures/transcripts --hidden")
        let out = try await FieldRoleFormatter().format(input, field: f)
        #expect(out.text == "rg camelCase user_session_token Fixtures/transcripts --hidden")
        #expect(ConfidenceContract.verify(input: input, output: out.spans).isEmpty)
    }

    @Test("restoration is boundary-aware and leaves unrelated text alone")
    func restorationBoundaries() {
        #expect(CodeIdentifier.replacing("camelCase", in: "the camelcase token") == "the camelCase token")
        #expect(CodeIdentifier.replacing("camelCase", in: "notcamelcase") == "notcamelcase")
        #expect(CodeIdentifier.replacing("camelCase", in: "nothing here") == "nothing here")
    }

    // MARK: - Stage contract

    @Test("the stage appends its id and keeps confidence, audioRange and provenance")
    func stageContract() async throws {
        var context = StageContext(register: .unknown)
        Self.field("com.microsoft.VSCode", role: "AXTextArea", hints: ["Terminal input"],
                   before: "cd ~/Developer && ").write(into: &context)
        let input = Self.spans("git status")
        let out = try await FieldRoleFormatterStage().process(input, context: context)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out.allSatisfy { $0.provenance.first == .asr })
        #expect(out.allSatisfy { $0.provenance.last == FieldRoleFormatterStage.stageID })
        #expect(out.allSatisfy { $0.provenance.contains(.formatterTerminal) })
    }

    @Test("a low-confidence span is never rewritten and never loses its audio range")
    func lowConfidencePassthrough() async throws {
        let f = Self.field("com.apple.mail", role: "AXTextArea", before: "It was cold. ")
        var input = Self.spans("the memoized value was stale")
        input[1].confidence = 0.41
        let out = try await FieldRoleFormatter().format(input, field: f)
        #expect(ConfidenceContract.verify(input: input, output: out.spans).isEmpty)
        #expect(out.spans.contains { $0.text == "memoized" })
        #expect(out.spans.contains { $0.needsRepair } || out.spans.contains { $0.confidence == 0.41 })
    }

    @Test("the field context survives a round trip through StageContext")
    func contextRoundTrip() {
        let original = Self.field("com.microsoft.VSCode", role: "AXTextArea", subrole: nil,
                                  hints: ["Terminal input", "xterm-screen"], before: "cd ~/ ", after: "x",
                                  multiline: true, submits: false, paragraph: true)
        var context = StageContext()
        original.write(into: &context)
        let decoded = FieldContext(stageContext: context)
        #expect(decoded.appBundleID == original.appBundleID)
        #expect(decoded.axRole == original.axRole)
        #expect(decoded.hints == original.hints)
        #expect(decoded.textBeforeCursor == original.textBeforeCursor)
        #expect(decoded.textAfterCursor == original.textAfterCursor)
        #expect(decoded.isMultiline == true)
        #expect(decoded.submitsOnReturn == false)
        #expect(decoded.paragraphIntent)
    }
}
