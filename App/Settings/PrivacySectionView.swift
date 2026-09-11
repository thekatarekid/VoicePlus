import SwiftUI
import Shared

// R7.2 — Privacy (`DESIGN.md` §9.5). The Data Panel window folds in here as the **Transmitted**
// group, kill switch included. Three groups: Captured, Saved, Transmitted.

struct PrivacySectionView: View {
    @ObservedObject var model: PrivacySectionViewModel
    @ObservedObject var audio: AudioInputSettingsViewModel
    @State private var confirmingDeleteAll = false

    init(model: PrivacySectionViewModel) {
        self.model = model
        _audio = ObservedObject(wrappedValue: model.audio)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MainWindowSection.privacy.detailTitle).font(.title2.weight(.semibold))
                    Text(MainWindowSection.privacy.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                if let banner = model.banner { SectionBannerView(banner: banner) }
                captured
                saved
                transmitted
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete everything saved on this Mac?", isPresented: $confirmingDeleteAll) {
            Button("Delete everything", role: .destructive) { model.deleteAll() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(model.deleteAllSummary)
        }
    }

    // MARK: Captured — the switches render immediately from settings (§9.5)

    private var captured: some View {
        GroupBox("Captured") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Ambient capture", isOn: Binding(
                    get: { model.ambientCapture },
                    set: { model.ambientCapture = $0 }
                ))
                .accessibilityIdentifier("privacy.ambientCapture")
                Text(PrivacySectionViewModel.enrolledSpeakerOnlyNote)
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Keep transcripts for", selection: Binding(
                    get: { model.retentionDays },
                    set: { model.retentionDays = $0 }
                )) {
                    ForEach(AmbientRetentionSettings.choices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .accessibilityIdentifier("privacy.retentionDays")
                Toggle("Save recordings of what I dictate", isOn: Binding(
                    get: { model.audioRetention },
                    set: { model.audioRetention = $0; model.refreshSaved() }
                ))
                .accessibilityIdentifier("settings.saveRecordings")
                Text(audio.saveRecordings
                     ? "ON — every dictation is being saved as audio on this Mac, so a bad transcription can be replayed and diagnosed. Nothing is uploaded and nothing leaves this Mac. Turn it off when you're done."
                     : "Off. Turn this on only to chase down bad accuracy: it saves each dictation's audio on this Mac so it can be replayed. Nothing is ever uploaded.")
                    .font(.caption)
                    .foregroundStyle(audio.saveRecordings ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("settings.saveRecordingsNote")
            }
            .padding(4)
        }
    }

    // MARK: Saved

    private var saved: some View {
        GroupBox("Saved") {
            VStack(alignment: .leading, spacing: 8) {
                if model.saved.isContent {
                    HStack {
                        Text(audio.recordingsSummary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { audio.revealRecordings() }
                        Button("Delete all", role: .destructive) { confirmingDeleteAll = true }
                    }
                    .accessibilityIdentifier("settings.recordings")
                } else {
                    SectionStateView(state: model.saved)
                    HStack {
                        Text(audio.recordingsSummary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { audio.revealRecordings() }
                    }
                    .accessibilityIdentifier("settings.recordings")
                }
                Button("Delete everything saved…", role: .destructive) { confirmingDeleteAll = true }
                    .accessibilityIdentifier("privacy.deleteAll")
            }
            .padding(4)
        }
    }

    // MARK: Transmitted — the Data Panel, folded in

    private var transmitted: some View {
        GroupBox("Transmitted") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Block all network egress", isOn: Binding(
                    get: { model.killSwitch },
                    set: { model.killSwitch = $0 }
                ))
                .accessibilityIdentifier("privacy.killSwitch")
                Text(model.windowSentence).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Today: \(model.bytesOutToday) bytes out")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("privacy.bytesOutToday")
                    Spacer()
                    Button("Refresh") { Task { await model.reload() } }
                        .accessibilityIdentifier("privacy.egressRefresh")
                }
                if model.egress.isContent {
                    Table(model.records.map(DataRow.init)) {
                        TableColumn("When") { Text($0.timestamp, style: .time) }
                        TableColumn("Stage", value: \.stage)
                        TableColumn("Provider", value: \.provider)
                        TableColumn("Host") { Text($0.host).font(.body.monospaced()) }
                        TableColumn("Out") { Text("\($0.bytesOut)").font(.body.monospacedDigit()) }
                        TableColumn("In") { Text("\($0.bytesIn)").font(.body.monospacedDigit()) }
                        TableColumn("Purpose", value: \.purpose)
                    }
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("privacy.egressTable")
                } else {
                    SectionStateView(state: model.egress) { Pasteboard.copy(diagnostics) }
                        .accessibilityIdentifier("privacy.egressTable")
                }
            }
            .padding(4)
        }
    }

    private var diagnostics: String {
        model.banner?.diagnostics ?? "egress log unreadable"
    }
}
