import Foundation

/// JSON + Markdown renderers for one report or an A/B comparison of several.
public enum ReportWriter {
    public static func json(_ report: LabReport) throws -> String {
        String(decoding: try LabReport.jsonEncoder.encode(report), as: UTF8.self)
    }

    public static func json(_ reports: [LabReport]) throws -> String {
        String(decoding: try LabReport.jsonEncoder.encode(reports), as: UTF8.self)
    }

    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    static func ms(_ v: Double) -> String { String(format: "%.0f ms", v) }

    public static func markdown(_ report: LabReport) -> String {
        var out = "# Lab report — \(report.config.name)\n\n"
        out += "- Transcriber: `\(report.config.transcriber)`\n"
        out += "- Stages: \(report.config.stages.isEmpty ? "none" : report.config.stages.map { "`\($0)`" }.joined(separator: " → "))\n"
        out += "- Flags: \(report.config.flags.isEmpty ? "defaults" : report.config.flags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        out += "- Hardware: \(report.hardware)\n"
        out += "- Thermal during run: \(report.thermalStates.joined(separator: ", "))\n\n"
        out += "| Suite | Items | WER | Entity recall | False-entity | Zero-edit | p50 | p95 |\n|---|---|---|---|---|---|---|---|\n"
        for s in report.suites + [report.overall] {
            out += "| \(s.suite) | \(s.items) | \(pct(s.wer)) | \(pct(s.entityRecall)) | \(pct(s.falseEntityRate)) | \(pct(s.zeroEditRate)) | \(ms(s.latencyP50Ms)) | \(ms(s.latencyP95Ms)) |\n"
        }
        if !report.stageLatencyMs.isEmpty {
            out += "\n## Stage latency (mean)\n\n"
            for stage in report.config.stages {
                out += "- `\(stage)`: \(ms(report.stageLatencyMs[stage] ?? 0))\n"
            }
        }
        let worst = report.items.filter { $0.wer > 0 }.sorted { $0.wer > $1.wer }.prefix(10)
        if !worst.isEmpty {
            out += "\n## Worst items\n\n| File | WER | Reference | Hypothesis |\n|---|---|---|---|\n"
            for i in worst { out += "| \(i.file) | \(pct(i.wer)) | \(i.reference) | \(i.hypothesis) |\n" }
        }
        return out
    }

    /// Side-by-side comparison (e.g. biasing on vs off). Columns are configs, rows are metrics.
    public static func comparison(_ reports: [LabReport]) -> String {
        guard !reports.isEmpty else { return "(no reports)\n" }
        var out = "# Lab comparison\n\n| Metric | " + reports.map(\.config.name).joined(separator: " | ") + " |\n"
        out += "|---|" + String(repeating: "---|", count: reports.count) + "\n"
        func row(_ label: String, _ f: (LabReport) -> String) { out += "| \(label) | " + reports.map(f).joined(separator: " | ") + " |\n" }
        row("WER") { pct($0.overall.wer) }
        row("Entity recall") { pct($0.overall.entityRecall) }
        row("False-entity rate") { pct($0.overall.falseEntityRate) }
        row("Zero-edit (predicted)") { pct($0.overall.zeroEditRate) }
        row("Latency p50") { ms($0.overall.latencyP50Ms) }
        row("Latency p95") { ms($0.overall.latencyP95Ms) }
        let suiteNames = Array(NSOrderedSet(array: reports.flatMap { $0.suites.map(\.suite) })) as? [String] ?? []
        for s in suiteNames {
            row("\(s) WER") { r in pct(r.suites.first { $0.suite == s }?.wer) }
            row("\(s) entity recall") { r in pct(r.suites.first { $0.suite == s }?.entityRecall) }
        }
        return out
    }
}
