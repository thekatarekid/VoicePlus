import SwiftUI
import Shared

/// Run / compare configurations, waterfall, thermal readout. Pure SwiftUI; hostable in any window.
public struct LabPanelView: View {
    @ObservedObject var model: LabPanelViewModel

    public init(model: LabPanelViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("The Lab").font(.title2.bold())
                Spacer()
                ThermalReadoutView(readout: model.thermal)
            }
            GroupBox("Configurations") {
                ForEach($model.choices) { $choice in
                    Toggle(isOn: $choice.selected) {
                        VStack(alignment: .leading) {
                            Text(choice.config.name)
                            Text("\(choice.config.transcriber) · \(choice.config.stages.isEmpty ? "no stages" : choice.config.stages.joined(separator: " → ")) · \(flagsText(choice.config))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button(model.isRunning ? "Running…" : "Run benchmark on this Mac") { Task { await model.run() } }
                    .disabled(model.isRunning || model.selectedConfigs.isEmpty)
                phaseLabel
                Spacer()
            }
            if !model.reports.isEmpty {
                ComparisonTable(reports: model.reports)
                ForEach(model.reports, id: \.config.name) { report in
                    LatencyWaterfallView(title: report.config.name, rows: LabPanelViewModel.waterfall(report))
                }
            }
        }
        .padding()
        .frame(minWidth: 520)
    }

    func flagsText(_ c: LabConfig) -> String {
        c.flags.isEmpty ? "default flags" : c.flags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value ? "on" : "off")" }.joined(separator: " ")
    }

    @ViewBuilder var phaseLabel: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .running(let done, let total): ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 120)
        case .finished: Text("Done").foregroundStyle(.secondary)
        case .failed(let msg): Text(msg).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct ComparisonTable: View {
    let reports: [LabReport]
    var body: some View {
        GroupBox("Results") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Metric").bold(); ForEach(reports, id: \.config.name) { Text($0.config.name).bold() } }
                row("WER") { pct($0.overall.wer) }
                row("Entity recall") { pct($0.overall.entityRecall) }
                row("False-entity") { pct($0.overall.falseEntityRate) }
                row("Zero-edit (pred.)") { pct($0.overall.zeroEditRate) }
                row("p50 / p95") { "\(Int($0.overall.latencyP50Ms)) / \(Int($0.overall.latencyP95Ms)) ms" }
            }
        }
    }
    func row(_ label: String, _ f: @escaping (LabReport) -> String) -> some View {
        GridRow { Text(label); ForEach(reports, id: \.config.name) { Text(f($0)).monospacedDigit() } }
    }
    func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
}

/// Per-stage latency as stacked horizontal bars.
public struct LatencyWaterfallView: View {
    public var title: String
    public var rows: [(label: String, ms: Double)]

    public init(title: String, rows: [(label: String, ms: Double)]) { self.title = title; self.rows = rows }

    public var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.ms }, 1)
        GroupBox("Latency waterfall — \(title)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    let before = rows.prefix(idx).reduce(0) { $0 + $1.ms }
                    HStack(spacing: 8) {
                        Text(row.label).frame(width: 140, alignment: .leading).font(.caption)
                        GeometryReader { geo in
                            Rectangle().fill(Color.accentColor.opacity(0.8))
                                .frame(width: max(2, geo.size.width * row.ms / total))
                                .offset(x: geo.size.width * before / total)
                        }.frame(height: 12)
                        Text("\(Int(row.ms.rounded())) ms").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                    }
                }
                Text("total \(Int(total.rounded())) ms").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

public struct ThermalReadoutView: View {
    public var readout: ThermalReadout
    public init(readout: ThermalReadout) { self.readout = readout }
    var color: Color { [.green, .yellow, .orange, .red][min(readout.level, 3)] }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text("Thermal: \(readout.name)").font(.caption)
        }
        .help("ProcessInfo.thermalState sampled before and after each run")
    }
}
