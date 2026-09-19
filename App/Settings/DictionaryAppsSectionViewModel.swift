import Engine
import Foundation
import Injection
import Shared

// S7d — Dictionary & Apps (design §8.3, §9). Two segmented panes, each with exactly one base
// rendering (content / empty / loading / error) under the page header and the segmented control:
//
// - **Dictionary**: search, every word with its spoken variant, language and source, add / edit in
//   a form that resolves duplicates and spoken-form conflicts inline, import with a preview (a word
//   list, or Contacts: explain → preview → commit), the words learned from corrections, and the
//   spoken snippets.
// - **Apps**: the inherited default, then one row per app with a rule — its style, whether VoicePlus
//   may type into it (never-inject), contextual reading, and whether word marks can be drawn there.
//   "Uses default" is shown apart from an override; code and terminal apps are verbatim and nothing
//   ever presses Return.
//
// A save that fails keeps what the user entered on screen, marks it unsaved, and leaves the previous
// value active (S02 inline: "Changes weren’t saved · Your previous setting is still active."). Every
// state is decided here, never in a `body`, so it is testable on a toolchain with no UI testing.

/// Every sentence the section says that is not the design's page or empty copy.
public enum DictionaryAppsCopy {
    // MARK: States (design §9 table)
    public static let loadingDictionary = "Loading dictionary…"
    public static let loadingApps = "Loading app rules…"
    public static let dictionaryUnreadable = "The dictionary can’t be read"
    public static let dictionaryUnreadableDetail = "Your saved words haven’t been cleared."
    public static let appsUnreadable = "App rules can’t be read"
    public static let appsUnreadableDetail = "Nothing was cleared, and apps you never type into stay protected."
    public static let appsEmpty = "Every app uses your defaults"
    public static let appsEmptyDetail = "Add an app to give it its own style, typing rule or contextual reading."
    public static let tryAgain = "Try again"
    public static func noMatches(_ query: String) -> String { "No matches for “\(query)”" }
    public static let clearSearch = "Clear search"

    // MARK: Dictionary
    public static let searchPrompt = "Search your words"
    public static let addWord = "Add a word"
    public static let editWord = "Edit spelling"
    public static let edit = "Edit"
    public static let saveWord = "Save word"
    public static let deleteWord = "Delete word"
    public static let cancel = "Cancel"
    public static let keepEditing = "Keep editing"
    public static let spelling = "Spelling"
    public static let spellingPrompt = "e.g. Meera"
    public static let spokenForm = "Spoken form"
    public static let spokenFormPrompt = "e.g. mee rah"
    public static let spokenFormHelp = "How it sounds, if that differs from the spelling. Separate several with commas."
    public static let language = "Language"
    public static let trainByVoice = "Train by voice…"
    /// Prototype, under the word list.
    public static let rememberNote = "Only spellings you choose to remember are added."
    public static let importWords = "Import words…"
    public static let importFromContacts = "Import from Contacts…"
    public static let importTitle = "Import words"
    public static let selectAll = "Select all"
    public static let selectNone = "Select none"
    public static let learnedTitle = "Learned from your corrections"
    public static let forget = "Forget"
    public static let snippetsTitle = "Snippets"
    public static func added(_ count: Int, fromContacts: Bool) -> String {
        let noun = fromContacts ? (count == 1 ? "name" : "names") : (count == 1 ? "word" : "words")
        return "Added \(count) \(noun)" + (fromContacts ? " from Contacts." : ".")
    }

    // MARK: Apps
    public static let addApp = "Add an app"
    public static let defaultsTitle = "Defaults"
    public static let appRulesTitle = "App rules"
    public static let writingStyle = "Writing style"
    public static let writingStyleDetail = "Every app without its own rule writes this way."
    public static let contextualReading = "Contextual reading"
    public static let contextualReadingDetail = "Reads text near your words and inside boxes you draw, to spell names right. Stays on this Mac."
    public static let codeProfileTitle = "Code editors and terminals"
    public static let codeProfileDetail = "Keep commands exactly as spoken. Never presses Return."
    public static let verbatim = "Verbatim"
    public static let usesDefault = "Uses default"
    public static func defaultOption(_ value: String) -> String { "Default (\(value))" }
    public static let on = "On"
    public static let off = "Off"
    public static let typeIntoApp = "Type into this app"
    public static let writingInstructions = "Writing instructions"
    public static let writingInstructionsDetail = "Plain English, for this app. Example: “Casual, short, no sign-off.”"
    public static let autoDraft = "Auto-draft from my style"
    public static let saveInstructions = "Save instructions"
    public static let wordMarksTitle = "Word marks"
    public static let useDefaults = "Use defaults for this app"
    public static let notSaved = "Not saved"
    public static let runningNow = "Running now"
    public static let chooseApplication = "Choose from Applications…"
    public static let bundleID = "Bundle ID"
    public static let bundleIDPrompt = "e.g. com.tinyspeck.slackmacgap"
    public static let add = "Add"
    public static let neverTypedHere = "Never typed here"
}

/// One app row: the app, its rule as the controls show it, and its overlay capability.
public struct AppPolicyRow: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    /// The app's writing instructions (P2.5 persona), if any.
    public var persona: String?
    /// The rule as entered — the active one unless a save failed.
    public var rule: ResolvedAppRule
    public var wordMarks: WordMarkSupport
    /// The entered rule differs from the active one (a save failed).
    public var isUnsaved: Bool
    /// The inline S02 row, when the last save failed.
    public var failure: SectionBanner?

    public var neverInject: Bool { !rule.mayInsert }

    /// Nothing of the app's own: every value is the default and it has no writing instructions.
    public var usesDefaults: Bool {
        rule.style.usesDefault && rule.contextualReading.usesDefault && rule.mayInsert && persona == nil
    }

    /// The row's second line: "Uses default", or what is the app's own.
    public var summary: String {
        var parts: [String] = []
        if rule.profile.isVerbatim {
            parts.append(DictionaryAppsCopy.verbatim)
        } else if !rule.style.usesDefault {
            parts.append(rule.style.value.title)
        }
        if !rule.contextualReading.usesDefault {
            parts.append("\(DictionaryAppsCopy.contextualReading) \(rule.contextualReading.value ? "on" : "off")")
        }
        if neverInject { parts.append(DictionaryAppsCopy.neverTypedHere) }
        if persona != nil { parts.append(DictionaryAppsCopy.writingInstructions) }
        return parts.isEmpty ? DictionaryAppsCopy.usesDefault : parts.joined(separator: " · ")
    }
}

/// The add / edit form. What the user typed stays here, untouched, until a save succeeds.
public struct DictionaryTermEditor: Equatable, Identifiable {
    public var id: String { draft.editingID ?? "new" }
    public var draft: DictionaryTermDraft
    /// Why the entry cannot be saved as typed.
    public var validation: String?
    /// The collision to resolve inline.
    public var conflict: DictionaryConflict?
    /// The resolution the user chose; a retry after a failed save applies it again.
    public var resolving: DictionaryConflict?
    /// The last save failed (S02): nothing changed, the entry is still here.
    public var failure: RecoveryID?

    public init(draft: DictionaryTermDraft) { self.draft = draft }

    public var title: String { draft.isNew ? DictionaryAppsCopy.addWord : DictionaryAppsCopy.editWord }
    public var failureBanner: SectionBanner? { failure.map { SectionBanner.recovery(RecoveryCatalog.entry($0)) } }
}

/// An import in progress: Contacts' explanation and access request, then the preview for either.
public struct DictionaryImportSession: Equatable, Identifiable {
    public enum Step: Equatable {
        /// Contacts only: why, and what is read, before the system prompt.
        case explainContacts
        /// Contacts only: waiting on the system prompt.
        case requestingAccess
        /// The rows, nothing written yet.
        case preview
    }

    public var id: String { origin == .contacts ? "contacts" : "file" }
    public var origin: DictionaryImportPreview.Origin
    public var step: Step
    public var preview: DictionaryImportPreview
    /// X04 when nothing in the import can be added (or Contacts could not be read); S02 when the
    /// commit failed. Either way the dictionary is unchanged.
    public var failure: RecoveryID?

    public var title: String { origin == .contacts ? ContactsImportCopy.title : DictionaryAppsCopy.importTitle }
    public var failureBanner: SectionBanner? { failure.map { SectionBanner.recovery(RecoveryCatalog.entry($0)) } }
    public var canCommit: Bool { step == .preview && !preview.selected.isEmpty }
}

/// What the page banner's action does.
public enum DictionaryAppsBannerAction: Equatable, Sendable {
    case openContactsSettings
    case dismiss
}

@MainActor
public final class DictionaryAppsSectionViewModel: ObservableObject {
    // MARK: Pane states

    @Published public private(set) var dictionaryState: SectionState =
        .loading(.dictionary, headline: DictionaryAppsCopy.loadingDictionary)
    @Published public private(set) var appsState: SectionState =
        .loading(.dictionary, headline: DictionaryAppsCopy.loadingApps)
    /// A failure beside the panes (Contacts denied), never instead of them.
    @Published public private(set) var banner: SectionBanner?
    @Published public private(set) var bannerAction: DictionaryAppsBannerAction?
    /// A verified success line ("Added 12 words.").
    @Published public private(set) var notice: String?

    // MARK: Dictionary

    /// The saved words, as last read from the store.
    @Published public private(set) var terms: [DictionaryTerm] = []
    @Published public var editor: DictionaryTermEditor?
    @Published public var importSession: DictionaryImportSession?

    // MARK: Apps

    /// The rules in force.
    @Published public private(set) var book = AppRuleBook()
    @Published public private(set) var apps: [AppPolicyRow] = []
    /// The defaults as the controls show them (entered) and as the app uses them (active).
    @Published public private(set) var defaultsDraft = SettingDraft(AppRuleDefaults.standard)
    /// Per app, a rule whose save failed: entered (`nil` = removal) vs active.
    @Published public private(set) var ruleDrafts: [String: SettingDraft<AppRule?>] = [:]
    /// Per app, writing instructions whose save failed, as entered.
    @Published public private(set) var personaFailures: [String: String] = [:]

    public let learned: LearnedDictionaryViewModel
    public let personas: PersonasViewModel
    public let snippets: SnippetsViewModel

    private var termStore: DictionaryTermStoring?
    private var isConnected: Bool
    /// For the writing-instructions auto-draft (style learnings live in the app database).
    private var database: AppDatabase?
    private let ruleStore: AppRuleStoring
    private let wordMarks: WordMarkCapabilityProviding
    private let identities: AppIdentityResolving

    /// Everything injected: the word store (`nil` = not connected yet — the pane shows loading until
    /// `connect`), the rule store, the S5 overlay record and the app-name lookup.
    public init(terms: DictionaryTermStoring?,
                learned: LearnedDictionaryViewModel,
                personas: PersonasViewModel,
                snippets: SnippetsViewModel,
                rules: AppRuleStoring,
                wordMarks: WordMarkCapabilityProviding,
                identities: AppIdentityResolving) {
        self.termStore = terms
        self.isConnected = terms != nil
        self.learned = learned
        self.personas = personas
        self.snippets = snippets
        self.ruleStore = rules
        self.wordMarks = wordMarks
        self.identities = identities
        reload()
    }

    /// The composition root's R7 signature (`MainWindowController`). `dictionary` is no longer read:
    /// the section reads and writes words through the store its screen connects on appear
    /// (`connect(database:)`), which is what lets a failed save be seen at all.
    public convenience init(dictionary: DictionaryViewModel,
                            learned: LearnedDictionaryViewModel,
                            personas: PersonasViewModel,
                            snippets: SnippetsViewModel,
                            defaults: UserDefaults = .standard) {
        self.init(terms: nil, learned: learned, personas: personas, snippets: snippets,
                  rules: UserDefaultsAppRuleStore(defaults: defaults),
                  wordMarks: RecordedWordMarkCapability(defaults: defaults),
                  identities: WorkspaceAppIdentities())
    }

    /// Connects the app database once. `nil` (no database) is a read failure, not an empty list.
    public func connect(database: AppDatabase?) {
        guard !isConnected else { return }
        isConnected = true
        self.database = database
        termStore = database.map { DatabaseDictionaryTermStore(database: $0) }
        reloadTerms()
    }

    public func reload() {
        learned.reload()
        personas.reload()
        snippets.reload()
        reloadTerms()
        reloadRules()
    }

    // MARK: - Dictionary: reading

    public func reloadTerms() {
        guard isConnected else {
            dictionaryState = .loading(.dictionary, headline: DictionaryAppsCopy.loadingDictionary)
            return
        }
        do {
            guard let termStore else { throw NoDatabase() }
            terms = try termStore.loadTerms()
            updateDictionaryState()
        } catch {
            Log.app.error("dictionary: read failed: \(error)")
            dictionaryState = .error(DictionaryAppsCopy.dictionaryUnreadable,
                                     detail: DictionaryAppsCopy.dictionaryUnreadableDetail,
                                     action: DictionaryAppsCopy.tryAgain)
        }
    }

    /// The app database did not open: the words exist somewhere this build cannot read.
    private struct NoDatabase: Error {}

    private func updateDictionaryState() {
        let copy = DesignScreen.dictionary.empty
        dictionaryState = terms.isEmpty && learned.entries.isEmpty
            ? .empty(copy.headline, detail: copy.body, action: copy.action)
            : .content
    }

    public func filteredTerms(_ query: String) -> [DictionaryTerm] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? terms : terms.filter { $0.matches(q) }
    }

    public func filteredLearned(_ query: String) -> [LearnedDictionaryViewModel.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? learned.entries : learned.entries.filter {
            $0.spelling.localizedCaseInsensitiveContains(q) || $0.heardAs.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    /// True when a search hides every word and every learned entry: the pane says "No matches for …"
    /// with Clear search, never the empty state (design §9 "Search" row).
    public func searchFindsNothing(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && filteredTerms(query).isEmpty && filteredLearned(query).isEmpty
    }

    public func forget(_ entry: LearnedDictionaryViewModel.Entry) {
        learned.forget(entry)
        if dictionaryState.rendering != .error, isConnected { updateDictionaryState() }
    }

    // MARK: - Dictionary: add / edit

    public func beginAdd(spelling: String = "") {
        notice = nil
        editor = DictionaryTermEditor(draft: DictionaryTermDraft(spelling: spelling))
    }

    public func beginEdit(_ term: DictionaryTerm) {
        notice = nil
        editor = DictionaryTermEditor(draft: DictionaryTermDraft(editing: term))
    }

    /// Typing changes the entry: a pending conflict or validation message no longer applies.
    public func updateDraft(_ draft: DictionaryTermDraft) {
        guard var e = editor, e.draft != draft else { return }
        e.draft = draft
        e.validation = nil
        e.conflict = nil
        e.resolving = nil
        editor = e
    }

    /// Saves the form. Validation or a conflict keeps it open with a message; a failed write keeps
    /// it open with S02 and the entry intact, and the list still shows the saved words.
    @discardableResult
    public func saveEditor() -> Bool {
        guard var e = editor else { return false }
        if let problem = DictionaryRules.validate(spelling: e.draft.spelling) {
            e.validation = problem
            editor = e
            return false
        }
        e.validation = nil
        let conflict = DictionaryRules.conflict(for: e.draft, in: terms)
        if let conflict, e.resolving != conflict {
            e.conflict = conflict
            e.resolving = nil
            editor = e
            return false
        }
        guard let changes = DictionaryRules.changes(saving: e.draft, over: terms, resolving: conflict) else {
            e.conflict = conflict
            editor = e
            return false
        }
        guard write(changes) else {
            e.failure = .S02
            editor = e
            return false
        }
        editor = nil
        reloadTerms()
        return true
    }

    /// The conflict's inline resolution: saves with it.
    @discardableResult
    public func resolveConflict() -> Bool {
        guard var e = editor, let conflict = e.conflict, conflict.resolveTitle(for: e.draft) != nil else { return false }
        e.resolving = conflict
        e.conflict = nil
        editor = e
        return saveEditor()
    }

    /// Dismisses the conflict; the entry stays as typed and nothing is saved.
    public func keepEditing() {
        guard var e = editor else { return }
        e.conflict = nil
        e.resolving = nil
        editor = e
    }

    public func cancelEditor() { editor = nil }

    /// Deletes the word being edited. A failed delete keeps the form and the word.
    @discardableResult
    public func deleteEditedTerm() -> Bool {
        guard var e = editor, let id = e.draft.editingID else { return false }
        guard write(DictionaryChangeSet(deletions: [id])) else {
            e.failure = .S02
            editor = e
            return false
        }
        editor = nil
        reloadTerms()
        return true
    }

    private func write(_ changes: DictionaryChangeSet) -> Bool {
        guard let termStore else { return false }
        do {
            try termStore.apply(changes)
            return true
        } catch {
            Log.app.error("dictionary: save failed: \(error)")
            return false
        }
    }

    // MARK: - Dictionary: import

    /// A word list read from a file: the preview, nothing written. A list with no usable line is X04.
    public func beginFileImport(text: String, fileName: String) {
        notice = nil
        let preview = DictionaryImportPreview.build(origin: .file(fileName), entries: DictionaryImportParser.parse(text),
                                                    existing: terms)
        importSession = DictionaryImportSession(origin: .file(fileName), step: .preview, preview: preview,
                                                failure: preview.hasNothingValid ? .X04 : nil)
    }

    /// A file that could not be read at all.
    public func fileImportFailed(fileName: String) {
        importSession = DictionaryImportSession(origin: .file(fileName), step: .preview,
                                                preview: DictionaryImportPreview(origin: .file(fileName), candidates: []),
                                                failure: .X04)
    }

    /// Contacts: the explanation first; nothing is asked of the system yet.
    public func beginContactsImport() {
        notice = nil
        importSession = DictionaryImportSession(origin: .contacts, step: .explainContacts,
                                                preview: DictionaryImportPreview(origin: .contacts, candidates: []))
    }

    /// After the explanation: the system prompt (if needed), then the preview. Denied closes the
    /// flow with the banner that opens System Settings.
    public func continueContactsImport(offer: ContactsImportOffer) async {
        guard var session = importSession, session.origin == .contacts, session.step == .explainContacts else { return }
        session.step = .requestingAccess
        importSession = session
        let result = await offer.requestNames()
        guard importSession?.origin == .contacts else { return } // cancelled meanwhile
        switch result {
        case .denied:
            importSession = nil
            reportContactsDenied()
        case .unavailable:
            session.step = .preview
            session.failure = .X04
            importSession = session
        case .names(let names):
            let entries = ContactsImportMapper.candidates(names: names).map { DictionaryImportEntry(spelling: $0) }
            session.step = .preview
            session.preview = DictionaryImportPreview.build(origin: .contacts, entries: entries, existing: terms)
            session.failure = nil
            importSession = session
        }
    }

    public func toggleImportCandidate(_ id: Int) { importSession?.preview.toggle(id) }

    public func setAllImportCandidates(_ selected: Bool) { importSession?.preview.setAll(selected) }

    /// Writes the selected rows in one transaction. Success is announced only after the words read
    /// back; a failure keeps the preview (S02) and changes nothing.
    @discardableResult
    public func commitImport() -> Bool {
        guard var session = importSession, session.canCommit else { return false }
        let chosen = session.preview.selected
        guard write(session.preview.changes(over: terms)) else {
            session.failure = .S02
            importSession = session
            return false
        }
        importSession = nil
        reloadTerms()
        let saved = Set(terms.map { DictionaryRules.key($0.spelling) })
        let landed = chosen.filter { saved.contains(DictionaryRules.key($0.spelling)) }.count
        notice = DictionaryAppsCopy.added(landed, fromContacts: session.origin == .contacts)
        return true
    }

    public func cancelImport() { importSession = nil }

    // MARK: - Apps: reading

    public func reloadRules() {
        do {
            book = try ruleStore.load()
            defaultsDraft = SettingDraft(book.defaults)
            ruleDrafts = [:]
            rebuildApps()
        } catch {
            Log.app.error("apps: rules unreadable: \(error)")
            apps = []
            appsState = .error(DictionaryAppsCopy.appsUnreadable, detail: DictionaryAppsCopy.appsUnreadableDetail,
                               action: DictionaryAppsCopy.tryAgain)
        }
    }

    private func rebuildApps() {
        let personaByApp = Dictionary(personas.personas.map { ($0.appBundleID, $0.instructions) }, uniquingKeysWith: { a, _ in a })
        let bundles = Set(book.rules.keys).union(ruleDrafts.keys).union(personaByApp.keys)
        apps = bundles.map { bundleID in
            let draft = ruleDrafts[bundleID]
            let entered = draft.map { $0.entered ?? AppRule(bundleID: bundleID) } ?? book.rule(for: bundleID)
            let resolved = AppRuleBook(defaults: book.defaults, rules: [bundleID: entered]).resolved(for: bundleID)
            return AppPolicyRow(bundleID: bundleID,
                                name: entered.name ?? identities.name(for: bundleID) ?? bundleID,
                                persona: personaByApp[bundleID],
                                rule: resolved,
                                wordMarks: wordMarks.wordMarks(for: bundleID),
                                isUnsaved: draft?.isUnsaved ?? false,
                                failure: draft?.failureBanner)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appsState = apps.isEmpty
            ? .empty(DictionaryAppsCopy.appsEmpty, detail: DictionaryAppsCopy.appsEmptyDetail, action: DictionaryAppsCopy.addApp)
            : .content
    }

    public func filteredApps(_ query: String) -> [AppPolicyRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Apps: defaults

    public func setDefaultStyle(_ style: AppWritingStyle) {
        var draft = defaultsDraft
        draft.entered.style = style
        commitDefaults(draft)
    }

    public func setDefaultContextualReading(_ on: Bool) {
        var draft = defaultsDraft
        draft.entered.contextualReading = on
        commitDefaults(draft)
    }

    public func retryDefaults() { commitDefaults(defaultsDraft) }

    public func revertDefaults() {
        var draft = defaultsDraft
        draft.revert()
        defaultsDraft = draft
    }

    private func commitDefaults(_ draft: SettingDraft<AppRuleDefaults>) {
        var draft = draft
        let current = book
        if draft.commit({ value in
            var next = current
            next.defaults = value
            try ruleStore.save(next)
        }) {
            book.defaults = draft.active
        }
        defaultsDraft = draft
        rebuildApps()
    }

    // MARK: - Apps: one app

    public func isNeverInject(_ bundleID: String) -> Bool { book.neverInject.contains(bundleID) }

    /// Adds an app with no values of its own (it uses the defaults until one is set).
    public func addApp(_ identity: AppIdentity) {
        let bundleID = identity.bundleID.trimmingCharacters(in: .whitespaces)
        guard !bundleID.isEmpty, book.rules[bundleID] == nil else { return }
        commitRule(bundleID, AppRule(bundleID: bundleID, name: identity.name))
    }

    /// Adds an app by bundle ID, named if it is installed.
    public func addApp(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        addApp(AppIdentity(bundleID: trimmed, name: identities.name(for: trimmed) ?? trimmed))
    }

    public func setStyle(_ style: AppWritingStyle?, for bundleID: String) { change(bundleID) { $0.style = style } }

    public func setContextualReading(_ on: Bool?, for bundleID: String) { change(bundleID) { $0.contextualReading = on } }

    /// R2.3 — insertion eligibility. On: dictation for this app is held, never typed.
    public func setNeverInject(_ on: Bool, bundleID: String) {
        guard !bundleID.isEmpty else { return }
        change(bundleID) { $0.neverInject = on }
    }

    /// Back to the defaults: the rule and its writing instructions go.
    public func removeApp(_ bundleID: String) {
        commitRule(bundleID, nil)
        if personas.personas.contains(where: { $0.appBundleID == bundleID }) {
            personas.delete(appBundleID: bundleID)
            rebuildApps()
        }
    }

    /// Retries the app's failed save with the value still entered.
    public func retryRule(_ bundleID: String) {
        guard let draft = ruleDrafts[bundleID] else { return }
        commitRule(bundleID, draft.entered)
    }

    /// Puts the active value back in the app's controls.
    public func revertRule(_ bundleID: String) {
        ruleDrafts[bundleID] = nil
        rebuildApps()
    }

    private func change(_ bundleID: String, _ edit: (inout AppRule) -> Void) {
        var rule = ruleDrafts[bundleID].map { $0.entered ?? AppRule(bundleID: bundleID) } ?? book.rule(for: bundleID)
        if rule.name == nil { rule.name = identities.name(for: bundleID) }
        edit(&rule)
        commitRule(bundleID, rule)
    }

    private func commitRule(_ bundleID: String, _ entered: AppRule?) {
        var draft = SettingDraft<AppRule?>(book.rules[bundleID])
        draft.entered = entered
        let current = book
        if draft.commit({ value in
            var next = current
            next.rules[bundleID] = value
            try ruleStore.save(next)
        }) {
            book.rules[bundleID] = draft.active
            ruleDrafts[bundleID] = nil
        } else {
            ruleDrafts[bundleID] = draft
        }
        rebuildApps()
    }

    // MARK: - Apps: writing instructions (P2.5 personas)

    /// Saves (or, when empty, removes) the app's writing instructions, and reads them back: a save
    /// that did not stick is reported inline with the text kept.
    @discardableResult
    public func saveInstructions(_ text: String, for bundleID: String) -> Bool {
        personas.save(appBundleID: bundleID, instructions: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = personas.personas.first { $0.appBundleID == bundleID }?.instructions
        let ok = trimmed.isEmpty ? stored == nil : stored == trimmed
        personaFailures[bundleID] = ok ? nil : text
        rebuildApps()
        return ok
    }

    /// P2.5 — a draft of the app's instructions from the style learned there; never saved by itself.
    public func autoDraftInstructions(for bundleID: String) -> String? {
        personas.autoDraft(appBundleID: bundleID, database: database)
    }

    public func instructionsFailure(for bundleID: String) -> SectionBanner? {
        personaFailures[bundleID] == nil ? nil : SectionBanner.recovery(RecoveryCatalog.entry(.S02))
    }

    public func runningApps() -> [AppIdentity] {
        identities.runningApps().filter { book.rules[$0.bundleID] == nil }
    }

    public func identity(ofApplicationAt url: URL) -> AppIdentity? { identities.identity(ofApplicationAt: url) }

    // MARK: - Banner (R7 wording, kept)

    /// One line of consequence, stated next to the typing switch (`DESIGN.md` §9.3).
    public static let neverInjectConsequence = "Dictation is held here, never typed"

    public func reportContactsDenied() {
        banner = SectionBanner(headline: SectionCopy.contactsDenied, actionTitle: SectionCopy.openSystemSettings)
        bannerAction = .openContactsSettings
    }

    public func reportWriteFailure(_ detail: String) {
        banner = SectionBanner(headline: SectionCopy.notSaved, actionTitle: SectionCopy.tryAgain, diagnostics: detail)
        bannerAction = .dismiss
    }

    public func clearBanner() {
        banner = nil
        bannerAction = nil
    }

    public func clearNotice() { notice = nil }
}
