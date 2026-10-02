import Foundation
import Testing
@testable import Lab

/// N11-lab (F27) — the screen-terms report and the "off until measured" default.
@Suite("Screen terms report (N11-lab)")
struct ScreenTermsReportTests {
    static func counts(_ recalled: Int, of expected: Int = 13, fi: Int = 0, words: Int = 110) -> ContextRecallCounts {
        ContextRecallCounts(utterances: 10, entitiesExpected: expected, entitiesRecalled: recalled,
                            falseInsertions: fi, hypothesisWords: words)
    }

    static func report(none: Int = 8, matching: Int = 11, distractor: Int = 8, distractorFI: Int = 0) -> ScreenTermsReport {
        ScreenTermsReport(corpus: "entity+screens", recognizer: "tdt-v3+ctc-110m",
                          measuredAt: Date(timeIntervalSince1970: 1_790_000_000),
                          noScreen: counts(none), matchingScreen: counts(matching),
                          distractorScreen: counts(distractor, fi: distractorFI))
    }

    @Test func gainWithoutDistractorCostPasses() {
        let r = Self.report()
        #expect(r.passes)
        #expect(abs((r.recallGainPoints ?? 0) - 300.0 / 13) < 1e-9)
        #expect(r.table.contains("PASS"))
    }

    @Test func noGainFails() { #expect(!Self.report(matching: 8).passes) }

    @Test func distractorFalseInsertionsFail() {
        let r = Self.report(distractorFI: 2)   // 2/110 = +1.8 pp
        #expect(!r.passes)
        #expect(r.table.contains("FAIL"))
    }

    @Test func distractorRecallLossFails() { #expect(!Self.report(distractor: 7).passes) }

    @Test func unmeasuredOrEmptyReportsFail() {
        #expect(!ScreenTermsReport(corpus: "x", recognizer: "y").passes)
        #expect(!ScreenTermsDefault.enabled(by: nil))
    }

    @Test func defaultIsOffUntilAPassingReportIsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n11lab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = ScreenTermsDefault.url(in: dir)
        #expect(!ScreenTermsDefault.enabled(reportAt: url))
        try ScreenTermsDefault.save(Self.report(distractorFI: 3), to: url)
        #expect(!ScreenTermsDefault.enabled(reportAt: url))
        try ScreenTermsDefault.save(Self.report(), to: url)
        #expect(ScreenTermsDefault.enabled(reportAt: url))
        #expect(ScreenTermsDefault.load(from: url) == Self.report())
    }

    /// Counts only: the encoded report carries no term or transcript text.
    @Test func reportHoldsNoTerms() throws {
        let json = String(decoding: try JSONEncoder().encode(Self.report()), as: UTF8.self)
        let strings = json.matches(of: #/"[^"]*"\s*:\s*"([^"]*)"/#).map { String($0.output.1) }
        #expect(Set(strings) == ["entity+screens", "tdt-v3+ctc-110m"])
    }
}
