import Foundation
import Testing
import Shared
@testable import Lab

/// R4.1b — the shape Lab and the Benchmark tab (R4.3) read the ranked list's numbers in.
///
/// `Lab` cannot import `Engine`, which is why the measurement itself lives in
/// `Tests/EngineTests/ContextRecallCorpusTests.swift` (real recognizer, real corpus, real ranker)
/// and this file covers the arithmetic, the gate and — the point of the split — that the type
/// carrying the numbers out of the measurement has nowhere to put a harvested term.
@Suite("Context recall report (R4.1b)")
struct ContextRecallReportTests {

    static func report(withoutRecalled: Int, withRecalled: Int, expected: Int = 20,
                       withoutFalse: Int = 0, withFalse: Int = 0,
                       largestList: Int = 118, longestPrompt: Int = 640) -> ContextRecallReport {
        ContextRecallReport(
            corpus: "real-room/builtin",
            recognizer: "parakeet-tdt-0.6b-v3",
            largestList: largestList,
            longestPromptCharacters: longestPrompt,
            withoutList: ContextRecallCounts(utterances: 20, entitiesExpected: expected,
                                             entitiesRecalled: withoutRecalled,
                                             falseInsertions: withoutFalse, hypothesisWords: 220),
            withList: ContextRecallCounts(utterances: 20, entitiesExpected: expected,
                                          entitiesRecalled: withRecalled,
                                          falseInsertions: withFalse, hypothesisWords: 220))
    }

    // MARK: arithmetic

    @Test
    func recallAndRateAreCountsOverCounts() {
        var counts = ContextRecallCounts()
        #expect(counts.entityRecall == nil, "no entities expected must read as n/a, not as zero recall")
        #expect(counts.falseInsertionRate == 0)
        counts.record(entitiesExpected: 4, recalled: 3, falseInsertions: 1, hypothesisWords: 10)
        counts.record(entitiesExpected: 6, recalled: 3, falseInsertions: 0, hypothesisWords: 30)
        #expect(counts.utterances == 2)
        #expect(counts.entitiesExpected == 10)
        #expect(counts.entitiesRecalled == 6)
        #expect(counts.entityRecall == 0.6)
        #expect(counts.falseInsertionRate == 0.025)
        let doubled = counts + counts
        #expect(doubled.entitiesRecalled == 12)
        #expect(doubled.entityRecall == 0.6)
    }

    @Test
    func gainIsInPercentagePointsAndDeltaIsSigned() {
        let report = Self.report(withoutRecalled: 12, withRecalled: 16, withoutFalse: 1, withFalse: 3)
        #expect(report.withoutList.entityRecall == 0.6)
        #expect(report.withList.entityRecall == 0.8)
        let gain = try? #require(report.recallGainPoints)
        #expect(abs((gain ?? 0) - 20) < 1e-9)
        #expect(report.falseInsertionDelta == 2)
    }

    // MARK: the gate

    @Test
    func aListThatCostsRecallFails() {
        #expect(Self.report(withoutRecalled: 16, withRecalled: 12).passes == false)
        #expect(Self.report(withoutRecalled: 12, withRecalled: 12).passes)
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16).passes)
    }

    @Test
    func aListThatBreaksACapFails() {
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16, largestList: 401).passes == false)
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16, longestPrompt: 1_001).passes == false)
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16, largestList: 400,
                            longestPrompt: 1_000).withinCaps)
    }

    @Test
    func aListThatInsertsMoreThanOneWordPerUtteranceFails() {
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16, withFalse: 20).passes)
        #expect(Self.report(withoutRecalled: 12, withRecalled: 16, withFalse: 21).passes == false)
    }

    @Test
    func anUnmeasuredReportDoesNotPass() {
        #expect(Self.report(withoutRecalled: 0, withRecalled: 0, expected: 0).passes == false)
    }

    // MARK: rendering and privacy

    @Test
    func theTableCarriesBothArmsAndTheVerdict() {
        let table = Self.report(withoutRecalled: 12, withRecalled: 16, withFalse: 2).table
        #expect(table.contains("without list"))
        #expect(table.contains("with list"))
        #expect(table.contains("real-room/builtin"))
        #expect(table.contains("parakeet-tdt-0.6b-v3"))
        #expect(table.contains("+20.0"))
        #expect(table.contains("PASS"))
        #expect(Self.report(withoutRecalled: 16, withRecalled: 12).table.contains("FAIL"))
    }

    /// V3 §7.3 — the report is what leaves the measurement and may be shown, encoded or filed next
    /// to a benchmark run. It must be arithmetically incapable of carrying screen text: every field
    /// is a number, apart from the corpus and recognizer names the caller supplies.
    @Test
    func theEncodedReportHasNowhereToPutATerm() throws {
        let data = try JSONEncoder().encode(Self.report(withoutRecalled: 12, withRecalled: 16))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stringValued = object.filter { $0.value is String }.keys.sorted()
        #expect(stringValued == ["corpus", "recognizer"])
        for (key, value) in object where !(value is String) {
            #expect(value is [String: Any] || value is NSNumber, "\(key) is neither a number nor counts")
        }
        let arms = ["withList", "withoutList"]
        for arm in arms {
            let counts = try #require(object[arm] as? [String: Any])
            #expect(counts.values.allSatisfy { $0 is NSNumber }, "\(arm) carries something that is not a count")
        }
        let round = try JSONDecoder().decode(ContextRecallReport.self, from: data)
        #expect(round == Self.report(withoutRecalled: 12, withRecalled: 16))
    }
}
