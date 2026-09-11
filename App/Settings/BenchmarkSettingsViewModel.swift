import Combine
import Foundation
import Lab

/// R4.3 — Benchmark tab: renders R4.1b's ranked-context-list counters
/// (`Lab/Harness/ContextRecallReport.swift`).
///
/// This view model does not run the corpus measurement — `Tests/EngineTests/
/// ContextRecallCorpusTests.swift` owns that, against real audio and a real model, and `Lab`
/// cannot see `Engine` at all (one-way dependency in `Package.swift`). It only *displays* the one
/// completed run recorded there, or the honest "no measurements yet" empty state (`DESIGN.md`
/// §9.4) when handed none.
@MainActor
public final class BenchmarkViewModel: ObservableObject {
    /// One arm of the comparison, reduced to display strings so nothing here needs to re-derive
    /// a number `ContextRecallReport` already computed.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String { arm }
        public var arm: String
        public var recallText: String
        public var falseInsertions: Int
        public var hypothesisWords: Int
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var corpusLabel: String?
    @Published public private(set) var recallGainText: String?
    @Published public private(set) var passLabel: String?
    public var hasData: Bool { !rows.isEmpty }

    public init(report: ContextRecallReport? = nil) { load(report) }

    public func load(_ report: ContextRecallReport?) {
        guard let report else {
            rows = []; corpusLabel = nil; recallGainText = nil; passLabel = nil
            return
        }
        corpusLabel = "\(report.corpus) · \(report.recognizer) · list \(report.largestList)/\(report.listCap)"
        rows = [
            Row(arm: "without the ranked list", recallText: Self.recallText(report.withoutList),
                falseInsertions: report.withoutList.falseInsertions, hypothesisWords: report.withoutList.hypothesisWords),
            Row(arm: "with the ranked list", recallText: Self.recallText(report.withList),
                falseInsertions: report.withList.falseInsertions, hypothesisWords: report.withList.hypothesisWords),
        ]
        recallGainText = report.recallGainPoints.map { String(format: "%+.1f pp recall, %+d false insertions", $0, report.falseInsertionDelta) }
        passLabel = report.passes ? "Within budget" : "Over budget"
    }

    private static func recallText(_ c: ContextRecallCounts) -> String {
        guard let recall = c.entityRecall else { return "n/a" }
        return String(format: "%.3f (%d/%d)", recall, c.entitiesRecalled, c.entitiesExpected)
    }

    /// R4.1b's measured run — `Tests/EngineTests/ContextRecallCorpusTests.swift`, 11 September
    /// 2026, `real-room/builtin` (20 utterances, 10 curated entities), Parakeet TDT 0.6B v3 pass 1:
    /// without the list, recall 0.600 (6/10), 2 false insertions; with it, recall 0.800 (8/10),
    /// 6 false insertions. Rendered here; never re-derived here — see the file comment above.
    public static let lastMeasured = ContextRecallReport(
        corpus: "real-room/builtin", recognizer: "parakeetTDTv3",
        largestList: 189, listCap: 400, longestPromptCharacters: 1_000, promptCap: 1_000,
        withoutList: ContextRecallCounts(utterances: 20, entitiesExpected: 10, entitiesRecalled: 6, falseInsertions: 2, hypothesisWords: 223),
        withList: ContextRecallCounts(utterances: 20, entitiesExpected: 10, entitiesRecalled: 8, falseInsertions: 6, hypothesisWords: 222))
}
