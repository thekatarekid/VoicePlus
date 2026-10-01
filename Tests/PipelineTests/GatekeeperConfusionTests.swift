import Foundation
import Testing
import Shared
@testable import Pipeline

/// H2 — the live gatekeeper's confusion matrix on 200 scripted utterances
/// (`Fixtures/gatekeeper/h2-scripted.tsv`: 50 each of dictate / command / edit / note), plus a
/// route-threshold sweep. Threshold tuning only; nothing is trained on this set.
///
/// `VOICEPLUS_WRITE_RESULTS=1 swift test --filter GatekeeperConfusion` rewrites
/// `Lab/results/h2-gatekeeper-confusion.{json,md}`; a plain run only asserts.
@Suite("Gatekeeper confusion matrix (H2)")
struct GatekeeperConfusionTests {
    struct Row { let cls: String; let expected: Utterance.Route; let text: String }

    static let classes = ["dictate", "command", "edit", "note"]
    static let routes = Utterance.Route.allCases.map(\.rawValue)
    static let sweep: [Double] = stride(from: 0.40, through: 0.951, by: 0.05).map { ($0 * 100).rounded() / 100 }

    static func corpus() throws -> [Row] {
        let dir = try #require(AppPaths.fixturesDirectory())
        let text = try String(contentsOf: dir.appendingPathComponent("gatekeeper/h2-scripted.tsv"), encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            #expect(f.count == 3, "bad row: \(line)")
            return Row(cls: f[0], expected: try #require(Utterance.Route(rawValue: f[1])), text: f[2])
        }
    }

    struct Result: Codable {
        var threshold: Double
        var matrix: [String: [String: Int]]   // class -> predicted route -> count
        var accuracy: Double
        var perClassAccuracy: [String: Double]
        /// Dictation or notes routed to a command/transform: the destructive error (text eaten).
        var falseCommands: Int
        /// Commands/edits typed in as dictation: the annoying error (command text lands in the doc).
        var missedCommands: Int
        var misses: [String]
    }

    static func run(_ rows: [Row], threshold: Double) -> Result {
        let stage = GatekeeperStage(local: LocalGatekeeper(routeThreshold: threshold))
        var matrix = Dictionary(uniqueKeysWithValues: classes.map { ($0, Dictionary(uniqueKeysWithValues: routes.map { ($0, 0) })) })
        var correct = 0, falseCommands = 0, missedCommands = 0
        var perClass: [String: Int] = [:]
        var misses: [String] = []
        for row in rows {
            let span = TranscriptSpan(text: row.text, confidence: 0.9, audioRange: 0...1)
            let route = stage.decide([span], context: StageContext()).route
            matrix[row.cls, default: [:]][route.rawValue, default: 0] += 1
            if route == row.expected {
                correct += 1; perClass[row.cls, default: 0] += 1
            } else {
                misses.append("\(row.cls) → \(route.rawValue): \(row.text)")
                if row.expected == .dictate, route == .repairCommand || route == .transform { falseCommands += 1 }
                if row.expected != .dictate, route == .dictate || route == .none { missedCommands += 1 }
            }
        }
        let n = Dictionary(grouping: rows, by: \.cls).mapValues(\.count)
        return Result(threshold: threshold, matrix: matrix, accuracy: Double(correct) / Double(rows.count),
                      perClassAccuracy: Dictionary(uniqueKeysWithValues: classes.map { ($0, Double(perClass[$0] ?? 0) / Double(n[$0] ?? 1)) }),
                      falseCommands: falseCommands, missedCommands: missedCommands, misses: misses)
    }

    @Test func corpusIsTwoHundredBalancedAndUnseen() throws {
        let rows = try Self.corpus()
        #expect(rows.count == 200)
        for c in Self.classes { #expect(rows.filter { $0.cls == c }.count == 50, "class \(c)") }
        let seed = Set(GatekeeperSeedCorpus.routes.map { $0.1.lowercased() })
        #expect(rows.filter { seed.contains($0.text.lowercased()) }.isEmpty, "H2 set must not repeat the seed corpus")
    }

    @Test func shippedThresholdMatrix() throws {
        let rows = try Self.corpus()
        let shipped = Self.run(rows, threshold: LocalGatekeeper.shared.routeThreshold)
        let swept = Self.sweep.map { Self.run(rows, threshold: $0) }
        // Regression floors measured on 2026-10-01 at the shipped threshold (see Lab/results).
        #expect(shipped.accuracy >= 0.97, "accuracy \(shipped.accuracy)")
        #expect(shipped.falseCommands <= 2, "dictation eaten as a command: \(shipped.falseCommands)")
        if ProcessInfo.processInfo.environment["VOICEPLUS_WRITE_RESULTS"] == "1" {
            try Self.write(shipped: shipped, sweep: swept)
        }
    }

    static func write(shipped: Result, sweep: [Result]) throws {
        let dir = try #require(AppPaths.fixturesDirectory()).deletingLastPathComponent()
            .appendingPathComponent("Lab/results", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        struct Doc: Codable {
            let item = "H2"; let model = "LocalGatekeeper (rules + naive Bayes seed corpus)"
            let set = "Fixtures/gatekeeper/h2-scripted.tsv (200 scripted, 50/class)"
            let date: String; let shipped: Result; let sweep: [Result]
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        try enc.encode(Doc(date: String(date), shipped: shipped, sweep: sweep))
            .write(to: dir.appendingPathComponent("h2-gatekeeper-confusion.json"))
        var md = "# H2 · Gatekeeper confusion matrix (\(date))\n\n"
        md += "Set: `Fixtures/gatekeeper/h2-scripted.tsv` — 200 scripted utterances, 50 per class. Notes are expected "
        md += "to route as dictation (the gatekeeper has no note route; note ownership is O2/O3). Threshold tuning only.\n\n"
        md += "## Shipped threshold \(shipped.threshold)\n\n| class \\ predicted | " + routes.joined(separator: " | ") + " | acc |\n"
        md += "|---|" + routes.map { _ in "---" }.joined(separator: "|") + "|---|\n"
        for c in classes {
            md += "| \(c) | " + routes.map { String(shipped.matrix[c]?[$0] ?? 0) }.joined(separator: " | ")
            md += String(format: " | %.2f |\n", shipped.perClassAccuracy[c] ?? 0)
        }
        md += String(format: "\nOverall %.3f · false commands (dictation eaten) %d · missed commands %d\n\n",
                     shipped.accuracy, shipped.falseCommands, shipped.missedCommands)
        md += "## Route-threshold sweep\n\n| threshold | accuracy | false commands | missed commands |\n|---|---|---|---|\n"
        for r in sweep { md += String(format: "| %.2f | %.3f | %d | %d |\n", r.threshold, r.accuracy, r.falseCommands, r.missedCommands) }
        md += "\n## Misses at the shipped threshold\n\n" + shipped.misses.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try md.write(to: dir.appendingPathComponent("h2-gatekeeper-confusion.md"), atomically: true, encoding: .utf8)
    }
}
