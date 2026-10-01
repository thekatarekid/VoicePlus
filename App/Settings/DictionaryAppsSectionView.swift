import Shared
import SwiftUI
import UniformTypeIdentifiers

// S7d — the two panes of Dictionary & Apps (design §8.3), drawn with `App/UI/Components/`. Each pane
// shows exactly one base rendering of its `SectionState` (content / empty / loading / error); every
// decision is the view model's. Spool appears only as the still cameo of an empty or loading pane
// (design §8.9: "Ordinary lists and controls; small static brand mark only").

// MARK: - One pane's base rendering

/// Empty, loading and error inside a pane (the page header and the segmented control stay above it,
/// so the other pane is always one click away). Content is the caller's.
struct PaneState: View {
    let state: SectionState
    var onAction: (() -> Void)?

    var body: some View {
        switch state.rendering {
        case .content:
            EmptyView()
        case .empty:
            EmptyState(pose: .ready, headline: state.headline, message: state.detail,
                       action: state.actionTitle.flatMap { title in
                           onAction.map { PageAction(title, identifier: "dictionaryApps.pane.action", perform: $0) }
                       })
                .accessibilityIdentifier("dictionaryApps.pane.empty")
        case .loading:
            EmptyState(pose: .ready, headline: state.headline, message: state.detail)
                .accessibilityIdentifier("dictionaryApps.pane.loading")
        case .error:
            ScopedBanner(SectionBanner(headline: state.headline, actionTitle: state.actionTitle, body: state.detail),
                         onAction: onAction)
                .accessibilityIdentifier("dictionaryApps.pane.error")
        }
    }
}

/// "No matches for “…”" with Clear search (design §9 "Search" row) — never the empty state.
struct NoMatches: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Text(DictionaryAppsCopy.noMatches(query))
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(WindowColor.secondaryInk)
            Button(DictionaryAppsCopy.clearSearch, action: clear)
                .accessibilityIdentifier("dictionaryApps.clearSearch")
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.Spacing.xl)
        .accessibilityIdentifier("dictionaryApps.noMatches")
    }
}

// MARK: - Dictionary

struct DictionaryPaneView: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel
    @ObservedObject var learned: LearnedDictionaryViewModel
    @ObservedObject var navigation: SectionNavigation
    let onImportFile: () -> Void

    init(model: DictionaryAppsSectionViewModel, navigation: SectionNavigation, onImportFile: @escaping () -> Void) {
        self.model = model
        self.navigation = navigation
        self.onImportFile = onImportFile
        _learned = ObservedObject(wrappedValue: model.learned)
    }

    private var query: String { navigation.searchQuery }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            TextField(DictionaryAppsCopy.searchPrompt, text: $navigation.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .accessibilityLabel("Search dictionary")
                .accessibilityIdentifier("dictionary.filter")
            if model.dictionaryState.isContent {
                if model.searchFindsNothing(query) {
                    NoMatches(query: query) { navigation.searchQuery = "" }
                } else {
                    words
                    learnedGroup
                }
            } else {
                PaneState(state: model.dictionaryState) {
                    model.dictionaryState.rendering == .error ? model.reloadTerms() : model.beginAdd()
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark")
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.ready)
                    .accessibilityIdentifier("dictionary.notice")
            }
            importActions
            SnippetsSettingsTab(model: model.snippets, query: query)
            DictionaryPublicListsView()   // V5 P1–P7
        }
    }

    @ViewBuilder private var words: some View {
        let shown = model.filteredTerms(query)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                GroupBox(layout: .rows) {
                    ForEach(shown) { term in
                        RowView(term.spelling, detail: term.detail) {
                            Button(DictionaryAppsCopy.edit) { model.beginEdit(term) }
                                .controlSize(.small)
                                .accessibilityLabel("Edit “\(term.spelling)”")
                                .accessibilityIdentifier("dictionary.edit.\(term.id)")
                        }
                    }
                }
                .accessibilityIdentifier("dictionary.terms")
                Text(DictionaryAppsCopy.rememberNote)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
    }

    private var importActions: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Button(DictionaryAppsCopy.importWords, action: onImportFile)
                .accessibilityIdentifier("dictionary.importWords")
            Button(DictionaryAppsCopy.importFromContacts) { model.beginContactsImport() }
                .accessibilityIdentifier("dictionary.importContacts")
        }
        .disabled(!model.dictionaryState.isContent && model.dictionaryState.rendering != .empty)
    }

    /// R4.3 — what was learned from corrections: spelling, what it was heard as, where it came from,
    /// and Forget (which takes effect on the next utterance).
    @ViewBuilder private var learnedGroup: some View {
        let shown = model.filteredLearned(query)
        if !shown.isEmpty {
            GroupBox(DictionaryAppsCopy.learnedTitle, layout: .rows) {
                ForEach(shown) { entry in
                    RowView(entry.spelling, detail: Self.learnedDetail(entry)) {
                        Button(DictionaryAppsCopy.forget) { model.forget(entry) }
                            .controlSize(.small)
                            .accessibilityLabel("Forget “\(entry.spelling)”")
                            .accessibilityIdentifier("dictionary.learned.forget.\(entry.id)")
                    }
                }
            }
            .accessibilityIdentifier("dictionary.learned.list")
        }
    }

    static func learnedDetail(_ entry: LearnedDictionaryViewModel.Entry) -> String {
        let heard = entry.heardAs.isEmpty ? nil : "heard as \(entry.heardAs.joined(separator: ", "))"
        return [heard, "Learned · \(entry.origin)"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Train the typed spelling by saying it (the R4.3 "Train by voice…" entry point), when the app has
/// wired a trainer. The result line says what happened.
struct TrainByVoiceButton: View {
    let word: String
    let onTrained: () -> Void
    @State private var status: String?

    var body: some View {
        if let train = MainWindowController.trainByVoice {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Button(DictionaryAppsCopy.trainByVoice) {
                    let spelling = DictionaryRules.collapse(word)
                    guard !spelling.isEmpty else { status = DictionaryRules.emptySpelling; return }
                    status = "Listening…"
                    Task {
                        status = await train(spelling) ?? "Already remembered “\(spelling)”."
                        onTrained()
                    }
                }
                .accessibilityIdentifier("dictionary.trainByVoice")
                if let status {
                    Text(status)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                        .accessibilityIdentifier("dictionary.rememberToast")
                }
            }
        }
    }
}

// MARK: - Apps

struct AppsPaneView: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel
    @ObservedObject var navigation: SectionNavigation
    let onAddApp: () -> Void

    private var query: String { navigation.searchQuery }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            switch model.appsState.rendering {
            case .loading, .error:
                PaneState(state: model.appsState) { model.reloadRules() }
            case .empty:
                defaults
                PaneState(state: model.appsState, onAction: onAddApp)
            case .content:
                defaults
                rules
            }
        }
    }

    /// The inherited default every app without its own value uses, and the fixed code / terminal
    /// profile.
    private var defaults: some View {
        let draft = model.defaultsDraft
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            GroupBox(DictionaryAppsCopy.defaultsTitle, layout: .rows) {
                RowView(DictionaryAppsCopy.writingStyle, detail: DictionaryAppsCopy.writingStyleDetail) {
                    Picker(DictionaryAppsCopy.writingStyle, selection: Binding(
                        get: { draft.entered.style },
                        set: { model.setDefaultStyle($0) }
                    )) {
                        ForEach(AppWritingStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityIdentifier("apps.default.style")
                }
                RowView(DictionaryAppsCopy.contextualReading, detail: DictionaryAppsCopy.contextualReadingDetail) {
                    Toggle(DictionaryAppsCopy.contextualReading, isOn: Binding(
                        get: { draft.entered.contextualReading },
                        set: { model.setDefaultContextualReading($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("apps.default.contextualReading")
                }
                RowView(DictionaryAppsCopy.codeProfileTitle, detail: DictionaryAppsCopy.codeProfileDetail) {
                    StatusTag(DictionaryAppsCopy.verbatim)
                }
            }
            if let failure = draft.failureBanner {
                ScopedBanner(failure) { model.retryDefaults() }
                    .accessibilityIdentifier("apps.default.failure")
            }
        }
    }

    @ViewBuilder private var rules: some View {
        let shown = model.filteredApps(query)
        if shown.isEmpty {
            NoMatches(query: query) { navigation.searchQuery = "" }
        } else {
            GroupBox(DictionaryAppsCopy.appRulesTitle, layout: .rows) {
                ForEach(shown) { row in
                    AppRuleRow(row: row, model: model, expanded: Binding(
                        get: { navigation.selectionID == row.bundleID },
                        set: { navigation.selectionID = $0 ? row.bundleID : nil }
                    ))
                }
            }
            .accessibilityIdentifier("apps.personas.list")
        }
    }
}

/// One app: its name and what is its own ("Uses default" otherwise), its overlay badge, and — open —
/// the controls: style, typing, contextual reading, word marks, writing instructions.
struct AppRuleRow: View {
    let row: AppPolicyRow
    @ObservedObject var model: DictionaryAppsSectionViewModel
    @Binding var expanded: Bool
    @State private var instructions: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowView(row.name, detail: row.summary) {
                HStack(spacing: Tokens.Spacing.s) {
                    if row.isUnsaved || row.failure != nil { StatusTag(DictionaryAppsCopy.notSaved, kind: .warn) }
                    if row.usesDefaults { StatusTag(DictionaryAppsCopy.usesDefault) }
                    StatusTag(row.wordMarks.tag, kind: row.wordMarks == .supported ? .good : .warn)
                    Button(expanded ? "Done" : DictionaryAppsCopy.edit) { expanded.toggle() }
                        .controlSize(.small)
                        .accessibilityLabel(expanded ? "Done with \(row.name)" : "Edit \(row.name)")
                }
            }
            if let failure = row.failure {
                ScopedBanner(failure) { model.retryRule(row.bundleID) }
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.m)
                    .accessibilityIdentifier("apps.rule.failure.\(row.bundleID)")
            }
            if expanded { controls }
        }
        .accessibilityIdentifier("apps.row.\(row.bundleID)")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(row.bundleID)
                .windowFont(Tokens.Typography.key)
                .foregroundStyle(WindowColor.secondaryInk)
                .textSelection(.enabled)
            style
            contextual
            typing
            HStack(spacing: Tokens.Spacing.s) {
                Text(DictionaryAppsCopy.wordMarksTitle).windowFont(Tokens.Typography.body)
                StatusTag(row.wordMarks.tag, kind: row.wordMarks == .supported ? .good : .warn)
                Text(row.wordMarks.detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("apps.wordMarks.\(row.bundleID)")
            writingInstructions
            Button(DictionaryAppsCopy.useDefaults, role: .destructive) {
                expanded = false
                model.removeApp(row.bundleID)
            }
            .accessibilityIdentifier("apps.remove.\(row.bundleID)")
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Uses default" beside an inherited value; a reset beside the app's own.
    @ViewBuilder private func inheritance(usesDefault: Bool, reset: @escaping () -> Void) -> some View {
        if usesDefault {
            Text(DictionaryAppsCopy.usesDefault)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
        } else {
            Button("Use default", action: reset).buttonStyle(.link)
        }
    }

    @ViewBuilder private var style: some View {
        if row.rule.styleIsLocked {
            HStack(spacing: Tokens.Spacing.s) {
                Text(DictionaryAppsCopy.writingStyle).windowFont(Tokens.Typography.body)
                StatusTag(DictionaryAppsCopy.verbatim)
                Text(DictionaryAppsCopy.codeProfileDetail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: Tokens.Spacing.s) {
                Picker(DictionaryAppsCopy.writingStyle, selection: Binding<AppWritingStyle?>(
                    get: { row.rule.style.usesDefault ? nil : row.rule.style.value },
                    set: { model.setStyle($0, for: row.bundleID) }
                )) {
                    Text(DictionaryAppsCopy.defaultOption(model.book.defaults.style.title)).tag(AppWritingStyle?.none)
                    ForEach(AppWritingStyle.allCases) { Text($0.title).tag(AppWritingStyle?.some($0)) }
                }
                .frame(maxWidth: 320)
                .accessibilityIdentifier("apps.style.\(row.bundleID)")
                inheritance(usesDefault: row.rule.style.usesDefault) { model.setStyle(nil, for: row.bundleID) }
            }
        }
    }

    private var contextual: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Picker(DictionaryAppsCopy.contextualReading, selection: Binding<Bool?>(
                get: { row.rule.contextualReading.usesDefault ? nil : row.rule.contextualReading.value },
                set: { model.setContextualReading($0, for: row.bundleID) }
            )) {
                Text(DictionaryAppsCopy.defaultOption(model.book.defaults.contextualReading ? DictionaryAppsCopy.on : DictionaryAppsCopy.off))
                    .tag(Bool?.none)
                Text(DictionaryAppsCopy.on).tag(Bool?.some(true))
                Text(DictionaryAppsCopy.off).tag(Bool?.some(false))
            }
            .frame(maxWidth: 320)
            .accessibilityIdentifier("apps.contextualReading.\(row.bundleID)")
            inheritance(usesDefault: row.rule.contextualReading.usesDefault) { model.setContextualReading(nil, for: row.bundleID) }
        }
    }

    /// R2.3 insertion eligibility, with its consequence stated beside the switch.
    private var typing: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Toggle(DictionaryAppsCopy.typeIntoApp, isOn: Binding(
                get: { row.rule.mayInsert },
                set: { model.setNeverInject(!$0, bundleID: row.bundleID) }
            ))
            .toggleStyle(.switch)
            .accessibilityIdentifier("apps.neverInject.\(row.bundleID)")
            if row.neverInject {
                Text(DictionaryAppsSectionViewModel.neverInjectConsequence)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
    }

    /// P2.5 — the app's writing instructions (persona), used when the style is Clear & natural.
    private var writingInstructions: some View {
        let text = Binding(get: { instructions ?? model.personaFailures[row.bundleID] ?? row.persona ?? "" },
                           set: { instructions = $0 })
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(DictionaryAppsCopy.writingInstructions).windowFont(Tokens.Typography.body)
            Text(DictionaryAppsCopy.writingInstructionsDetail)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            TextField(DictionaryAppsCopy.writingInstructions, text: text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("apps.personas.instructions")
            if let learned = model.personas.learnedLine(for: row.bundleID) {   // V5 F1
                Text(learned)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("apps.personas.learned")
            }
            if let failure = model.instructionsFailure(for: row.bundleID) {
                ScopedBanner(failure) { _ = model.saveInstructions(text.wrappedValue, for: row.bundleID) }
            }
            HStack(spacing: Tokens.Spacing.s) {
                Button(DictionaryAppsCopy.autoDraft) {
                    if let draft = model.autoDraftInstructions(for: row.bundleID) { instructions = draft }
                }
                .accessibilityIdentifier("apps.personas.autoDraft")
                Spacer()
                Button(DictionaryAppsCopy.saveInstructions) {
                    if model.saveInstructions(text.wrappedValue, for: row.bundleID) { instructions = nil }
                }
                .accessibilityIdentifier("apps.personas.save")
            }
            .controlSize(.small)
        }
    }
}

/// "Add an app": the apps running now, any app chosen from Applications, or a bundle ID typed in.
/// The app is added with no values of its own — it uses the defaults until one is set.
struct AddAppSheet: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel
    let onAdded: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID = ""
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text(DictionaryAppsCopy.addApp)
                .windowFont(Tokens.Typography.section)
                .accessibilityAddTraits(.isHeader)
            let running = model.runningApps()
            if !running.isEmpty {
                GroupBox(DictionaryAppsCopy.runningNow, layout: .rows) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(running) { app in
                                RowView(app.name, detail: app.bundleID) {
                                    Button(DictionaryAppsCopy.add) { add(app) }
                                        .controlSize(.small)
                                        .accessibilityLabel("Add \(app.name)")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            Button(DictionaryAppsCopy.chooseApplication) { choosing = true }
                .accessibilityIdentifier("apps.chooseApplication")
            HStack(spacing: Tokens.Spacing.s) {
                TextField(DictionaryAppsCopy.bundleID, text: $bundleID, prompt: Text(DictionaryAppsCopy.bundleIDPrompt))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                    .accessibilityIdentifier("apps.personas.bundleID")
                Button(DictionaryAppsCopy.add, action: addTyped)
                    .disabled(bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button(DictionaryAppsCopy.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: 460)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let app = model.identity(ofApplicationAt: url) { add(app) }
        }
    }

    private func add(_ app: AppIdentity) {
        model.addApp(app)
        onAdded(app.bundleID)
        dismiss()
    }

    private func addTyped() {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.addApp(bundleID: trimmed)
        onAdded(trimmed)
        dismiss()
    }
}
