import SwiftUI
import Shared

/// Live log of every byte that left the machine + hourly rollup + kill switch.
public struct DataPanelView: View {
    @ObservedObject var model: DataPanelViewModel
    public init(model: DataPanelViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Data Panel").font(.title2.bold())
                Spacer()
                Toggle("Block all network egress", isOn: Binding(get: { model.killSwitch }, set: { model.killSwitch = $0 }))
                    .toggleStyle(.switch)
            }
            if model.model.isClean {
                Label("Nothing left this machine in the last 24 hours.", systemImage: "checkmark.shield").foregroundStyle(.green)
            } else {
                Text("\(DataPanelModel.formatBytes(model.model.totalBytesOut)) out · \(DataPanelModel.formatBytes(model.model.totalBytesIn)) in · \(model.model.records.count) requests")
            }
            HourlyRollupView(buckets: model.model.hourlyRollup())
            GroupBox("Recent requests") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.model.records.prefix(200), id: \.id) { r in
                            HStack {
                                Text(r.timestamp, style: .time).frame(width: 70, alignment: .leading)
                                Text(r.host).frame(width: 180, alignment: .leading)
                                Text("\(r.stage)/\(r.provider)").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(DataPanelModel.formatBytes(r.bytesOut)) ↑").monospacedDigit()
                                Text(r.purpose).foregroundStyle(.secondary).lineLimit(1)
                            }.font(.caption)
                        }
                    }
                }.frame(maxHeight: 240)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Button("Refresh") { model.reload() }
        }
        .padding()
        .onAppear { model.reload() }
    }
}

struct HourlyRollupView: View {
    let buckets: [HourBucket]
    var body: some View {
        let peak = max(buckets.map(\.bytesOut).max() ?? 0, 1)
        GroupBox("Last 24 hours (bytes out per hour)") {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(buckets) { b in
                    Rectangle().fill(b.bytesOut == 0 ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .frame(height: max(2, 60 * CGFloat(b.bytesOut) / CGFloat(peak)))
                        .help("\(b.hour.formatted(date: .omitted, time: .shortened)): \(DataPanelModel.formatBytes(b.bytesOut)), \(b.requests) req")
                }
            }.frame(height: 60)
        }
    }
}

/// Menu-bar dropdown stat + 14-day trend sparkline.
public struct ZeroEditMenuView: View {
    @ObservedObject var model: ZeroEditViewModel
    public init(model: ZeroEditViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.stat.menuBarLine).font(.headline)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(model.stat.trend) { d in
                    Rectangle().fill(d.dictations == 0 ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .frame(width: 8, height: max(2, 24 * CGFloat(d.zeroEditRate)))
                        .help("\(d.day.formatted(date: .abbreviated, time: .omitted)): \(Int(d.zeroEditRate * 100))% of \(d.dictations)")
                }
            }
            Text("zero-edit rate, last 14 days").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.reload() }
    }
}
