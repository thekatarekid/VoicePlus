import SwiftUI
import Shared

// R7.2 — Settings is now a *section of the one window*, not a window with nine tabs
// (`DESIGN.md` §9.6). The `TabView` is gone. Groups, in the order §9.6 fixes: Keys, Behaviour,
// Presence, Models, Providers / Services, Sync, Feature flags, Updates.
//
// Two of the old tabs are deliberately not here, because §9.6 says they have better homes:
// Data → Privacy, and Dictionary / Snippets / Personas → Dictionary / Apps. Voice (the second-pass
// picker) sits in Voice, next to the microphone and the measurements. `SettingsReachability` lists
// every one of those moves and `SettingsReachabilityTests` proves each landed somewhere.

struct SettingsView: View {
    @ObservedObject var model: MainWindowViewModel
    @ObservedObject var general: GeneralSettingsViewModel
    @ObservedObject var models: ModelsSettingsViewModel
    @ObservedObject var flags: FlagsViewModel
    @ObservedObject var section: SettingsSectionViewModel

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var muted = UserDefaultsMuteStore().loadMuted()

    init(model: MainWindowViewModel) {
        self.model = model
        _general = ObservedObject(wrappedValue: model.general)
        _models = ObservedObject(wrappedValue: model.models)
        _flags = ObservedObject(wrappedValue: model.flags)
        _section = ObservedObject(wrappedValue: model.settingsSection)
    }

    var body: some View {
        Form {
            keys
            behaviour
            presence
            modelsGroup
            providers
            Section("Sync") { SyncSettingsTab(model: model.sync) }
            featureFlags
            updates
        }
        .formStyle(.grouped)
        .navigationTitle(MainWindowSection.settings.detailTitle)
    }

    // MARK: Keys

    private var keys: some View {
        Section("Keys") {
            Picker("Dictation key", selection: $general.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.hotkey")
            Text("Hold to talk, release to land. Double-tap latches it on.")
                .font(.caption).foregroundStyle(.secondary)
            Text(general.hotkeyPermissionNote).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.hotkeyPermissionNote")
            Picker("Actions key", selection: $general.actKey) {
                ForEach(ActKeyChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.actKey")
            Text(general.actKeyNote).font(.caption)
                .foregroundStyle(general.actKeyCollidesWithDictation ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier("settings.actKeyNote")
            Toggle("Use the legacy event-tap listener", isOn: $general.forceEventTap)
                .accessibilityIdentifier("settings.forceEventTap")
            Text("Only if the dictation key stops responding. This is the pre-1.6.8 mechanism: it needs VoicePlus in Privacy & Security › Input Monitoring, and macOS hands that permission over only at launch, so you have to quit and reopen. Everything else here needs no permission at all.")
                .font(.caption).foregroundStyle(.secondary)
            rowError("settings.hotkey")
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        Section("Behaviour") {
            Text("Hold the key to talk and release to land. Double-tap it to latch: listening carries on across pauses until you tap again.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Mute the microphone", isOn: Binding(
                get: { muted },
                set: { on in
                    muted = on
                    UserDefaultsMuteStore().saveMuted(on)
                }
            ))
            .accessibilityIdentifier("settings.mute")
            Text("A hard mute. It survives a relaunch and never clears itself — nothing opens the microphone until you turn it off.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    let applied = LaunchAtLogin.set(enabled: on)
                    launchAtLogin = applied ? on : LaunchAtLogin.isEnabled
                    if !applied { section.reportNotSaved("settings.launchAtLogin") }
                }
            ))
            .disabled(!LaunchAtLogin.isAvailable)
            .accessibilityIdentifier("settings.launchAtLogin")
            if !LaunchAtLogin.isAvailable {
                Text("Only a VoicePlus that is running from an .app bundle can register itself as a login item.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            rowError("settings.launchAtLogin")
            CorrectionSettingsSection(model: model.corrections)
            Button("Run onboarding again") { OnboardingWindowController.show(dependencies: model.deps) }
                .accessibilityIdentifier("settings.runOnboardingAgain")
        }
    }

    // MARK: Presence

    private var presence: some View {
        Section("Presence") {
            Toggle("Show indicator under the notch", isOn: $general.presenceIndicator)
                .accessibilityIdentifier("settings.presenceIndicator")
            Text("A small chin under the camera housing that says VoicePlus is alive — and shows when the mic is open or muted. The menu-bar icon disappears when another app fills the menu bar; this doesn't.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hide it in full screen", isOn: $general.presenceHideInFullScreen)
                .disabled(!general.presenceIndicator)
                .accessibilityIdentifier("settings.presenceHideInFullScreen")
            Text("Only the quiet states hide. Listening, working and muted always stay visible — a hidden hot mic is exactly what this is for.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Models

    private var modelsGroup: some View {
        Section("Models") {
            ForEach(RoutableStage.all) { stage in
                Picker(stage.title, selection: Binding(
                    get: { models.choice(for: stage.id) },
                    set: { models.set($0, for: stage.id) }
                )) {
                    ForEach(models.options(for: stage)) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.routing.\(stage.id.rawValue)")
            }
            Button("Reset all to Auto") { models.resetToAuto() }
                .accessibilityIdentifier("settings.resetRoutingToAuto")
            Text(models.speechModelSummary)
                .accessibilityIdentifier("settings.speechModel")
            Text("One stack, installed on first run. There is no model to choose: this is the only thing that transcribes, and it runs on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Providers / Services

    private var providers: some View {
        Section("Providers and services") {
            Text("Auto uses local models first and a paid model only where it helps. Transcription is always local — subscriptions don't improve it.")
                .font(.caption).foregroundStyle(.secondary)
            if section.providers.isContent {
                ForEach(models.connectedProviders, id: \.self) { Text($0) }
                    .accessibilityIdentifier("settings.connectedProviders")
            } else {
                SectionStateView(state: section.providers)
                    .accessibilityIdentifier("settings.connectedProviders")
            }
            Button("Connect what you pay for…") { model.deps.openProvidersSettings() }
                .accessibilityIdentifier("settings.connectProviders")
            ConnectorsSettingsTab(model: model.connectors)
        }
    }

    // MARK: Feature flags

    private var featureFlags: some View {
        Section("Feature flags") {
            Text("Risky bets ship behind flags the Lab measures. Flip one to compare on your own audio.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(flags.rows) { row in
                Toggle(isOn: Binding(get: { row.enabled }, set: { flags.set($0, for: row.flag) })) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(row.flag.id)
                            if row.overridden {
                                Text("overridden").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text(row.flag.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.flag.\(row.flag.id)")
            }
            Button("Reset to defaults") { flags.resetAll() }
                .accessibilityIdentifier("settings.flagsReset")
        }
    }

    // MARK: Updates

    private var updates: some View {
        Section("Updates") {
            Text("VoicePlus \(MainWindowController.appVersion)").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.version")
            if let updater = MainWindowController.updater {
                Button("Check for updates") { updater.checkForUpdates() }
                    .accessibilityIdentifier("settings.checkForUpdates")
            } else {
                Text("This build has no updater wired, so it will never update itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.checkForUpdates")
            }
        }
    }

    @ViewBuilder private func rowError(_ setting: String) -> some View {
        if let error = section.rowError(setting) {
            Text(error).font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("settings.rowError.\(setting)")
        }
    }
}

/// Identifiable wrapper so `Table` can display `NetworkLogRecord`s (whose `id` is optional).
/// Used by Privacy › Transmitted (`PrivacySectionView`), which is where the Data Panel now lives.
struct DataRow: Identifiable {
    let record: NetworkLogRecord
    var id: String { "\(record.id ?? -1)-\(record.timestamp.timeIntervalSince1970)" }
    var timestamp: Date { record.timestamp }
    var stage: String { record.stage }
    var provider: String { record.provider }
    var host: String { record.host }
    var bytesOut: Int { record.bytesOut }
    var bytesIn: Int { record.bytesIn }
    var purpose: String { record.purpose }
}
