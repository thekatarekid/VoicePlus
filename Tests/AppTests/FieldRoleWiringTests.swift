import Foundation
import Testing
import Injection
import Pipeline
import Shared
@testable import VoicePlusApp

/// R4.2 wiring — the *live app path*, end to end with mocks: a focused element's AX hints →
/// `FieldContext` → the pipeline's `FieldRoleFormatterStage` → the text and the submit rule the
/// injector is handed.
///
/// The case that matters: VS Code's integrated terminal. The bundle ID says "editor", the AX
/// hint says "Terminal input", and terminal rules must win. Before this item nothing carried the
/// hint out of `Injection`, so the rule only ever fired in `Pipeline`'s own unit tests.
@Suite struct FieldRoleWiringTests {
    static let vsCode = "com.microsoft.VSCode"
    static let textEdit = "com.apple.TextEdit"

    /// Exactly the stage list `AppContainer.init` assembles for the formatter slot: the built-in
    /// stages with the register-routed formatters replaced by one `FieldRoleFormatterStage`.
    static func appPipeline() -> PipelineRunner {
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }
        return PipelineRunner(stages: FieldRolePipeline.replacingFormatters(in: builtIn))
    }

    static func stack(_ bundleID: String, field: MockSystemAccess.Field)
        -> (UtteranceLander, MockSystemAccess) {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 100, bundleID: bundleID,
                                                            appName: bundleID, elementToken: "el-1"))
        mock.field = field
        let lander = UtteranceLander(pipeline: appPipeline(), injector: TextInjector(system: mock),
                                     system: mock, repair: nil, flags: .inMemory(), database: nil)
        let reader = FieldContextReader(system: mock)
        lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
        return (lander, mock)
    }

    static func spans(_ text: String) -> [TranscriptSpan] {
        [TranscriptSpan(text: text, confidence: 0.95, audioRange: 0...1)]
    }

    // MARK: The headline case — a terminal inside an editor

    @Test func vsCodeIntegratedTerminalGetsTerminalRules() async {
        // Same app, same AX role as the editor pane below. Only the hint differs.
        let (lander, mock) = Self.stack(Self.vsCode,
                                        field: MockSystemAccess.Field(role: "AXTextArea", hints: ["Terminal input"]))
        let result = await lander.land(Self.spans("git commit dash dash amend"),
                                      startedAt: Date(), focus: mock.frontmost)
        #expect(result.fieldRole == .terminal)
        #expect(!result.allowSubmit)                                    // never press Return in a shell
        #expect(!result.text.hasSuffix("."))                            // no trailing period
        #expect(result.text.first?.isUppercase != true)                 // no auto-capitalization
        #expect(result.text.lowercased() == result.text)
    }

    @Test func theTerminalVerdictComesFromTheHintNotTheAppClass() async {
        // The proof that this is hint-driven: identical app, identical role, hints removed.
        let editor = MockSystemAccess.Field(role: "AXTextArea", hints: ["Monaco editor"])
        let (landerA, mockA) = Self.stack(Self.vsCode, field: editor)
        let a = await landerA.land(Self.spans("hello there"), startedAt: Date(), focus: mockA.frontmost)
        #expect(a.fieldRole == .codeEditor)
        #expect(a.fieldRole != .terminal)

        let terminal = MockSystemAccess.Field(role: "AXTextArea", hints: ["Terminal input"])
        let (landerB, mockB) = Self.stack(Self.vsCode, field: terminal)
        let b = await landerB.land(Self.spans("hello there"), startedAt: Date(), focus: mockB.frontmost)
        #expect(b.fieldRole == .terminal)

        // And with no hints at all, the app class decides — the pre-R4.2 behaviour, unchanged.
        let (landerC, mockC) = Self.stack(Self.vsCode, field: MockSystemAccess.Field(role: "AXTextArea"))
        let c = await landerC.land(Self.spans("hello there"), startedAt: Date(), focus: mockC.frontmost)
        #expect(c.fieldRole == .codeEditor)
    }

    @Test func anOrdinaryProseFieldStillGetsSentenceRules() async {
        // The contrast that shows terminal rules are rules, not a no-op everywhere.
        let (lander, mock) = Self.stack(Self.textEdit, field: MockSystemAccess.Field(role: "AXTextArea"))
        let result = await lander.land(Self.spans("hello there"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.fieldRole == .multilineText)
        #expect(result.text.hasPrefix("H"))
        #expect(result.text.hasSuffix("."))
    }

    // MARK: Continuation from the text before the caret

    @Test func midSentenceInsertionGetsALeadingSpaceNoCapitalAndNoPeriod() async {
        // Caret sits after "brown", with " jumps over" still to its right.
        let value = "The quick brown jumps over"
        let caret = "The quick brown".utf16.count
        let (lander, mock) = Self.stack(Self.textEdit,
                                        field: MockSystemAccess.Field(role: "AXTextArea", value: value,
                                                                      selection: caret..<caret))
        let result = await lander.land(Self.spans("and dusty"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.text.hasPrefix(" "))                             // never fuses with "brown"
        #expect(result.text == " and dusty")                            // no capital, no period
        #expect(mock.field.value == "The quick brown and dusty jumps over")
    }

    @Test func atTheStartOfAnEmptyFieldThereIsNoLeadingSpace() async {
        let (lander, mock) = Self.stack(Self.textEdit, field: MockSystemAccess.Field(role: "AXTextArea"))
        let result = await lander.land(Self.spans("hello there"), startedAt: Date(), focus: mock.frontmost)
        #expect(!result.text.hasPrefix(" "))
    }

    @Test func theCaretWindowIsReadInUTF16UnitsAroundTheCaret() {
        let value = "The quick brown jumps over"
        let caret = "The quick brown".utf16.count
        let (before, after) = FieldContextReader.textAroundCaret(value: value, range: caret..<caret, window: 400)
        #expect(before == "The quick brown")
        #expect(after == " jumps over")
        // Bounded: a huge field contributes only the window either side.
        let long = String(repeating: "x", count: 5_000)
        let (b2, a2) = FieldContextReader.textAroundCaret(value: long, range: 2_500..<2_500, window: 400)
        #expect(b2.count == 400)
        #expect(a2.count == 400)
        // No caret at all: the caret is the end of the value (appending is the safe reading).
        let (b3, a3) = FieldContextReader.textAroundCaret(value: "abc", range: nil, window: 400)
        #expect(b3 == "abc")
        #expect(a3.isEmpty)
        // A surrogate pair at the window edge is not sliced in half.
        let emoji = "ab\u{1F600}cd"
        let (b4, _) = FieldContextReader.textAroundCaret(value: emoji, range: nil, window: 3)
        #expect(!b4.contains("\u{FFFD}"))
    }

    // MARK: Secure fields yield nothing, and nothing is posted

    @Test("a password field yields no text and is never posted into", arguments: [false, true])
    func secureFieldYieldsNothing(webStyle: Bool) async {
        let (lander, mock) = Self.stack(Self.textEdit, field: .secure(webStyle: webStyle))
        let result = await lander.land(Self.spans("hunter two"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.fieldRole == .secure)
        #expect(result.text.isEmpty)
        #expect(!result.allowSubmit)
        #expect(result.injection == .refused(.secureField))             // the same verdict R2.3 reaches
        #expect(mock.postCount == 0)
        #expect(mock.journal.isEmpty)
        #expect(mock.field.value.isEmpty)
        #expect(!result.landed)
    }

    // MARK: One formatter, not two

    @Test func theAppPipelineRunsTheFieldRoleFormatterInsteadOfTheRegisterFormatters() {
        let stages = FieldRolePipeline.replacingFormatters(in: StageRegistry.allStages().filter { $0.id != .gatekeeper })
        let ids = stages.map(\.id)
        #expect(ids.contains(FieldRoleFormatterStage.stageID))
        #expect(ids.filter { $0 == FieldRoleFormatterStage.stageID }.count == 1)
        for replaced in FieldRolePipeline.replacedFormatterIDs {
            #expect(!ids.contains(replaced), "\(replaced) still in the list — spans would be formatted twice")
        }
        // Order is otherwise untouched: style remains the last pass (Bet 8).
        #expect(ids.last == .style)
        // Idempotent — assembling twice cannot add a second copy.
        #expect(FieldRolePipeline.replacingFormatters(in: stages).map(\.id) == ids)
    }

    @Test func theInnerFormatterRunsExactlyOncePerUtterance() async {
        let (lander, mock) = Self.stack(Self.textEdit, field: MockSystemAccess.Field(role: "AXTextArea"))
        let result = await lander.land(Self.spans("hello there"), startedAt: Date(), focus: mock.frontmost)
        // "Hello there." — a second prose pass would have appended a second period or re-cased it.
        #expect(result.text == "Hello there.")
        #expect(!result.text.hasSuffix(".."))
    }
}
