import Foundation
import Testing
import Shared
@testable import Injection

/// Q1 (P0, safety) — a dictated paragraph break must never send half a message (Claude, Slack,
/// Cursor) or commit a Google Sheets cell. The keystroke stream for these apps contains no bare ↩:
/// no unicode `\n`/`\r` keystroke and no plain Return combo.
@Suite struct NewlineSafetyTests {
    static let twoParagraphs = "First paragraph.\n\nSecond line one\nSecond line two"

    /// Every journal entry that would type a bare ↩.
    static func bareReturns(_ journal: [String]) -> [String] {
        journal.filter { entry in
            if entry.hasPrefix("key.unicode"), let payload = entry.split(separator: ":", maxSplits: 1).last {
                return payload.contains("\n") || payload.contains("\r")
            }
            return entry.hasPrefix("key.combo") && entry.hasSuffix(":36")
        }
    }

    static func combos(_ journal: [String]) -> [String] {
        journal.filter { $0.hasPrefix("key.combo") }.map { String($0.split(separator: ":").last ?? "") }
    }

    @Test(arguments: ["com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode",
                      "com.todesktop.230313mzl4w4u92", "com.brave.Browser", "com.google.Chrome"])
    func multiParagraphPayloadHasNoBareReturn(bundleID: String) {
        let (injector, mock, _) = makeStack(bundleID) { $0.axReadable = true; $0.keystrokesWork = true }
        let outcome = injector.inject(InjectionRequest(text: Self.twoParagraphs, expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(Self.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        // Paragraph break = ⇧↩ twice, single line break = ⇧↩ once: three in all.
        #expect(Self.combos(mock.journal) == Array(repeating: "36+shift", count: 3), "\(mock.journal)")
        #expect(mock.field.value == Self.twoParagraphs)
    }

    @Test func googleSheetsCellGetsOptionReturn() {
        let (injector, mock, _) = makeStack("com.google.Chrome") {
            $0.axReadable = true
            $0.documentURL = "https://docs.google.com/spreadsheets/d/abc123/edit#gid=0"
        }
        _ = injector.inject(InjectionRequest(text: "line one\nline two", expectedFocus: mock.frontmost))
        #expect(Self.bareReturns(mock.journal).isEmpty)
        #expect(Self.combos(mock.journal) == ["36+opt"])
        #expect(mock.field.value == "line one\nline two")
    }

    @Test func googleDocsInABrowserIsNotASheet() {
        #expect(!NewlineSafety.isSpreadsheetDocument("https://docs.google.com/document/d/x/edit"))
        #expect(NewlineSafety.isSpreadsheetDocument("https://docs.google.com/spreadsheets/d/x/edit"))
        #expect(!NewlineSafety.isSpreadsheetDocument("https://evil.example/docs.google.com/spreadsheets"))
        #expect(!NewlineSafety.isSpreadsheetDocument(nil))
        #expect(ChromiumAdapter().newlineCombo(focused: nil) == .shiftReturn)
    }

    @Test func otherLineSeparatorsAreNormalisedThenSafe() {
        #expect(NewlineSafety.normalize("a\r\nb\rc\u{2028}d\u{2029}e") == "a\nb\nc\nd\n\ne")
        let (injector, mock, _) = makeStack("com.anthropic.claudefordesktop")
        _ = injector.inject(InjectionRequest(text: "one\r\ntwo\u{2029}three", expectedFocus: mock.frontmost))
        #expect(Self.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        #expect(Self.combos(mock.journal).count == 3)
    }

    @Test func singleLineTextIsOneUnicodeBurstAsBefore() {
        let (injector, mock, _) = makeStack("com.anthropic.claudefordesktop")
        _ = injector.inject(InjectionRequest(text: "hello there", expectedFocus: mock.frontmost))
        #expect(mock.journal.filter { $0.hasPrefix("key.") } == ["key.unicode(100):hello there"])
    }

    /// TextEdit (DefaultAdapter, AX first) is untouched: the text goes in as one AX write, newlines
    /// and all, exactly as before.
    @Test func textEditPathUnchanged() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let outcome = injector.inject(InjectionRequest(text: Self.twoParagraphs, expectedFocus: mock.frontmost))
        #expect(outcome == .injected(method: .ax, verified: true))
        #expect(!mock.journal.contains { $0.hasPrefix("key.") })
        #expect(mock.field.value == Self.twoParagraphs)
        #expect(!(AdapterRegistry.standard().adapter(for: "com.apple.TextEdit") is NewlineSafeAdapter))
    }

    @Test func allowSubmitStaysFalseForSendOnReturnApps() {
        for id in ["com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.todesktop.230313mzl4w4u92",
                   "com.google.Chrome", "com.brave.Browser.beta"] {
            #expect(SubmitPolicy.allowSubmit(requested: true, bundleID: id) == false, "\(id)")
        }
        #expect(SubmitPolicy.allowSubmit(requested: true, bundleID: "com.apple.Safari"))
        #expect(SubmitPolicy.allowSubmit(requested: false, bundleID: "com.apple.Safari") == false)
    }
}
