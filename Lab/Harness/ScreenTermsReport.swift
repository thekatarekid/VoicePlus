import Foundation
import Shared

// N11-lab (F27) — the on-screen-words measurement, in the form Lab and the Benchmark tab render.
//
// Counts only, like `ContextRecallReport`: no field can hold a screen term or a transcript. The
// measurement itself (`ScreenTermsExperiment` in Engine) runs the entity suite with no screen, a
// screen showing the spoken entity, and a distractor screen, through the CTC rescorer.
//
// Screen terms stay out of the boost list by default. `ScreenTermsDefault.enabled` turns them on
// only when a measured report on disk passes this gate.

public struct ScreenTermsReport: Codable, Equatable, Sendable {
    /// Corpus the numbers came from, e.g. `entity+screens`.
    public var corpus: String
    /// Recognizer + rescorer that produced the hypotheses.
    public var recognizer: String
    public var measuredAt: Date
    public var noScreen: ContextRecallCounts
    public var matchingScreen: ContextRecallCounts
    public var distractorScreen: ContextRecallCounts

    /// Minimum recall gain (percentage points) from a matching screen before the feature is worth it.
    public static let minRecallGainPoints = 1.0
    /// Maximum false-insertion-rate increase a distractor screen may cost (0.5 pp, as V5 B1).
    public static let maxFalseInsertionRateIncrease = 0.005

    public init(corpus: String, recognizer: String, measuredAt: Date = Date(),
                noScreen: ContextRecallCounts = .init(), matchingScreen: ContextRecallCounts = .init(),
                distractorScreen: ContextRecallCounts = .init()) {
        self.corpus = corpus
        self.recognizer = recognizer
        self.measuredAt = measuredAt
        self.noScreen = noScreen
        self.matchingScreen = matchingScreen
        self.distractorScreen = distractorScreen
    }

    /// Recall gained when the spoken entity is on screen, in percentage points.
    public var recallGainPoints: Double? {
        guard let with = matchingScreen.entityRecall, let without = noScreen.entityRecall else { return nil }
        return (with - without) * 100
    }

    /// Recall change caused by a distractor screen (should be ~0; negative means it hurt).
    public var distractorRecallDeltaPoints: Double? {
        guard let d = distractorScreen.entityRecall, let without = noScreen.entityRecall else { return nil }
        return (d - without) * 100
    }

    /// False-insertion-rate increase on distractor screens.
    public var distractorFalseInsertionIncrease: Double {
        distractorScreen.falseInsertionRate - noScreen.falseInsertionRate
    }

    /// False-insertion-rate increase on matching screens.
    public var matchingFalseInsertionIncrease: Double {
        matchingScreen.falseInsertionRate - noScreen.falseInsertionRate
    }

    /// The gate for turning screen terms on by default: a real recall gain, no recall loss on
    /// distractors, and false insertions within 0.5 pp on both screen arms.
    public var passes: Bool {
        guard noScreen.utterances > 0, matchingScreen.utterances == noScreen.utterances,
              distractorScreen.utterances == noScreen.utterances,
              let gain = recallGainPoints, let distractorDelta = distractorRecallDeltaPoints else { return false }
        return gain >= Self.minRecallGainPoints
            && distractorDelta >= 0
            && distractorFalseInsertionIncrease <= Self.maxFalseInsertionRateIncrease
            && matchingFalseInsertionIncrease <= Self.maxFalseInsertionRateIncrease
    }

    public var table: String {
        func pad(_ t: String, _ w: Int) -> String { t.count >= w ? t : t + String(repeating: " ", count: w - t.count) }
        func lead(_ t: String, _ w: Int) -> String { t.count >= w ? t : String(repeating: " ", count: w - t.count) + t }
        var out = "== N11 screen terms (F27) · \(corpus) · \(recognizer) ==\n"
        out += "arm               utts  entities  recalled  recall  falseIns    rate\n"
        for (name, c) in [("no screen", noScreen), ("matching screen", matchingScreen), ("distractor screen", distractorScreen)] {
            out += pad(name, 17) + lead("\(c.utterances)", 5) + lead("\(c.entitiesExpected)", 10)
                + lead("\(c.entitiesRecalled)", 10)
                + lead(c.entityRecall.map { String(format: "%.3f", $0) } ?? "n/a", 8)
                + lead("\(c.falseInsertions)", 10) + lead(String(format: "%.4f", c.falseInsertionRate), 8) + "\n"
        }
        let gain = recallGainPoints.map { String(format: "%+.1f", $0) } ?? "n/a"
        out += "recall gain \(gain) pp · distractor false-insertion rate "
            + String(format: "%+.2f", distractorFalseInsertionIncrease * 100) + " pp · "
            + (passes ? "PASS (screen terms may default on)" : "FAIL (screen terms stay off)")
        return out
    }
}

/// Whether screen terms join the per-turn boost layer by default (F27: off until measured).
public enum ScreenTermsDefault {
    public static let fileName = "screen-terms-lab.json"

    public static func url(in directory: URL = AppPaths.supportDirectory()) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// On only when a measured report exists and passes.
    public static func enabled(by report: ScreenTermsReport?) -> Bool { report?.passes ?? false }

    public static func enabled(reportAt url: URL = url()) -> Bool { enabled(by: load(from: url)) }

    public static func load(from url: URL = url()) -> ScreenTermsReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ScreenTermsReport.self, from: data)
    }

    public static func save(_ report: ScreenTermsReport, to url: URL = url()) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(report).write(to: url, options: .atomic)
    }
}
