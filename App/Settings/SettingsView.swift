import SwiftUI
import Shared

/// Single, small settings window: General · Models · Personas · Dictionary · Flags · Data.
public struct SettingsView: View {
    @ObservedObject var general: GeneralSettingsViewModel
    @ObservedObject var models: ModelsSettingsViewModel
    @ObservedObject var personas: PersonasViewModel
    @ObservedObject var dictionary: DictionaryViewModel
    /// R4.3 — the learned half of the Dictionary tab (spelling / heard-as / origin / forget),
    /// distinct from `dictionary`'s user-typed term list.
    @ObservedObject var learnedDictionary: LearnedDictionaryViewModel
    /// R4.3 — Benchmark tab: R4.1b's ranked-context-list recall/false-insertion counters.
    @ObservedObject var benchmark: BenchmarkViewModel
    @ObservedObject var flags: FlagsViewModel
    @ObservedObject var data: DataPanelViewModel
    @ObservedObject var snippets: SnippetsViewModel
    @ObservedObject var corrections: CorrectionSettingsViewModel
    @ObservedObject var connectors: ConnectorsSettingsViewModel
    @ObservedObject var sync: SyncSettingsViewModel
    let deps: OnboardingDependencies
    @Binding var selectedTab: SettingsTab
    /// Owned here rather than injected: it reads and writes the `UserDefaults` keys the engine
    /// already owns, so there is nothing for the container to hold on its behalf.
    @StateObject private var audio = AudioInputSettingsViewModel()

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gear") }.tag(SettingsTab.general)
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models)
            // R5.3 — Voice owns the refinement mode (Auto / Always / Never). It builds its own
            // view model from `deps`, so this tab needs no new injected dependency.
            VoiceSettingsTab(store: deps.settingsStore, flags: deps.flags)
                .tabItem { Label("Voice", systemImage: "waveform") }.tag(SettingsTab.voice)
            personasTab.tabItem { Label("Personas", systemImage: "person.text.rectangle") }.tag(SettingsTab.personas)
            dictionaryTab.tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(SettingsTab.dictionary)
            SnippetsSettingsTab(model: snippets).padding(4).tabItem { Label("Snippets", systemImage: "text.quote") }.tag(SettingsTab.snippets)
            flagsTab.tabItem { Label("Flags", systemImage: "flag") }.tag(SettingsTab.flags)
            ConnectorsSettingsTab(model: connectors).tabItem { Label("Services", systemImage: "link") }.tag(SettingsTab.connectors)
            SyncSettingsTab(model: sync).tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.sync)
            dataTab.tabItem { Label("Data", systemImage: "network") }.tag(SettingsTab.data)
            benchmarkTab.tabItem { Label("Benchmark", systemImage: "gauge.with.dots.needle.50percent") }.tag(SettingsTab.benchmark)
        }
        .frame(width: 560, height: 400)
        .padding(12)
    }

    private var generalTab: some View {
        Form {
            Picker("Dictation key", selection: $general.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
            }
            Text("Hold to talk, release to land. Double-tap locks it on.").font(.caption).foregroundStyle(.secondary)
            Text(general.hotkeyPermissionNote).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.hotkeyPermissionNote")
            Picker("Actions key", selection: $general.actKey) {
                ForEach(ActKeyChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.actKey")
            Text(general.actKeyNote).font(.caption)
                .foregroundStyle(general.actKeyCollidesWithDictation ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier("settings.actKeyNote")
            Section("Microphone") {
                Picker("Microphone", selection: $audio.selection) {
                    Text("Automatic").tag(AudioInputSettingsViewModel.automatic)
                    ForEach(audio.devices) { Text(audio.title(for: $0)).tag($0.uid) }
                }
                .accessibilityIdentifier("settings.microphone")
                Text(audio.note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.microphoneNote")
                Toggle("Save recordings of what I dictate", isOn: $audio.saveRecordings)
                    .accessibilityIdentifier("settings.saveRecordings")
                Text(audio.saveRecordings
                     ? "ON — every dictation is being saved as audio on this Mac, so a bad transcription can be replayed and diagnosed. Nothing is uploaded and nothing leaves this Mac. Turn it off when you're done."
                     : "Off. Turn this on only to chase down bad accuracy: it saves each dictation's audio on this Mac so it can be replayed. Nothing is ever uploaded.")
                    .font(.caption)
                    .foregroundStyle(audio.saveRecordings ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("settings.saveRecordingsNote")
                HStack {
                    Text(audio.recordingsSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { audio.revealRecordings() }
                    Button("Delete all", role: .destructive) { audio.deleteRecordings() }
                }
            }
            Toggle("Use the legacy event-tap listener", isOn: $general.forceEventTap)
                .accessibilityIdentifier("settings.forceEventTap")
            Text("Only if the dictation key stops responding. This is the pre-1.6.8 mechanism: it needs VoicePlus in Privacy & Security › Input Monitoring, and macOS hands that permission over only at launch, so you have to quit and reopen. Everything else here needs no permission at all.")
                .font(.caption).foregroundStyle(.secondary)
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
            Button("Run onboarding again") { OnboardingWindowController.show(dependencies: deps) }
            CorrectionSettingsSection(model: corrections)
        }
        .formStyle(.grouped)
    }

    private var modelsTab: some View {
        Form {
            Section("Per-stage routing") {
                ForEach(RoutableStage.all) { stage in
                    Picker(stage.title, selection: Binding(
                        get: { models.choice(for: stage.id) },
                        set: { models.set($0, for: stage.id) }
                    )) {
                        ForEach(models.options(for: stage)) { Text($0.title).tag($0) }
                    }
                }
                Button("Reset all to Auto") { models.resetToAuto() }
            }
            Section("Speech model") {
                Text(models.speechModelSummary)
                    .accessibilityIdentifier("settings.speechModel")
                Text("One stack, installed on first run. There is no model to choose: this is the only thing that transcribes, and it runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Providers") {
                Text("Auto uses local models first and a paid model only where it helps. Transcription is always local — subscriptions don't improve it.")
                    .font(.caption).foregroundStyle(.secondary)
                if models.connectedProviders.isEmpty {
                    Text("Nothing connected.").foregroundStyle(.secondary)
                } else {
                    ForEach(models.connectedProviders, id: \.self) { Text($0) }
                }
                Button("Connect what you pay for…") { deps.openProvidersSettings() }
            }
        }
        .formStyle(.grouped)
    }

    @State private var personaBundle = ""
    @State private var personaText = ""

    private var personasTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plain English, per app. Example for Slack: “Casual, short, no sign-off.”").font(.caption).foregroundStyle(.secondary)
            List(personas.personas) { p in
                VStack(alignment: .leading) {
                    Text(p.appBundleID).font(.caption.monospaced())
                    Text(p.instructions)
                }
                .contextMenu { Button("Delete") { personas.delete(appBundleID: p.appBundleID) } }
                .onTapGesture { personaBundle = p.appBundleID; personaText = p.instructions }
            }
            TextField("App bundle ID (e.g. com.tinyspeck.slackmacgap)", text: $personaBundle)
            TextEditor(text: $personaText).frame(height: 60).border(.quaternary)
            HStack {
                Button("Auto-draft from my style") { if let d = personas.autoDraft(appBundleID: personaBundle, database: deps.database) { personaText = d } }
                    .disabled(personaBundle.isEmpty)
                Spacer()
                Button("Save") { personas.save(appBundleID: personaBundle, instructions: personaText) }
            }
        }
    }

    @State private var newTerm = ""
    @State private var importResult: ContactsImportOffer.Outcome?
    @State private var trainToast: String?

    private var dictionaryTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter", text: $dictionary.filter)
            List(dictionary.filtered) { t in
                HStack {
                    Text(t.term)
                    if !t.spokenForms.isEmpty { Text("spoken: \(t.spokenForms)").foregroundStyle(.secondary).font(.caption) }
                    Spacer()
                    Button(role: .destructive) { dictionary.remove(id: t.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("New term", text: $newTerm).onSubmit { if dictionary.add(term: newTerm) { newTerm = "" } }
                Button("Add") { if dictionary.add(term: newTerm) { newTerm = "" } }
                // P6.2 — say the word once; the clip becomes adaptation training data and the
                // one-time "I'll remember …" toast confirms it.
                if let train = SettingsWindowController.trainByVoice {
                    Button("Train by voice…") {
                        let word = newTerm
                        guard !word.isEmpty else { trainToast = "Type the word first, then train."; return }
                        trainToast = "Listening…"
                        Task { trainToast = await train(word) ?? "Already remembered “\(word)”." }
                    }
                    .disabled(newTerm.isEmpty)
                    .accessibilityIdentifier("dictionary.trainByVoice")
                }
                Spacer()
                Button("Import names from Contacts…") {
                    Task { importResult = await dictionary.importContacts(store: deps.contacts, settings: deps.settingsStore) }
                }
            }
            if let trainToast {
                Text(trainToast).font(.caption).foregroundStyle(.teal).accessibilityIdentifier("dictionary.rememberToast")
            }
            if let importResult {
                Text(describe(importResult)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            learnedDictionarySection
        }
    }

    /// R4.3 — words this Mac corrected on its own: the spelling it settled on, what it used to
    /// hear instead, and where the correction came from. Forgetting one takes effect on the very
    /// next utterance (`LearnedDictionaryViewModel.forget`, `AdaptationLoop.forget`).
    private var learnedDictionarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learned automatically").font(.headline)
            if learnedDictionary.entries.isEmpty {
                Text("Nothing learned yet — corrections you make while dictating show up here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictionary.learned.empty")
            } else {
                List(learnedDictionary.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.spelling)
                            Text(entry.heardAs.isEmpty ? "heard as: (no misheard form on record)" : "heard as: \(entry.heardAs.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("origin: \(entry.origin)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { learnedDictionary.forget(entry) } label: {
                            Label("Forget", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("dictionary.learned.forget.\(entry.id)")
                    }
                }
                .accessibilityIdentifier("dictionary.learned.list")
            }
        }
    }

    private var benchmarkTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recall and false insertions from the ranked context list on the real-room corpus (R4.1b). Not run here — this shows the last completed measurement.")
                .font(.caption).foregroundStyle(.secondary)
            if !benchmark.hasData {
                Text("No measurements yet.").accessibilityIdentifier("benchmark.empty")
            } else {
                if let corpusLabel = benchmark.corpusLabel {
                    Text(corpusLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(benchmark.rows) { row in
                    HStack {
                        Text(row.arm)
                        Spacer()
                        Text("recall \(row.recallText)").font(.caption.monospaced())
                        Text("false insertions \(row.falseInsertions)").font(.caption.monospaced())
                    }
                    .accessibilityIdentifier("benchmark.row.\(row.id)")
                }
                if let recallGainText = benchmark.recallGainText {
                    Text(recallGainText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("benchmark.recallGain")
                }
                if let passLabel = benchmark.passLabel {
                    Text(passLabel).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("benchmark.passLabel")
                }
            }
        }
        .padding(4)
    }

    private func describe(_ o: ContactsImportOffer.Outcome) -> String {
        switch o {
        case .imported(let n): return "Added \(n) names."
        case .denied: return "Contacts access was denied. Grant it in System Settings › Privacy › Contacts."
        case .declined: return "Skipped."
        case .unavailable: return "Couldn't import."
        }
    }

    private var flagsTab: some View {
        Form {
            Text("Risky bets ship behind flags the Lab measures. Flip one to compare on your own audio.").font(.caption).foregroundStyle(.secondary)
            ForEach(flags.rows) { row in
                Toggle(isOn: Binding(get: { row.enabled }, set: { flags.set($0, for: row.flag) })) {
                    VStack(alignment: .leading) {
                        HStack { Text(row.flag.id); if row.overridden { Text("overridden").font(.caption).foregroundStyle(.orange) } }
                        Text(row.flag.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Reset to defaults") { flags.resetAll() }
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Every byte that left this Mac. Today: \(data.bytesOutToday) bytes out.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { data.reload() }
            }
            if data.entries.isEmpty {
                Text("Nothing has left this Mac.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(data.entries.map(DataRow.init)) {
                    TableColumn("When") { Text($0.timestamp, style: .time) }
                    TableColumn("Stage", value: \.stage)
                    TableColumn("Provider", value: \.provider)
                    TableColumn("Host", value: \.host)
                    TableColumn("Out") { Text("\($0.bytesOut)") }
                    TableColumn("In") { Text("\($0.bytesIn)") }
                    TableColumn("Purpose", value: \.purpose)
                }
            }
        }
    }
}

/// Identifiable wrapper so `Table` can display `NetworkLogRecord`s (whose `id` is optional).
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

public enum SettingsTab: String, CaseIterable, Sendable { case general, models, voice, personas, dictionary, snippets, flags, connectors, sync, data, benchmark }
