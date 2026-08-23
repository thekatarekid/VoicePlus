import SwiftUI
import Shared

/// Single, small settings window: General · Models · Personas · Dictionary · Flags · Data.
public struct SettingsView: View {
    @ObservedObject var general: GeneralSettingsViewModel
    @ObservedObject var models: ModelsSettingsViewModel
    @ObservedObject var personas: PersonasViewModel
    @ObservedObject var dictionary: DictionaryViewModel
    @ObservedObject var flags: FlagsViewModel
    @ObservedObject var data: DataPanelViewModel
    @ObservedObject var snippets: SnippetsViewModel
    @ObservedObject var corrections: CorrectionSettingsViewModel
    @ObservedObject var connectors: ConnectorsSettingsViewModel
    let deps: OnboardingDependencies
    @Binding var selectedTab: SettingsTab

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gear") }.tag(SettingsTab.general)
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models)
            personasTab.tabItem { Label("Personas", systemImage: "person.text.rectangle") }.tag(SettingsTab.personas)
            dictionaryTab.tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(SettingsTab.dictionary)
            SnippetsSettingsTab(model: snippets).padding(4).tabItem { Label("Snippets", systemImage: "text.quote") }.tag(SettingsTab.snippets)
            flagsTab.tabItem { Label("Flags", systemImage: "flag") }.tag(SettingsTab.flags)
            ConnectorsSettingsTab(model: connectors).tabItem { Label("Services", systemImage: "link") }.tag(SettingsTab.connectors)
            dataTab.tabItem { Label("Data", systemImage: "network") }.tag(SettingsTab.data)
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
                Spacer()
                Button("Import names from Contacts…") {
                    Task { importResult = await dictionary.importContacts(store: deps.contacts, settings: deps.settingsStore) }
                }
            }
            if let importResult {
                Text(describe(importResult)).font(.caption).foregroundStyle(.secondary)
            }
        }
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

public enum SettingsTab: String, CaseIterable, Sendable { case general, models, personas, dictionary, snippets, flags, connectors, data }
