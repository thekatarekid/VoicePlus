import Foundation
import Testing
import Shared
@testable import Injection

/// N24 — rich paste keyed on the surface kind, never on app names: a table into a spreadsheet
/// cell (TSV + HTML), Markdown into a Markdown editor. Formula guard unless "equals" was said;
/// secure / terminal / chat surfaces never get a payload.
@Suite struct RichPasteN24Tests {
    static let tsv = "Name\tQty\nApples\t3\nPears\t5"
    static let pipe = "| Name | Qty |\n|---|---:|\n| Apples | 3 |\n| Pears | 5 |"

    // MARK: Pure planner

    @Test func tsvTableIntoSheetCellGetsTSVAndHTML() throws {
        let p = try #require(RichPaste.payload(for: Self.tsv, surface: .spreadsheetCell))
        #expect(p.kind == .spreadsheetTable)
        #expect(p.plainText == Self.tsv)
        #expect(p.html?.contains("<table><tr><td>Name</td><td>Qty</td></tr>") == true)
        #expect(p.html?.contains("<td>Pears</td><td>5</td>") == true)
    }

    @Test func markdownPipeTableIntoSheetBecomesTSV() throws {
        let p = try #require(RichPaste.payload(for: Self.pipe, surface: .spreadsheetCell))
        #expect(p.plainText == Self.tsv)
    }

    @Test func plainTextIntoSheetIsNotRich() {
        #expect(RichPaste.payload(for: "just a note", surface: .spreadsheetCell) == nil)
        #expect(RichPaste.payload(for: "one\ttwo", surface: .spreadsheetCell) == nil)        // one row
        #expect(RichPaste.payload(for: "a\tb\nc", surface: .spreadsheetCell) == nil)          // ragged
    }

    @Test func htmlIsEscaped() throws {
        let p = try #require(RichPaste.payload(for: "a<b\tx&y\n\"q\"\tz", surface: .spreadsheetCell))
        #expect(p.html?.contains("<td>a&lt;b</td><td>x&amp;y</td>") == true)
        #expect(p.html?.contains("&quot;q&quot;") == true)
    }

    @Test func formulaGuard() throws {
        let text = "Item\tValue\nTotal\t=SUM(B1:B2)\nHandle\t@me\nNeg\t-5\nCall\t+1 555\nDash\t-x"
        let guarded = try #require(RichPaste.payload(for: text, surface: .spreadsheetCell)?.plainText)
        #expect(guarded.contains("\t'=SUM(B1:B2)"))
        #expect(guarded.contains("\t'@me"))
        #expect(guarded.contains("\t-5"))          // a number stays a number
        #expect(guarded.contains("\t'+1 555"))
        #expect(guarded.contains("\t'-x"))
        let said = try #require(RichPaste.payload(for: text, surface: .spreadsheetCell, allowFormulas: true)?.plainText)
        #expect(said.contains("\t=SUM(B1:B2)"))
        #expect(said.contains("\t'@me"))           // "equals" only frees `=`
    }

    @Test func markdownIntoMarkdownEditor() throws {
        let md = "# Plan\n- one\n- two"
        let p = try #require(RichPaste.payload(for: md, surface: .markdownEditor))
        #expect(p.kind == .markdown)
        #expect(p.plainText == md)
        #expect(p.types[RichPaste.markdownType] == Data(md.utf8))
        #expect(RichPaste.payload(for: "Just one plain sentence.", surface: .markdownEditor) == nil)
    }

    @Test func tsvIntoMarkdownEditorBecomesPipeTable() throws {
        let p = try #require(RichPaste.payload(for: Self.tsv, surface: .markdownEditor))
        #expect(p.plainText == "| Name | Qty |\n| --- | --- |\n| Apples | 3 |\n| Pears | 5 |")
    }

    @Test(arguments: [SurfaceKind.terminal, .secure, .chatComposer, .urlBar, .searchField, .canvas,
                      .codeEditor, .prose, .emailBody, .formField(label: "text")])
    func otherSurfacesNeverRich(_ kind: SurfaceKind) {
        #expect(RichPaste.payload(for: Self.tsv, surface: kind) == nil)
        #expect(RichPaste.payload(for: "# H\n- a", surface: kind) == nil)
    }

    @Test func noSurfaceNoPayload() {
        #expect(RichPaste.payload(for: Self.tsv, surface: nil) == nil)
    }

    // MARK: Through the injector

    @Test func sheetCellTablePastesRichFirstWithMarkersAndRestores() {
        let (injector, mock, _) = makeStack("com.unknown.Grid")
        mock.setPasteboard([PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data("mine".utf8)])])
        _ = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost, surfaceKind: .spreadsheetCell))
        let write = mock.pasteboardWrites.last
        #expect(write?.types[RichPaste.htmlType] != nil, "\(mock.journal)")
        #expect(PasteboardMarkers.all.allSatisfy { write?.types[$0] != nil })
        #expect(mock.journal.contains { $0.hasPrefix("key.combo") && $0.hasSuffix("+cmd") })
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        #expect(mock.pasteboardString == "mine")    // user's clipboard back after settle
    }

    @Test func sameTableInAnotherAppNameStillKeyedOnKind() {
        // Keyed on the surface kind: a well-known spreadsheet app with a prose surface gets no table.
        let (injector, mock, _) = makeStack("com.unknown.Grid")
        _ = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost, surfaceKind: .prose))
        #expect(mock.pasteboardWrites.allSatisfy { $0.types[RichPaste.htmlType] == nil })
    }

    @Test func markdownEditorPastesMarkdown() {
        let (injector, mock, _) = makeStack("com.unknown.Notes")
        _ = injector.inject(InjectionRequest(text: "# Plan\n- one\n- two", expectedFocus: mock.frontmost, surfaceKind: .markdownEditor))
        #expect(mock.pasteboardWrites.last?.types[RichPaste.markdownType] != nil, "\(mock.journal)")
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
    }

    @Test func secureFieldNeverPastedEvenWithTable() {
        let (injector, mock, _) = makeStack("com.unknown.Grid") { $0.field = MockSystemAccess.Field(role: "AXSecureTextField") }
        let outcome = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost, surfaceKind: .spreadsheetCell))
        #expect(mock.pasteboardWrites.isEmpty)
        #expect(!outcome.succeeded)
    }

    @Test func terminalNeverRich() {
        let (injector, mock, _) = makeStack("com.apple.Terminal")
        _ = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost, surfaceKind: .terminal))
        #expect(mock.pasteboardWrites.allSatisfy { $0.types[RichPaste.htmlType] == nil })
    }
}
