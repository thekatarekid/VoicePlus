import AppKit
import SwiftUI
import Shared

// S7f — Privacy (design §8.5), the section's `SectionScreen`. Drawn in S7a's `SectionPage`:
//
// - **content** — always the base rendering: the page is its switches, and a switch must stay
//   reachable whatever else fails. Loading, empty and error are scoped to the group they belong to
//   (network activity: "Reading activity…" / the dated no-egress result / the unreadable-log error;
//   history: "Nothing is saved — Your history is off…" with Review retention; audio: nothing saved).
// - **partial** — S04 "Some items couldn’t be deleted" as the page banner, its Retry deletion scoped
//   to the scopes that did not finish and disabled while it runs, over a list of what remains.
// - the Spool note: the design's still `ready` cameo, or the closed-shutter pose beside hard mute.
//
// The **Diagnostics** disclosure (design §8.5, build doc S7a) hosts the feature flags, the data
// panel (the old Data tab: every logged request, bytes each way, per destination) and the redacted
// diagnostics export with its exact preview. Its open state is `context.navigation`'s, so the old
// Flags and Data deep links open it.
struct PrivacyScreen: SectionScreen {
    static let section: MainWindowSection = .privacy
    /// Where "Review retention" scrolls to.
    static let retentionAnchor = "privacy.retention"

    let context: SectionContext
    @ObservedObject private var model: PrivacySectionViewModel
    @ObservedObject private var navigation: SectionNavigation
    @ObservedObject private var flags: FlagsViewModel
    @ObservedObject private var deletionRetry: ScopedRetry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(context: SectionContext) {
        self.context = context
        let model = context.window.privacy
        // The window's checker, so the access rows read the same TCC answers as onboarding.
        model.permissions = context.window.deps.permissions
        _model = ObservedObject(wrappedValue: model)
        _navigation = ObservedObject(wrappedValue: context.navigation)
        _flags = ObservedObject(wrappedValue: context.window.flags)
        _deletionRetry = ObservedObject(wrappedValue: model.deletionRetry)
    }

    var body: some View {
        ScrollViewReader { proxy in
            SectionPage(context.page, state: .content, banner: model.banner,
                        onBannerAction: { Task { await model.retryDeletion() } },
                        isRetrying: deletionRetry.isRetrying,
                        spoolNote: model.spoolNote, hotkey: context.hotkey) {
                VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                    PrivacySectionView(model: model, meetings: context.window.meetings, sync: context.window.sync,
                                       settings: context.window.deps.settingsStore,
                                       open: { context.open($0) },
                                       reviewRetention: {
                                           if reduceMotion { proxy.scrollTo(Self.retentionAnchor, anchor: .top) }
                                           else { withAnimation { proxy.scrollTo(Self.retentionAnchor, anchor: .top) } }
                                       })
                    diagnostics
                }
            }
        }
        .onAppear {
            flags.reload()
            model.refreshAccess()
            model.refreshMute()
        }
    }

    // MARK: Diagnostics — feature flags, the data panel, the export

    private var diagnostics: some View {
        DisclosureGroup(SectionDisclosure.diagnostics.title, isExpanded: Binding(
            get: { navigation.isExpanded(.diagnostics) },
            set: { navigation.setExpanded(.diagnostics, $0) }
        )) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                featureFlags
                PrivacyDataPanel(model: model)
                PrivacyExportView(model: model)
                TurnDiagnosticsExportRow(database: model.turnDiagnosticsDatabase) // V5 Q13
            }
            .padding(.top, Tokens.Spacing.m)
        }
        .windowFont(Tokens.Typography.body)
        .accessibilityIdentifier("privacy.diagnostics")
    }

    /// Feature flags, re-homed from the old Flags tab: the same toggles and reset, the same service.
    private var featureFlags: some View {
        GroupBox("Feature flags") {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text(PrivacyCopy.flagsIntro)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                ForEach(flags.rows) { row in
                    Toggle(isOn: Binding(get: { row.enabled }, set: { flags.set($0, for: row.flag) })) {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            HStack(spacing: Tokens.Spacing.s) {
                                Text(row.flag.id)
                                if row.overridden { StatusTag("overridden", kind: .warn) }
                            }
                            Text(row.flag.description)
                                .windowFont(Tokens.Typography.meta)
                                .foregroundStyle(WindowColor.secondaryInk)
                        }
                    }
                    .accessibilityIdentifier("privacy.diagnostics.flag.\(row.flag.id)")
                }
                Button(PrivacyCopy.resetFlags) { flags.resetAll() }
                    .accessibilityIdentifier("privacy.diagnostics.flagsReset")
            }
        }
    }
}

/// The old Data tab, folded into Diagnostics: bytes out per destination, then every logged request
/// with its stage, provider, host and bytes each way. Blocked attempts are on the page's activity
/// list; this is the raw log.
struct PrivacyDataPanel: View {
    @ObservedObject var model: PrivacySectionViewModel

    var body: some View {
        GroupBox(PrivacyCopy.dataPanelTitle) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text(model.windowSentence)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                if model.egress.rendering == .error {
                    PrivacyScopedState(state: model.egress, onAction: { Pasteboard.copy(model.activityDiagnostics) })
                } else if model.records.isEmpty {
                    Text(model.egress.rendering == .loading ? PrivacyCopy.readingActivity : PrivacyCopy.dataPanelEmpty)
                        .windowFont(Tokens.Typography.body)
                        .foregroundStyle(WindowColor.secondaryInk)
                } else {
                    ForEach(NetworkActivity.byDestination(model.records), id: \.destination) { row in
                        HStack {
                            Text(row.destination).font(.body.monospaced())
                            Spacer()
                            Text("\(row.requests) request\(row.requests == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(row.bytesOut), countStyle: .binary)) out")
                                .windowFont(Tokens.Typography.meta)
                                .monospacedDigit()
                                .foregroundStyle(WindowColor.secondaryInk)
                        }
                    }
                    Table(model.records.map(DataRow.init)) {
                        TableColumn("When") { Text($0.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute()) }
                        TableColumn("Stage", value: \.stage)
                        TableColumn("Provider", value: \.provider)
                        TableColumn("Host") { Text($0.host).font(.body.monospaced()) }
                        TableColumn("Out") { Text("\($0.bytesOut)").monospacedDigit() }
                        TableColumn("In") { Text("\($0.bytesIn)").monospacedDigit() }
                        TableColumn("Purpose", value: \.purpose)
                    }
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("privacy.dataPanel.table")
                }
            }
        }
        .accessibilityIdentifier("privacy.dataPanel")
    }
}

/// Diagnostics export: redacted by default, two explicit opt-ins, and a preview of exactly what the
/// export contains before anything is copied or written.
struct PrivacyExportView: View {
    @ObservedObject var model: PrivacySectionViewModel
    @State private var export: DiagnosticsExport?

    var body: some View {
        GroupBox(PrivacyCopy.exportTitle) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text(PrivacyCopy.exportIntro)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                Toggle(PrivacyCopy.includeTranscripts, isOn: $model.diagnosticsOptions.includeTranscripts)
                    .accessibilityIdentifier("privacy.diagnostics.includeTranscripts")
                Toggle(PrivacyCopy.includeAudio, isOn: $model.diagnosticsOptions.includeAudio)
                    .accessibilityIdentifier("privacy.diagnostics.includeAudio")
                Text(PrivacyCopy.previewTitle)
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(WindowColor.secondaryInk)
                ScrollView {
                    Text(export?.preview ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Spacing.s)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.group).fill(WindowColor.surface))
                .accessibilityIdentifier("privacy.diagnostics.preview")
                HStack(spacing: Tokens.Spacing.s) {
                    Button(PrivacyCopy.copyReport) { if let export { Pasteboard.copy(export.report) } }
                        .accessibilityIdentifier("privacy.diagnostics.copy")
                    Button(PrivacyCopy.saveExport) { save() }
                        .accessibilityIdentifier("privacy.diagnostics.save")
                    if let status = model.exportStatus {
                        Text(status)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                    }
                }
            }
        }
        .task(id: model.diagnosticsOptions) { export = model.diagnosticsExport() }
        .accessibilityIdentifier("privacy.diagnostics.export")
    }

    private func save() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "VoicePlus writes one folder here with exactly what the preview shows."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        model.saveExport(export, into: parent)
    }
}
