import Foundation

// R4.1b — the ranked context list's numbers, in the form Lab and the Benchmark tab (R4.3) render.
//
// Deliberately **counts only**. `Lab` cannot see `Engine` (one-way dependency in `Package.swift`),
// which here is a feature rather than a limitation: the type that gets encoded, displayed and
// possibly written next to a benchmark run has no field that could hold a harvested term. Screen
// text cannot reach diagnostics through this file because it cannot be put into it (V3 §7.3).
//
// The measurement that fills it in runs in `Tests/EngineTests/ContextRecallCorpusTests.swift`,
// where the real recognizer, the real corpus and `ContextRanker` all exist.

/// Entity recall and false insertions for one arm of the comparison (with, or without, the list).
public struct ContextRecallCounts: Codable, Equatable, Sendable {
    public var utterances: Int
    /// Reference entities the arm was scored against (identical in both arms, by construction).
    public var entitiesExpected: Int
    public var entitiesRecalled: Int
    /// List terms present in the hypothesis and absent from the reference.
    public var falseInsertions: Int
    public var hypothesisWords: Int

    public init(utterances: Int = 0, entitiesExpected: Int = 0, entitiesRecalled: Int = 0,
                falseInsertions: Int = 0, hypothesisWords: Int = 0) {
        self.utterances = utterances
        self.entitiesExpected = entitiesExpected
        self.entitiesRecalled = entitiesRecalled
        self.falseInsertions = falseInsertions
        self.hypothesisWords = hypothesisWords
    }

    /// Recalled / expected; nil when nothing was expected (never 0, which would read as a failure).
    public var entityRecall: Double? {
        entitiesExpected == 0 ? nil : Double(entitiesRecalled) / Double(entitiesExpected)
    }

    /// False insertions per hypothesis word.
    public var falseInsertionRate: Double {
        hypothesisWords == 0 ? 0 : Double(falseInsertions) / Double(hypothesisWords)
    }

    public mutating func record(entitiesExpected expected: Int, recalled: Int,
                                falseInsertions inserted: Int, hypothesisWords words: Int) {
        utterances += 1
        entitiesExpected += expected
        entitiesRecalled += recalled
        falseInsertions += inserted
        hypothesisWords += words
    }

    public static func + (a: ContextRecallCounts, b: ContextRecallCounts) -> ContextRecallCounts {
        ContextRecallCounts(utterances: a.utterances + b.utterances,
                            entitiesExpected: a.entitiesExpected + b.entitiesExpected,
                            entitiesRecalled: a.entitiesRecalled + b.entitiesRecalled,
                            falseInsertions: a.falseInsertions + b.falseInsertions,
                            hypothesisWords: a.hypothesisWords + b.hypothesisWords)
    }
}

/// The whole R4.1b acceptance in one value: both arms, the prompt's size against its cap, and
/// whether the pair passes.
public struct ContextRecallReport: Codable, Equatable, Sendable {
    /// Corpus the numbers came from, e.g. `real-room/builtin`. Not a transcript, not a term.
    public var corpus: String
    /// Recognizer that produced pass 1.
    public var recognizer: String
    /// Terms in the largest ranked list built during the run.
    public var largestList: Int
    /// The list cap in force (400).
    public var listCap: Int
    /// Longest prompt built during the run, in characters.
    public var longestPromptCharacters: Int
    /// The prompt's character cap.
    public var promptCap: Int
    public var withoutList: ContextRecallCounts
    public var withList: ContextRecallCounts

    public init(corpus: String, recognizer: String, largestList: Int = 0, listCap: Int = 400,
                longestPromptCharacters: Int = 0, promptCap: Int = 1_000,
                withoutList: ContextRecallCounts = .init(), withList: ContextRecallCounts = .init()) {
        self.corpus = corpus
        self.recognizer = recognizer
        self.largestList = largestList
        self.listCap = listCap
        self.longestPromptCharacters = longestPromptCharacters
        self.promptCap = promptCap
        self.withoutList = withoutList
        self.withList = withList
    }

    /// Recall gained by adding the list, in percentage points. Nil when nothing was expected.
    public var recallGainPoints: Double? {
        guard let with = withList.entityRecall, let without = withoutList.entityRecall else { return nil }
        return (with - without) * 100
    }

    /// False insertions the list cost (negative means it removed some).
    public var falseInsertionDelta: Int { withList.falseInsertions - withoutList.falseInsertions }

    /// Both caps held.
    public var withinCaps: Bool { largestList <= listCap && longestPromptCharacters <= promptCap }

    /// The gate R4.1b asks for: the list must raise recall and must not add false insertions
    /// faster than it adds recall, and both caps must hold.
    public var passes: Bool {
        guard withinCaps, let gain = recallGainPoints else { return false }
        return gain >= 0 && withList.falseInsertions <= withoutList.falseInsertions + withList.utterances
    }

    /// Fixed-width table for the console and the Benchmark tab.
    public var table: String {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        func lead(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
        func recall(_ counts: ContextRecallCounts) -> String {
            counts.entityRecall.map { String(format: "%.3f", $0) } ?? "n/a"
        }
        var out = "== R4.1b ranked context list · \(corpus) · pass 1 = \(recognizer) ==\n"
        out += "arm           utts  entities  recalled  recall  falseIns    rate  words\n"
        for (name, counts) in [("without list", withoutList), ("with list", withList)] {
            out += pad(name, 13)
                + lead("\(counts.utterances)", 5)
                + lead("\(counts.entitiesExpected)", 10)
                + lead("\(counts.entitiesRecalled)", 10)
                + lead(recall(counts), 8)
                + lead("\(counts.falseInsertions)", 10)
                + lead(String(format: "%.4f", counts.falseInsertionRate), 8)
                + lead("\(counts.hypothesisWords)", 7) + "\n"
        }
        let gain = recallGainPoints.map { String(format: "%+.1f", $0) } ?? "n/a"
        out += "recall gain \(gain) pp · false insertions "
            + String(format: "%+d", falseInsertionDelta)
            + " · list \(largestList)/\(listCap) · prompt \(longestPromptCharacters)/\(promptCap) chars · "
            + (passes ? "PASS" : "FAIL")
        return out
    }
}
