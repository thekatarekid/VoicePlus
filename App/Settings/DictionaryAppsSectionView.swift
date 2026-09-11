import SwiftUI
import Shared

// R7.2 — Dictionary / Apps (`DESIGN.md` §9.3). Three of the old tabs live here: Dictionary (typed
// terms + the R4.3 learned list), Snippets, and Personas — plus the never-inject switch, which had
// no UI at all before now.

struct DictionaryAppsSectionView: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel
    /// The three tab view models are observed directly as well: they are the ones that publish when
    /// a term, persona or snippet changes.
    @ObservedObject var dictionary: DictionaryViewModel
    @ObservedObject var learned: LearnedDictionaryViewModel
    @ObservedObject var personas: PersonasViewModel
    let deps: OnboardingDependencies

    init(model: DictionaryAppsSectionViewModel, deps: OnboardingDependencies) {
        self.model = model
        self.deps = deps
        _dictionary = ObservedObject(wrappedValue: model.dictionary)
        _learned = ObservedObject(wrappedValue: model.learned)
        _personas = ObservedObject(wrappedValue: model.personas)
    }

    @State private var newTerm = ""
    @State private var trainToast: String?
    @State private var importResult: ContactsImportOffer.Outcome?
    @State private var personaBundle = ""
    @State private var personaText = ""
    @State private var neverInjectBundle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MainWindowSection.dictionary.detailTitle).font(.title2.weight(.semibold))
                    Text(MainWindowSection.dictionary.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                if let banner = model.banner { SectionBannerView(banner: banner) }
                dictionaryGroup
                learnedGroup
                appsGroup
                GroupBox("Snippets") { SnippetsSettingsTab(model: model.snippets).padding(4) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Dictionary

    @ViewBuilder private var dictionaryGroup: some View {
        GroupBox("Dictionary") {
            VStack(alignment: .leading, spacing: 8) {
                if model.dictionaryState.isContent {
                    TextField("Filter", text: $dictionary.filter)
                        .accessibilityIdentifier("dictionary.filter")
                    ForEach(dictionary.filtered) { term in
                        HStack {
                            Text(term.term)
                            if !term.spokenForms.isEmpty {
                                Text("spoken: \(term.spokenForms)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { dictionary.remove(id: term.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                } else {
                    SectionStateView(state: model.dictionaryState) { importContacts() }
                }
                addRow
                if let trainToast {
                    Text(trainToast).font(.caption).foregroundStyle(.teal)
                        .accessibilityIdentifier("dictionary.rememberToast")
                }
                if let importResult {
                    Text(describe(importResult)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var addRow: some View {
        HStack {
            TextField("New term", text: $newTerm)
                .onSubmit { add() }
            Button("Add") { add() }
                .accessibilityIdentifier("dictionary.add")
            if let train = MainWindowController.trainByVoice {
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
            Button("Import names from Contacts…") { importContacts() }
                .accessibilityIdentifier("dictionary.importContacts")
        }
    }

    private func add() {
        if dictionary.add(term: newTerm) { newTerm = ""; model.reload() }
    }

    private func importContacts() {
        Task {
            let outcome = await dictionary.importContacts(store: deps.contacts, settings: deps.settingsStore)
            importResult = outcome
            if case .denied = outcome { model.reportContactsDenied() }
            model.reload()
        }
    }

    private func describe(_ outcome: ContactsImportOffer.Outcome) -> String {
        switch outcome {
        case .imported(let n): return "Added \(n) names."
        case .denied: return SectionCopy.contactsDenied
        case .declined: return "Skipped."
        case .unavailable: return "Couldn't import."
        }
    }

    // MARK: Learned automatically (R4.3)

    private var learnedGroup: some View {
        GroupBox("Learned automatically") {
            VStack(alignment: .leading, spacing: 4) {
                if learned.entries.isEmpty {
                    Text("Nothing learned yet — corrections you make while dictating show up here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictionary.learned.empty")
                } else {
                    ForEach(learned.entries) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.spelling)
                                Text(entry.heardAs.isEmpty ? "heard as: (no misheard form on record)" : "heard as: \(entry.heardAs.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("origin: \(entry.origin)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { learned.forget(entry) } label: { Label("Forget", systemImage: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("dictionary.learned.forget.\(entry.id)")
                        }
                    }
                    .accessibilityIdentifier("dictionary.learned.list")
                }
            }
            .padding(4)
        }
    }

    // MARK: Apps — personas, injection policy

    private var appsGroup: some View {
        GroupBox("Apps") {
            VStack(alignment: .leading, spacing: 8) {
                if model.appsState.isContent {
                    ForEach(model.apps) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.bundleID).font(.caption.monospaced())
                            if let persona = row.persona {
                                Text(persona).font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Never type into this app", isOn: Binding(
                                get: { row.neverInject },
                                set: { model.setNeverInject($0, bundleID: row.bundleID) }
                            ))
                            .tint(.red)
                            .accessibilityIdentifier("apps.neverInject.\(row.bundleID)")
                            Text(DictionaryAppsSectionViewModel.neverInjectConsequence)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("apps.personas.list")
                } else {
                    SectionStateView(state: model.appsState)
                        .accessibilityIdentifier("apps.personas.list")
                }
                Divider()
                personaEditor
                Divider()
                neverInjectAdd
            }
            .padding(4)
        }
    }

    private var personaEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plain English, per app. Example for Slack: “Casual, short, no sign-off.”")
                .font(.caption).foregroundStyle(.secondary)
            TextField("App bundle ID (e.g. com.tinyspeck.slackmacgap)", text: $personaBundle)
                .accessibilityIdentifier("apps.personas.bundleID")
            TextEditor(text: $personaText).frame(height: 60).border(.quaternary)
                .accessibilityIdentifier("apps.personas.instructions")
            HStack {
                Button("Auto-draft from my style") {
                    if let draft = personas.autoDraft(appBundleID: personaBundle, database: deps.database) { personaText = draft }
                }
                .disabled(personaBundle.isEmpty)
                .accessibilityIdentifier("apps.personas.autoDraft")
                Spacer()
                Button("Save") {
                    personas.save(appBundleID: personaBundle, instructions: personaText)
                    model.reload()
                }
                .accessibilityIdentifier("apps.personas.save")
            }
        }
    }

    private var neverInjectAdd: some View {
        HStack {
            TextField("Never type into (bundle ID)", text: $neverInjectBundle)
                .accessibilityIdentifier("apps.neverInject.add")
            Button("Add") {
                model.setNeverInject(true, bundleID: neverInjectBundle)
                neverInjectBundle = ""
            }
            .disabled(neverInjectBundle.isEmpty)
        }
    }
}
