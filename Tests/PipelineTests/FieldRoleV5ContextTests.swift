import Foundation
import Testing
@testable import Pipeline
import Shared

/// V5 E2 (spreadsheet cell), E3 (web form labels), E4 (AppCategoryTable coverage).
@Suite("V5 E2/E3/E4 · field roles from screen context")
struct FieldRoleV5ContextTests {

    static func spans(_ words: String, confidence: Float = 0.95) -> [TranscriptSpan] {
        words.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), provenance: [.asr])
        }
    }

    // MARK: - E2 · classification

    @Test("AXCell, a 'cell' role description, Excel, Numbers and Sheets are cells",
          arguments: [
            FieldContext(appBundleID: "com.example.any", axRole: "AXCell"),
            FieldContext(appBundleID: "com.example.any", axRole: "AXTextArea", hints: ["cell"]),
            FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXTextArea"),
            FieldContext(appBundleID: "com.apple.iWork.Numbers", axRole: "AXTable"),
            FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                         documentURL: "https://docs.google.com/spreadsheets/d/abc/edit#gid=0"),
          ])
    func cellsClassify(field: FieldContext) {
        #expect(FieldRole.classify(field) == .spreadsheetCell)
    }

    @Test("search boxes in a spreadsheet, Google Docs and ordinary fields are not cells",
          arguments: [
            FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXSearchField"),
            FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXTextField", hints: ["Search"]),
            FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                         documentURL: "https://docs.google.com/document/d/abc/edit"),
            FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea"),
          ])
    func nonCells(field: FieldContext) {
        #expect(FieldRole.classify(field) != .spreadsheetCell)
    }

    @Test
    func aCellNamedConsoleIsStillACell() {
        let field = FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXCell", hints: ["Console"])
        #expect(FieldRole.classify(field) == .spreadsheetCell)
    }

    @Test
    func cellRules() {
        let rules = FieldRules.rules(for: FieldContext(appBundleID: "com.apple.iWork.Numbers", axRole: "AXCell"))
        #expect(rules.role == .spreadsheetCell)
        #expect(rules.autoCapitalize == false)
        #expect(rules.trailingPeriod == false)
        #expect(rules.allowSubmit == false)
        #expect(rules.alwaysNormalizeNumbers)
        #expect(rules.newlineInCell)
        #expect(rules.refusesDictation == false)
    }

    @Test
    func cellNeverSubmitsEvenWhenTheFieldClaimsTo() {
        let field = FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXCell", submitsOnReturn: true)
        #expect(FieldRules.rules(for: field).allowSubmit == false)
    }

    @Test
    func documentURLAndColumnHeaderRoundTripThroughStageContext() {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                                 documentURL: "https://docs.google.com/spreadsheets/d/x", columnHeader: "Revenue")
        var ctx = StageContext()
        field.write(into: &ctx)
        #expect(ctx.extra[FieldContext.Keys.columnHeader] == "Revenue")
        let back = FieldContext(stageContext: ctx)
        #expect(back.documentURL == field.documentURL)
        #expect(back.columnHeader == "Revenue")
        #expect(FieldRole.classify(back) == .spreadsheetCell)
    }

    // MARK: - E2 · formatting

    @Test
    func shortLabelKeepsItsCaseAndGetsNoPeriod() async throws {
        let field = FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXCell")
        let out = try await FieldRoleFormatter().format(Self.spans("total revenue"), field: field)
        #expect(out.text == "total revenue")
        #expect(out.allowSubmit == false)
    }

    @Test
    func numbersBecomeDigitsInACell() async throws {
        let field = FieldContext(appBundleID: "com.apple.iWork.Numbers", axRole: "AXCell")
        let out = try await FieldRoleFormatter().format(Self.spans("five units"), field: field)
        #expect(out.text == "5 units")
    }

    @Test
    func aSpokenPeriodStaysInACell() async throws {
        let field = FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXCell")
        let out = try await FieldRoleFormatter().format(Self.spans("done period"), field: field)
        #expect(out.text.hasSuffix("."))
    }

    // MARK: - E3 · labels

    @Test("hint words map to input kinds", arguments: [
        (["Email address"], FieldInputKind.email), (["E-mail"], .email), (["Phone number"], .phone),
        (["Telephone"], .phone), (["Website URL"], .url), (["Search mail"], .search),
        (["Password"], .password), (["Enter your passcode"], .password),
    ])
    func inputKinds(hints: [String], kind: FieldInputKind) {
        #expect(FieldInputKind.from(hints: hints) == kind)
    }

    @Test("words inside other words do not count", arguments: [["curl options"], ["hotel name"], ["Subject"], []])
    func noFalseKinds(hints: [String]) {
        #expect(FieldInputKind.from(hints: hints) == nil)
    }

    @Test
    func passwordByLabelIsRefused() async throws {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextField", hints: ["Password"])
        let rules = FieldRules.rules(for: field)
        #expect(rules.role == .secure)
        #expect(rules.refusesDictation)
        let out = try await FieldRoleFormatter().format(Self.spans("hunter two"), field: field)
        #expect(out.text.isEmpty)
    }

    @Test
    func aPasswordLabelOnAButtonIsNotASecureField() {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXButton", hints: ["Show password"])
        #expect(FieldRole.classify(field) != .secure)
    }

    @Test
    func emailFieldCompactsTheAddress() async throws {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextField", hints: ["Email"])
        let input = Self.spans("jo dot smith at example dot com")
        let out = try await FieldRoleFormatter().format(input, field: field)
        #expect(out.text == "jo.smith@example.com")
        #expect(out.rules.trailingPeriod == false && out.rules.autoCapitalize == false)
        #expect(ConfidenceContract.verify(input: input, output: out.spans).isEmpty)
    }

    @Test
    func urlFieldCompacts() async throws {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextField", hints: ["Website"])
        let out = try await FieldRoleFormatter().format(Self.spans("example dot com slash pricing"), field: field)
        #expect(out.text == "example.com/pricing")
    }

    @Test
    func lowConfidenceBlocksCompaction() {
        let input = Self.spans("jo at example dot com", confidence: 0.3)
        #expect(FieldValueCompactor.compact(input, kind: .email) == input)
    }

    @Test
    func phoneFieldUsesDigits() async throws {
        let field = FieldContext(appBundleID: "com.apple.Safari", axRole: "AXTextField", hints: ["Phone"])
        let out = try await FieldRoleFormatter().format(Self.spans("call five"), field: field)
        #expect(out.text.contains("5"))
        #expect(!out.text.hasSuffix("."))
    }

    @Test
    func searchLabelGetsNoPeriodButNoSubmitEither() {
        let field = FieldContext(appBundleID: "com.apple.Safari", axRole: "AXTextField", hints: ["Search"],
                                 textBeforeCursor: "", textAfterCursor: "")
        let rules = FieldRules.rules(for: field)
        #expect(rules.trailingPeriod == false)
        #expect(rules.allowSubmit == false, "a label is weaker evidence than AXSearchField")
    }

    // MARK: - E4 · coverage

    @Test("named apps are in the exact table", arguments: [
        ("company.thebrowser.Browser", AppCategory.prose), ("com.brave.Browser", .prose),
        ("com.microsoft.edgemac", .prose), ("com.linear", .prose), ("notion.id", .prose),
        ("com.figma.Desktop", .prose), ("us.zoom.xos", .chat), ("com.microsoft.teams", .chat),
        ("com.microsoft.teams2", .chat), ("com.apple.FaceTime", .chat), ("com.apple.iWork.Numbers", .prose),
        ("com.microsoft.Excel", .prose), ("com.apple.iWork.Keynote", .prose), ("com.apple.iWork.Pages", .prose),
        ("com.todesktop.230313mzl4w4u92", .code), ("com.exafunction.windsurf", .code),
        ("com.mitchellh.ghostty", .terminal), ("dev.warp.Warp-Stable", .terminal), ("dev.warp.Warp", .terminal),
    ])
    func coverage(bundleID: String, category: AppCategory) {
        #expect(AppCategoryTable.isKnown(bundleID))
        #expect(AppCategoryTable.category(for: bundleID) == category)
    }

    @Test
    func tableHasGrownBySixty() {
        #expect(AppCategoryTable.exact.count >= 38 + 60)
    }

    @Test
    func unknownAppsFallBackToProseAndAreNotedOnce() {
        let log = UnknownApps(log: Log(category: "test.unknownApps"))
        #expect(AppCategoryTable.categoryNotingUnknown(for: "com.example.never-heard-of", log: log) == .prose)
        #expect(AppCategoryTable.categoryNotingUnknown(for: "com.example.never-heard-of", log: log) == .prose)
        #expect(log.recorded == ["com.example.never-heard-of": .prose])
        #expect(log.note("com.example.never-heard-of", guessed: .prose) == false)
        _ = AppCategoryTable.categoryNotingUnknown(for: "com.apple.Notes", log: log)
        #expect(log.recorded["com.apple.Notes"] == nil, "known apps are not noted")
    }
}
