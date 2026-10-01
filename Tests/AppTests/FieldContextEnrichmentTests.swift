import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 E2/E3/E4 — `FieldContextReader` carries the form label, the Sheets URL and the column header
/// out of the accessibility tree, and notes bundle IDs the category table had to guess for.
@Suite("V5 E2/E3/E4 · field context enrichment")
struct FieldContextEnrichmentTests {

    final class MockDetails: FocusedFieldDetailsReading {
        var labels: [String] = []
        var header: String?
        private(set) var labelReads = 0
        private(set) var headerReads = 0
        func focusedFieldLabels(pid: Int32) -> [String] { labelReads += 1; return labels }
        func focusedCellColumnHeader(pid: Int32) -> String? { headerReads += 1; return header }
    }

    private func system(bundle: String, role: String, hints: [String] = [], url: String? = nil) -> MockSystemAccess {
        let s = MockSystemAccess(frontmost: FocusSnapshot(pid: 7777, bundleID: bundle, appName: "App", elementToken: "el"))
        s.field = .init(role: role, value: "", hints: hints)
        s.documentURL = url
        return s
    }

    @Test
    func webFormLabelJoinsTheHintsAndDrivesTheRules() throws {
        let details = MockDetails()
        details.labels = ["Email address", "you@example.com"]
        let reader = FieldContextReader(system: system(bundle: "com.google.Chrome", role: "AXTextField"),
                                        unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.google.Chrome"))
        #expect(field.hints.contains("Email address"))
        #expect(FieldRules.rules(for: field).inputKind == .email)
    }

    @Test
    func passwordLabelRefusesThroughTheReader() throws {
        let details = MockDetails()
        details.labels = ["Password"]
        let reader = FieldContextReader(system: system(bundle: "com.google.Chrome", role: "AXTextField"),
                                        unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.google.Chrome"))
        #expect(FieldRules.rules(for: field).refusesDictation)
    }

    @Test
    func secureFieldGetsNoExtraReads() throws {
        let details = MockDetails()
        let s = system(bundle: "com.google.Chrome", role: "AXTextField")
        s.field = .secure(webStyle: true)
        let reader = FieldContextReader(system: s, unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        _ = reader.fieldContext(bundleID: "com.google.Chrome")
        #expect(details.labelReads == 0 && details.headerReads == 0)
    }

    @Test
    func sheetsCellGetsURLAndColumnHeader() throws {
        let details = MockDetails()
        details.header = "Q3 Revenue"
        let s = system(bundle: "com.google.Chrome", role: "AXTextArea",
                       url: "https://docs.google.com/spreadsheets/d/abc/edit")
        let reader = FieldContextReader(system: s, unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.google.Chrome"))
        #expect(field.documentURL?.contains("/spreadsheets") == true)
        #expect(FieldRole.classify(field) == .spreadsheetCell)
        #expect(field.columnHeader == "Q3 Revenue")
        var ctx = StageContext()
        FieldRolePipeline.write(field, into: &ctx)
        #expect(ctx.extra[FieldContext.Keys.columnHeader] == "Q3 Revenue", "context hint for the cleanup prompt")
    }

    @Test
    func nativeAppsAreNotAskedForADocumentURLOrHeader() throws {
        let details = MockDetails()
        details.header = "never"
        let s = system(bundle: "com.apple.TextEdit", role: "AXTextArea", url: "https://docs.google.com/spreadsheets/d/x")
        let reader = FieldContextReader(system: s, unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.apple.TextEdit"))
        #expect(field.documentURL == nil)
        #expect(field.columnHeader == nil)
        #expect(details.headerReads == 0)
    }

    @Test
    func excelCellReadsTheHeader() throws {
        let details = MockDetails()
        details.header = "Units"
        let reader = FieldContextReader(system: system(bundle: "com.microsoft.Excel", role: "AXCell"),
                                        unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.microsoft.Excel"))
        #expect(FieldRules.rules(for: field).role == .spreadsheetCell)
        #expect(field.columnHeader == "Units")
    }

    @Test
    func unknownBundleIsNotedOnce() {
        let log = UnknownApps(log: Log(category: "test"))
        let reader = FieldContextReader(system: system(bundle: "com.example.mystery", role: "AXTextArea"),
                                        unknownApps: log)
        _ = reader.fieldContext(bundleID: "com.example.mystery")
        _ = reader.fieldContext(bundleID: "com.example.mystery")
        #expect(log.recorded == ["com.example.mystery": .prose])
    }
}
