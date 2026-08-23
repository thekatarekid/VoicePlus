import Foundation
import Testing
import Shared
@testable import Lab

@Suite struct CLITests {
    let runner = LabRunner(clock: { 0 }, hardware: "cli-hw", thermal: { .nominal })

    @Test func argParsing() throws {
        let o = try LabCLI.parse(["--name", "x", "--flags=contextBiasing=on,voiceRepair=off", "--json"])
        #expect(o == ["name": "x", "flags": "contextBiasing=on,voiceRepair=off", "json": "true"])
        #expect(throws: LabError.badArguments("unexpected argument 'run'")) { try LabCLI.parse(["run"]) }
        let cfg = try LabCLI.makeConfig(o, name: "n")
        #expect(cfg.flags == ["contextBiasing": true, "voiceRepair": false])
        #expect(cfg.suites == FixtureSuite.defaultNames)
    }

    @Test func suitesCommand() async {
        let out = await LabCLI.main(["suites"], runner: runner)
        #expect(out.exitCode == 0)
        #expect(out.text.split(separator: "\n").contains("entity"))
    }

    @Test func runProducesMarkdownAndJSONAndFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lab-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outFile = dir.appendingPathComponent("report.md").path
        let md = await LabCLI.main(["run", "--name", "smoke", "--transcriber", "degraded", "--suites", "clean,technical", "--out", outFile], runner: runner)
        #expect(md.exitCode == 0, Comment(rawValue: md.text))
        #expect(md.text.hasPrefix("# Lab report — smoke"))
        #expect(md.text.contains("| clean | 12 |") && md.text.contains("| technical | 10 |") && md.text.contains("| all | 22 |"))
        #expect(md.text.contains("## Worst items"))
        #expect(try String(contentsOfFile: outFile, encoding: .utf8) == md.text)

        let js = await LabCLI.main(["run", "--transcriber", "perfect", "--suites", "entity", "--format", "json"], runner: runner)
        #expect(js.exitCode == 0)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let report = try dec.decode(LabReport.self, from: Data(js.text.utf8))
        #expect(report.overall.wer == 0 && report.overall.items == 10)
    }

    @Test func compareRunsFlagOnAndOffAndPersists() async throws {
        let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString).sqlite").path
        let out = await LabCLI.main(["compare", "--flag", "contextBiasing", "--suites", "entity", "--db", dbPath], runner: runner)
        #expect(out.exitCode == 0, Comment(rawValue: out.text))
        #expect(out.reports.map(\.config.name) == ["contextBiasing=on", "contextBiasing=off"])
        #expect(out.reports[0].config.flags == ["contextBiasing": true])
        #expect(out.text.hasPrefix("# Lab comparison"))
        #expect(out.text.contains("| WER | 0.0% | 0.0% |"))
        let db = try AppDatabase.open(at: URL(fileURLWithPath: dbPath))
        #expect(try db.labRuns().map(\.name).sorted() == ["contextBiasing=off", "contextBiasing=on"])
    }

    @Test func errorsReportUsage() async {
        let a = await LabCLI.main(["run", "--transcriber", "nope"], runner: runner)
        #expect(a.exitCode == 2 && a.text.contains("unknown transcriber") && a.text.contains("usage:"))
        let b = await LabCLI.main(["compare"], runner: runner)
        #expect(b.exitCode == 2 && b.text.contains("--flag"))
        let c = await LabCLI.main(["run", "--stages", "ghost"], runner: runner)
        #expect(c.exitCode == 2 && c.text.contains("unknown stage"))
        let d = await LabCLI.main([], runner: runner)
        #expect(d.exitCode == 1)
    }
}
