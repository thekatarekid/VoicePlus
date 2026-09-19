import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

// S7d — Dictionary & Apps (design §8.3, §9). The panes' states, the dictionary's rules (duplicates,
// spoken-form conflicts, inline resolution), import previews (file and Contacts: explain → preview →
// commit), the Apps rules ("Uses default" vs override, style, never-inject, contextual reading, word
// marks, verbatim code / terminal, never Return), and every failed save keeping the entered value with
// the previous one still active (S02). No UI testing on this toolchain: everything a pane shows is a
// value these tests read.

// MARK: - Test doubles

final class ScriptedTermStore: DictionaryTermStoring {
    var terms: [DictionaryTerm]
    var failSaves = false
    var failLoads = false
    private(set) var applied: [DictionaryChangeSet] = []

    init(_ terms: [DictionaryTerm] = []) { self.terms = terms }

    struct Failure: Error {}

    func loadTerms() throws -> [DictionaryTerm] {
        if failLoads { throw Failure() }
        return terms.sorted(by: DictionaryTermStoreOrder.alphabetical)
    }

    func apply(_ changes: DictionaryChangeSet) throws {
        if failSaves { throw Failure() }
        applied.append(changes)
        terms.removeAll { changes.deletions.contains($0.id) }
        for term in changes.upserts {
            if let i = terms.firstIndex(where: { $0.id == term.id }) { terms[i] = term } else { terms.append(term) }
        }
    }
}

final class ScriptedRuleStore: AppRuleStoring {
    var book: AppRuleBook
    var failSaves = false
    var failLoads = false

    init(_ book: AppRuleBook = AppRuleBook()) { self.book = book }

    func load() throws -> AppRuleBook {
        if failLoads { throw AppRuleStoreError.unreadable }
        return book
    }

    func save(_ book: AppRuleBook) throws {
        if failSaves { throw AppRuleStoreError.notPersisted }
        self.book = book
    }
}

final class StaticIdentities: AppIdentityResolving {
    var names: [String: String] = ["com.apple.mail": "Mail", "com.apple.Terminal": "Terminal",
                                   "com.microsoft.VSCode": "Visual Studio Code", "com.apple.Notes": "Notes"]
    var running: [AppIdentity] = [AppIdentity(bundleID: "com.apple.mail", name: "Mail"),
                                  AppIdentity(bundleID: "com.apple.Notes", name: "Notes")]
    func name(for bundleID: String) -> String? { names[bundleID] }
    func runningApps() -> [AppIdentity] { running }
    func identity(ofApplicationAt url: URL) -> AppIdentity? { nil }
}

final class StaticWordMarks: WordMarkCapabilityProviding {
    var supported: Set<String>
    init(_ supported: Set<String> = []) { self.supported = supported }
    func wordMarks(for bundleID: String) -> WordMarkSupport { supported.contains(bundleID) ? .supported : .unavailable }
}

enum S7dFixture {
    @MainActor
    static func model(terms: DictionaryTermStoring? = ScriptedTermStore(),
                      rules: AppRuleStoring = ScriptedRuleStore(),
                      marks: Set<String> = [],
                      personas: PersonasViewModel? = nil,
                      identities: StaticIdentities = StaticIdentities()) -> DictionaryAppsSectionViewModel {
        DictionaryAppsSectionViewModel(terms: terms,
                                       learned: LearnedDictionaryViewModel(loop: nil, store: nil),
                                       personas: personas ?? PersonasViewModel(database: nil),
                                       snippets: SnippetsViewModel(store: InMemorySnippetStore()),
                                       rules: rules,
                                       wordMarks: StaticWordMarks(marks),
                                       identities: identities)
    }

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "vp.s7d.\(UUID().uuidString)")! }

    static let meera = DictionaryTerm(id: "meera", spelling: "Meera", spokenForms: ["mee rah"], language: .english,
                                      source: .personal)
}

// MARK: - The dictionary's rules

@Suite("S7d · dictionary rules: validation, duplicates, spoken-form conflicts")
struct DictionaryRulesS7dTests {
    @Test("a spelling is a word or a short name, never a sentence, and never empty")
    func validation() {
        #expect(DictionaryRules.validate(spelling: "   ") == DictionaryRules.emptySpelling)
        #expect(DictionaryRules.validate(spelling: "1234") == DictionaryRules.notAWord)
        #expect(DictionaryRules.validate(spelling: "please remember this whole long sentence") == DictionaryRules.notASpelling)
        #expect(DictionaryRules.validate(spelling: "Meera") == nil)
        #expect(DictionaryRules.validate(spelling: "Jo Ann Smith") == nil)
    }

    @Test("spoken variants: separated by commas, trimmed, each once ignoring case and accents")
    func spokenForms() {
        #expect(DictionaryRules.spokenForms(" mee rah,  Mee Rah ; meéra,, ") == ["mee rah", "meéra"])
        #expect(DictionaryRules.key("  MEERA ") == DictionaryRules.key("meera"))
    }

    @Test("the same spelling is a duplicate; the word being edited never collides with itself")
    func duplicate() {
        let terms = [S7dFixture.meera]
        let conflict = DictionaryRules.conflict(for: DictionaryTermDraft(spelling: "meera"), in: terms)
        #expect(conflict == .duplicate(S7dFixture.meera))
        #expect(conflict?.message == "“Meera” is already in your dictionary.")
        #expect(conflict?.resolveTitle(for: DictionaryTermDraft(spelling: "meera")) == "Update “Meera”")
        #expect(DictionaryRules.conflict(for: DictionaryTermDraft(editing: S7dFixture.meera), in: terms) == nil)
    }

    @Test("adding a duplicate and resolving it keeps one word with every spoken variant")
    func duplicateResolutionMerges() throws {
        let draft = DictionaryTermDraft(spelling: "MEERA", spokenForms: "meera ji", language: .any)
        let changes = try #require(DictionaryRules.changes(saving: draft, over: [S7dFixture.meera],
                                                           resolving: .duplicate(S7dFixture.meera)))
        #expect(changes.deletions.isEmpty)
        #expect(changes.upserts.count == 1)
        let merged = try #require(changes.upserts.first)
        #expect(merged.id == "meera")
        #expect(merged.spelling == "MEERA")
        #expect(merged.spokenForms == ["mee rah", "meera ji"])
        #expect(merged.language == .english, "an 'any' language in the form does not erase the saved one")
    }

    @Test("renaming a word to another word's spelling merges it into that word")
    func editIntoDuplicateMerges() throws {
        let kube = DictionaryTerm(id: "k", spelling: "Kubernetes", spokenForms: ["koo ber net ease"])
        let typo = DictionaryTerm(id: "t", spelling: "Kubernetis", spokenForms: ["kube"])
        var draft = DictionaryTermDraft(editing: typo)
        draft.spelling = "kubernetes"
        let conflict = try #require(DictionaryRules.conflict(for: draft, in: [kube, typo]))
        #expect(conflict.resolveTitle(for: draft) == "Merge into “Kubernetes”")
        let changes = try #require(DictionaryRules.changes(saving: draft, over: [kube, typo], resolving: conflict))
        #expect(changes.deletions == ["t"])
        #expect(changes.upserts.map(\.id) == ["k"])
        #expect(changes.upserts.first?.spokenForms == ["koo ber net ease", "kube"])
    }

    @Test("a spoken variant that already spells another word is a conflict; resolving moves it")
    func spokenFormConflict() throws {
        let draft = DictionaryTermDraft(spelling: "Mira", spokenForms: "Mee Rah")
        let conflict = try #require(DictionaryRules.conflict(for: draft, in: [S7dFixture.meera]))
        #expect(conflict == .spokenForm("Mee Rah", owner: S7dFixture.meera))
        #expect(conflict.message == "“Mee Rah” already spells “Meera”.")
        #expect(conflict.resolveTitle(for: draft) == "Use it for “Mira”")
        let changes = try #require(DictionaryRules.changes(saving: draft, over: [S7dFixture.meera], resolving: conflict))
        #expect(changes.upserts.first { $0.id == "meera" }?.spokenForms == [])
        #expect(changes.upserts.contains { $0.spelling == "Mira" && $0.spokenForms == ["Mee Rah"] && $0.source == .personal })
    }

    @Test("another word's own spelling cannot be taken as a spoken variant: no resolving action")
    func spokenFormThatIsAnotherSpelling() {
        let draft = DictionaryTermDraft(spelling: "Mira", spokenForms: "meera")
        let conflict = DictionaryRules.conflict(for: draft, in: [S7dFixture.meera])
        #expect(conflict?.message == "“meera” is how “Meera” is spelled.")
        #expect(conflict?.resolveTitle(for: draft) == nil)
        #expect(DictionaryRules.changes(saving: draft, over: [S7dFixture.meera], resolving: conflict) == nil)
    }

    @Test("a row says spoken variant · language · source, each only when there is one")
    func rowDetail() {
        #expect(S7dFixture.meera.detail == "mee rah · English · Added by you")
        #expect(DictionaryTerm(spelling: "Ada", source: .contacts).detail == "From Contacts")
        #expect(DictionaryTerm(record: DictionaryRecord(term: "GRDB", spokenForms: "gee are dee bee")).detail
                == "gee are dee bee · Saved earlier")
    }
}

// MARK: - The store

@Suite("S7d · the dictionary store: words in `dictionary`, language and source beside them")
struct DictionaryTermStoreS7dTests {
    @Test("words round-trip with language and source; the dictionary table keeps what biasing reads")
    func roundTrip() throws {
        let database = try AppDatabase.inMemory()
        try database.save(DictionaryRecord(id: "old", term: "Grafana"))
        let store = DatabaseDictionaryTermStore(database: database)
        try store.apply(DictionaryChangeSet(upserts: [S7dFixture.meera,
                                                      DictionaryTerm(id: "ada", spelling: "Ada", source: .contacts)]))
        let terms = try store.loadTerms()
        #expect(terms.map(\.spelling) == ["Ada", "Grafana", "Meera"])
        #expect(terms.first { $0.id == "meera" }?.language == .english)
        #expect(terms.first { $0.id == "meera" }?.spokenForms == ["mee rah"])
        #expect(terms.first { $0.id == "ada" }?.source == .contacts)
        #expect(terms.first { $0.id == "old" }?.source == .earlier, "a word saved before sources were kept claims nothing")
        #expect(try database.dictionaryTerms().first { $0.id == "meera" }?.spokenForms == "mee rah")

        try store.apply(DictionaryChangeSet(deletions: ["meera"]))
        #expect(try store.loadTerms().map(\.id) == ["ada", "old"])
        // A second store over the same database finds the side table already there.
        #expect(try DatabaseDictionaryTermStore(database: database).loadTerms().first { $0.id == "ada" }?.source == .contacts)
    }
}

// MARK: - The Dictionary pane

@Suite("S7d · Dictionary pane: states, add / edit, inline conflicts, failed saves")
@MainActor
struct DictionaryPaneS7dTests {
    @Test("loading until the store is connected, never the empty copy; then the design's empty state")
    func loadingThenEmpty() throws {
        let model = S7dFixture.model(terms: nil)
        #expect(model.dictionaryState.rendering == .loading)
        #expect(model.dictionaryState.headline == "Loading dictionary…")
        #expect(model.dictionaryState.detail == SectionCopy.loadingNote)
        #expect(model.dictionaryState.isWellFormed)

        model.connect(database: try AppDatabase.inMemory())
        #expect(model.dictionaryState.rendering == .empty)
        #expect(model.dictionaryState.headline == "Make it sound like you")
        #expect(model.dictionaryState.detail == "Add a word VoicePlus keeps getting wrong.")
        #expect(model.dictionaryState.actionTitle == "Add a word")
        #expect(model.dictionaryState.isWellFormed)
    }

    @Test("no database, or an unreadable one, is an error with Try again — not an empty dictionary")
    func unreadable() {
        let noDatabase = S7dFixture.model(terms: nil)
        noDatabase.connect(database: nil)
        #expect(noDatabase.dictionaryState.rendering == .error)
        #expect(noDatabase.dictionaryState.headline == "The dictionary can’t be read")
        #expect(noDatabase.dictionaryState.actionTitle == "Try again")
        #expect(noDatabase.dictionaryState.isWellFormed)

        let store = ScriptedTermStore([S7dFixture.meera])
        store.failLoads = true
        let model = S7dFixture.model(terms: store)
        #expect(model.dictionaryState.rendering == .error)
        store.failLoads = false
        model.reloadTerms()
        #expect(model.dictionaryState.isContent)
        #expect(model.terms.map(\.spelling) == ["Meera"])
    }

    @Test("add a word: spelling, spoken form, language; the row shows all three and its source")
    func addWord() throws {
        let store = ScriptedTermStore()
        let model = S7dFixture.model(terms: store)
        model.beginAdd()
        #expect(model.editor?.title == "Add a word")
        model.updateDraft(DictionaryTermDraft(spelling: "  Kubernetes ", spokenForms: "koo ber net ease", language: .english))
        #expect(model.saveEditor())
        #expect(model.editor == nil)
        #expect(model.dictionaryState.isContent)
        let term = try #require(model.terms.first)
        #expect(term.spelling == "Kubernetes")
        #expect(term.detail == "koo ber net ease · English · Added by you")
    }

    @Test("an empty spelling is refused in place; nothing is written")
    func validationInline() {
        let store = ScriptedTermStore()
        let model = S7dFixture.model(terms: store)
        model.beginAdd()
        #expect(!model.saveEditor())
        #expect(model.editor?.validation == "Enter a spelling first.")
        #expect(store.applied.isEmpty)
    }

    @Test("a duplicate is resolved inline: the form stays open until the user picks Update")
    func duplicateInline() throws {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        model.beginAdd(spelling: "meera")
        #expect(!model.saveEditor())
        let editor = try #require(model.editor)
        #expect(editor.conflict == .duplicate(S7dFixture.meera))
        #expect(store.applied.isEmpty, "a conflict writes nothing until it is resolved")

        model.keepEditing()
        #expect(model.editor?.conflict == nil)
        #expect(model.editor?.draft.spelling == "meera", "Keep editing leaves the entry as typed")

        #expect(!model.saveEditor())
        #expect(model.resolveConflict())
        #expect(model.editor == nil)
        #expect(model.terms.count == 1)
        #expect(model.terms.first?.spelling == "meera")
        #expect(model.terms.first?.spokenForms == ["mee rah"])
    }

    @Test("typing again clears a stale conflict")
    func typingClearsConflict() {
        let model = S7dFixture.model(terms: ScriptedTermStore([S7dFixture.meera]))
        model.beginAdd(spelling: "Meera")
        _ = model.saveEditor()
        #expect(model.editor?.conflict != nil)
        model.updateDraft(DictionaryTermDraft(spelling: "Meeraa"))
        #expect(model.editor?.conflict == nil)
        #expect(model.saveEditor())
        #expect(model.terms.map(\.spelling) == ["Meera", "Meeraa"])
    }

    @Test("a failed save keeps the entry and the previous word active, says S02 inline, and Try again saves it")
    func failedSaveKeepsBoth() throws {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        model.beginEdit(S7dFixture.meera)
        #expect(model.editor?.title == "Edit spelling")
        var draft = try #require(model.editor?.draft)
        draft.spelling = "Mira"
        model.updateDraft(draft)
        store.failSaves = true

        #expect(!model.saveEditor())
        let editor = try #require(model.editor, "the form stays open")
        #expect(editor.draft.spelling == "Mira", "the entered value is kept")
        #expect(editor.failure == .S02)
        let banner = try #require(editor.failureBanner)
        #expect(banner.headline == "Changes weren’t saved")
        #expect(banner.body == "Your previous setting is still active.")
        #expect(banner.actionTitle == "Try again")
        #expect(model.terms.map(\.spelling) == ["Meera"], "the previous word is still the active one")

        store.failSaves = false
        #expect(model.saveEditor())
        #expect(model.editor == nil)
        #expect(model.terms.map(\.spelling) == ["Mira"])
        #expect(model.terms.first?.id == "meera", "an edit keeps the word's identity")
    }

    @Test("delete from the form; a failed delete keeps the word")
    func deleteWord() {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        model.beginEdit(S7dFixture.meera)
        store.failSaves = true
        #expect(!model.deleteEditedTerm())
        #expect(model.terms.count == 1)
        #expect(model.editor?.failure == .S02)
        store.failSaves = false
        #expect(model.deleteEditedTerm())
        #expect(model.terms.isEmpty)
        #expect(model.dictionaryState.rendering == .empty)
    }

    @Test("search matches spellings and spoken variants; no match says so with Clear search")
    func search() {
        let model = S7dFixture.model(terms: ScriptedTermStore([S7dFixture.meera, DictionaryTerm(spelling: "Kubernetes")]))
        #expect(model.filteredTerms("RAH").map(\.spelling) == ["Meera"])
        #expect(model.filteredTerms("kube").map(\.spelling) == ["Kubernetes"])
        #expect(model.filteredTerms("").count == 2)
        #expect(!model.searchFindsNothing("kube"))
        #expect(model.searchFindsNothing("zzz"))
        #expect(!model.searchFindsNothing("  "))
        #expect(DictionaryAppsCopy.noMatches("zzz") == "No matches for “zzz”")
    }
}

// MARK: - Import

@Suite("S7d · import: parse, preview, commit (file and Contacts)")
@MainActor
struct DictionaryImportS7dTests {
    @Test("a word list: one per line, spoken form after a tab or the first comma, header and comments skipped")
    func parse() {
        let text = "term,spoken\n# my words\nMeera, mee rah\n\n\"Kubernetes\"\tkoo ber net ease\tkube\nGRDB\n"
        let entries = DictionaryImportParser.parse(text)
        #expect(entries == [
            DictionaryImportEntry(line: 3, spelling: "Meera", spokenForms: "mee rah"),
            DictionaryImportEntry(line: 5, spelling: "Kubernetes", spokenForms: "koo ber net ease,kube"),
            DictionaryImportEntry(line: 6, spelling: "GRDB"),
        ])
    }

    @Test("the preview marks new, already saved, listed twice, conflicting and rejected rows")
    func previewStatuses() throws {
        let entries = [DictionaryImportEntry(line: 1, spelling: "Ada"),
                       DictionaryImportEntry(line: 2, spelling: "meera"),
                       DictionaryImportEntry(line: 3, spelling: "Ada"),
                       DictionaryImportEntry(line: 4, spelling: "Mira", spokenForms: "mee rah"),
                       DictionaryImportEntry(line: 5, spelling: "42"),
                       DictionaryImportEntry(line: 6, spelling: "this is far too long to be one word")]
        let preview = DictionaryImportPreview.build(origin: .file("words.txt"), entries: entries, existing: [S7dFixture.meera])
        let statuses = preview.candidates.map(\.status)
        #expect(statuses[0] == .new)
        #expect(statuses[1] == .duplicate("Already in your dictionary"))
        #expect(statuses[2] == .duplicate("Listed twice"))
        #expect(statuses[3] == .conflict(.spokenForm("mee rah", owner: S7dFixture.meera)))
        #expect(statuses[4] == .rejected(DictionaryRules.notAWord))
        #expect(statuses[5] == .rejected(DictionaryRules.notASpelling))
        #expect(preview.candidates[4].detail == "Line 5 · A spelling needs at least one letter.")
        #expect(preview.candidates[3].detail == "“mee rah” already spells “Meera”. Select to use it for “Mira”.")
        #expect(preview.selected.map(\.spelling) == ["Ada"], "only new rows start selected; a conflict waits for a choice")
        #expect(preview.summary == "1 new · 1 to resolve · 2 already in your dictionary · 2 can’t be imported")
        #expect(preview.commitTitle == "Add 1 word")
        #expect(!preview.hasNothingValid)
    }

    @Test("committing writes only the selected rows, in one change; a chosen conflict moves the variant")
    func commitFile() throws {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        model.beginFileImport(text: "Ada\nMira, mee rah\nGrace\n", fileName: "names.txt")
        var session = try #require(model.importSession)
        #expect(session.step == .preview)
        #expect(session.failure == nil)
        let mira = try #require(session.preview.candidates.first { $0.spelling == "Mira" })
        model.toggleImportCandidate(mira.id)
        let grace = try #require(session.preview.candidates.first { $0.spelling == "Grace" })
        model.toggleImportCandidate(grace.id)
        session = try #require(model.importSession)
        #expect(session.preview.commitTitle == "Add 2 words")
        #expect(store.applied.isEmpty, "nothing is written by the preview")

        #expect(model.commitImport())
        #expect(model.importSession == nil)
        #expect(store.applied.count == 1, "one atomic change")
        #expect(model.terms.map(\.spelling) == ["Ada", "Meera", "Mira"])
        #expect(model.terms.first { $0.spelling == "Mira" }?.spokenForms == ["mee rah"])
        #expect(model.terms.first { $0.spelling == "Meera" }?.spokenForms == [])
        #expect(model.terms.first { $0.spelling == "Ada" }?.source == .imported)
        #expect(model.notice == "Added 2 words.")
    }

    @Test("a list with nothing usable is X04; a failed commit keeps the preview and changes nothing (S02)")
    func importFailures() throws {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        model.beginFileImport(text: "123\n456\n", fileName: "numbers.csv")
        #expect(model.importSession?.failure == .X04)
        #expect(model.importSession?.failureBanner?.headline == "Couldn’t import these words")
        #expect(model.importSession?.failureBanner?.body == "Existing dictionary entries are unchanged.")
        #expect(model.importSession?.canCommit == false)

        model.beginFileImport(text: "Ada\n", fileName: "one.txt")
        store.failSaves = true
        #expect(!model.commitImport())
        #expect(model.importSession?.failure == .S02)
        #expect(model.importSession?.preview.selected.map(\.spelling) == ["Ada"], "the preview is kept")
        #expect(model.terms.map(\.spelling) == ["Meera"])
        #expect(model.notice == nil, "success is announced only after it happened")
    }

    @Test("Contacts: the explanation comes first and asks nothing; then a preview; then an explicit commit")
    func contactsFlow() async throws {
        let store = ScriptedTermStore([DictionaryTerm(id: "ada", spelling: "Ada")])
        let model = S7dFixture.model(terms: store)
        let contacts = MockContactsStore(names: ["Ada Lovelace", "Linus Torvalds"])
        let settings = InMemorySettingsStore()
        let offer = ContactsImportOffer(store: contacts, database: nil, settings: settings)

        model.beginContactsImport()
        #expect(model.importSession?.step == .explainContacts)
        #expect(model.importSession?.title == "Import names from Contacts")
        #expect(contacts.authorization == .notDetermined, "the explanation is shown before the system prompt")

        await model.continueContactsImport(offer: offer)
        let session = try #require(model.importSession)
        #expect(session.step == .preview)
        #expect(contacts.authorization == .granted)
        #expect(offer.alreadyOffered, "onboarding will not offer it again")
        #expect(session.preview.candidates.map(\.spelling) == ["Ada", "Ada Lovelace", "Linus", "Linus Torvalds", "Lovelace", "Torvalds"])
        #expect(session.preview.candidates.first?.status == .duplicate("Already in your dictionary"))
        #expect(store.applied.isEmpty, "nothing is added before the commit")

        model.setAllImportCandidates(false)
        #expect(model.importSession?.canCommit == false)
        model.setAllImportCandidates(true)
        #expect(model.commitImport())
        #expect(model.terms.count == 6)
        #expect(model.terms.filter { $0.source == .contacts }.count == 5)
        #expect(model.notice == "Added 5 names from Contacts.")
    }

    @Test("Contacts denied: the flow closes, the banner opens System Settings, the dictionary is unchanged")
    func contactsDenied() async {
        let store = ScriptedTermStore([S7dFixture.meera])
        let model = S7dFixture.model(terms: store)
        let contacts = MockContactsStore(names: ["X Y"])
        contacts.grantOnRequest = false
        model.beginContactsImport()
        await model.continueContactsImport(offer: ContactsImportOffer(store: contacts, database: nil, settings: InMemorySettingsStore()))
        #expect(model.importSession == nil)
        #expect(model.banner?.headline == SectionCopy.contactsDenied)
        #expect(model.banner?.actionTitle == SectionCopy.openSystemSettings)
        #expect(model.bannerAction == .openContactsSettings)
        #expect(model.terms == [S7dFixture.meera])
        #expect(store.applied.isEmpty)
    }

    @Test("onboarding's one-step accept still imports, now recorded as From Contacts")
    func onboardingAcceptRecordsSource() async throws {
        let database = try AppDatabase.inMemory()
        let offer = ContactsImportOffer(store: MockContactsStore(names: ["Grace Hopper"]), database: database,
                                        settings: InMemorySettingsStore())
        #expect(await offer.accept() == .imported(3))
        let terms = try DatabaseDictionaryTermStore(database: database).loadTerms()
        #expect(terms.map(\.spelling) == ["Grace", "Grace Hopper", "Hopper"])
        #expect(terms.allSatisfy { $0.source == .contacts })
    }

    @Test("the Contacts candidates: full names and parts, each once, alphabetical")
    func contactsCandidates() {
        #expect(ContactsImportMapper.candidates(names: ["Ada Lovelace", "ada lovelace", "A", "123"])
                == ["Ada", "Ada Lovelace", "Lovelace"])
    }
}

// MARK: - The Apps pane

@Suite("S7d · Apps pane: defaults vs overrides, typing, contextual reading, word marks, verbatim")
@MainActor
struct AppsPaneS7dTests {
    @Test("no app rules: the design's empty state, with the defaults still shown above it")
    func empty() {
        let model = S7dFixture.model()
        #expect(model.appsState.rendering == .empty)
        #expect(model.appsState.headline == "Every app uses your defaults")
        #expect(model.appsState.actionTitle == "Add an app")
        #expect(model.appsState.isWellFormed)
        #expect(model.defaultsDraft.entered == AppRuleDefaults.standard)
    }

    @Test("an added app uses the defaults, and says so distinctly from an override")
    func usesDefaultVersusOverride() throws {
        let model = S7dFixture.model()
        model.addApp(AppIdentity(bundleID: "com.apple.mail", name: "Mail"))
        #expect(model.appsState.isContent)
        var row = try #require(model.apps.first)
        #expect(row.name == "Mail")
        #expect(row.usesDefaults)
        #expect(row.summary == "Uses default")
        #expect(row.rule.style == Inherited(.natural, usesDefault: true))

        model.setStyle(.verbatim, for: "com.apple.mail")
        row = try #require(model.apps.first)
        #expect(!row.usesDefaults)
        #expect(row.rule.style == Inherited(.verbatim, usesDefault: false))
        #expect(row.summary == "Verbatim")

        model.setStyle(nil, for: "com.apple.mail")
        #expect(model.apps.first?.summary == "Uses default")
    }

    @Test("a changed default reaches every app that inherits it, and no app that overrides it")
    func defaultsInherit() throws {
        let model = S7dFixture.model()
        model.addApp(AppIdentity(bundleID: "com.apple.mail", name: "Mail"))
        model.addApp(AppIdentity(bundleID: "com.apple.Notes", name: "Notes"))
        model.setContextualReading(true, for: "com.apple.Notes")
        model.setDefaultContextualReading(false)
        model.setDefaultStyle(.verbatim)
        let mail = try #require(model.apps.first { $0.bundleID == "com.apple.mail" })
        let notes = try #require(model.apps.first { $0.bundleID == "com.apple.Notes" })
        #expect(mail.rule.contextualReading == Inherited(false, usesDefault: true))
        #expect(mail.rule.style == Inherited(.verbatim, usesDefault: true))
        #expect(notes.rule.contextualReading == Inherited(true, usesDefault: false))
        #expect(notes.summary == "Contextual reading on")
    }

    @Test("insertion eligibility is the never-inject list Injection reads; its consequence is stated")
    func neverInject() throws {
        let defaults = S7dFixture.defaults()
        let model = S7dFixture.model(rules: UserDefaultsAppRuleStore(defaults: defaults))
        model.setNeverInject(true, bundleID: "com.apple.keychainaccess")
        #expect(model.isNeverInject("com.apple.keychainaccess"))
        #expect(UserDefaultsInjectionPolicy(defaults: defaults).neverInjectBundleIDs == ["com.apple.keychainaccess"])
        let row = try #require(model.apps.first)
        #expect(row.neverInject)
        #expect(row.summary == "Never typed here")
        #expect(DictionaryAppsSectionViewModel.neverInjectConsequence == "Dictation is held here, never typed")

        model.setNeverInject(false, bundleID: "com.apple.keychainaccess")
        #expect(UserDefaultsInjectionPolicy(defaults: defaults).neverInjectBundleIDs.isEmpty)
    }

    @Test("rules persist: a second store over the same defaults reads the same book")
    func persistence() throws {
        let defaults = S7dFixture.defaults()
        defaults.set("com.agilebits.onepassword7", forKey: InjectionSettingsKeys.neverInject)
        let model = S7dFixture.model(rules: UserDefaultsAppRuleStore(defaults: defaults))
        #expect(model.isNeverInject("com.agilebits.onepassword7"), "a never-inject list from before S7d is kept")
        model.addApp(AppIdentity(bundleID: "com.apple.mail", name: "Mail"))
        model.setStyle(.verbatim, for: "com.apple.mail")
        model.setContextualReading(false, for: "com.apple.mail")
        model.setDefaultStyle(.verbatim)
        let book = try UserDefaultsAppRuleStore(defaults: defaults).load()
        #expect(book == model.book)
        #expect(book.rules["com.apple.mail"] == AppRule(bundleID: "com.apple.mail", name: "Mail", style: .verbatim,
                                                        contextualReading: false))
        #expect(book.neverInject == ["com.agilebits.onepassword7"])
        #expect(AppRules.current(defaults: defaults) == book)
    }

    @Test("code editors and terminals are verbatim whatever the rule says, and nothing presses Return")
    func codeAndTerminalVerbatim() throws {
        var book = AppRuleBook(defaults: AppRuleDefaults(style: .natural))
        book.rules["com.microsoft.VSCode"] = AppRule(bundleID: "com.microsoft.VSCode", style: .natural)
        let terminal = book.resolved(for: "com.apple.Terminal")
        #expect(terminal.profile == .terminal)
        #expect(terminal.style == Inherited(.verbatim, usesDefault: false))
        #expect(terminal.styleIsLocked)
        let code = book.resolved(for: "com.microsoft.VSCode")
        #expect(code.profile == .code)
        #expect(code.style.value == .verbatim, "an override cannot make a code editor 'natural'")
        for bundleID in ["com.apple.Terminal", "com.microsoft.VSCode", "com.apple.mail", "com.apple.Notes"] {
            #expect(book.resolved(for: bundleID).pressesReturn == false)
        }
        #expect(book.resolved(for: "com.apple.mail").styleIsLocked == false)

        let model = S7dFixture.model()
        model.addApp(AppIdentity(bundleID: "com.apple.Terminal", name: "Terminal"))
        let row = try #require(model.apps.first)
        #expect(row.summary == "Verbatim")
        #expect(DictionaryAppsCopy.codeProfileDetail == "Keep commands exactly as spoken. Never presses Return.")
    }

    @Test("the rule applied to a run: verbatim switches style and instructions off; no context read")
    func applyToRun() {
        var book = AppRuleBook()
        book.rules["com.apple.mail"] = AppRule(bundleID: "com.apple.mail", style: .verbatim, contextualReading: false)
        var context = StageContext()
        context.extra[PersonaManager.promptKey] = "Casual"
        context.extra[DeixisService.windowTextKey] = "Dear Mira"
        context.extra[DeixisService.contextLineKey] = "box 1: Mira"
        context.extra["other"] = "kept"
        let applied = book.resolved(for: "com.apple.mail").apply(to: context)
        #expect(applied.extra[StyleStage.enabledKey] == "false")
        #expect(applied.extra[PersonaManager.promptKey] == nil)
        #expect(applied.extra[DeixisService.windowTextKey] == nil)
        #expect(applied.extra[DeixisService.contextLineKey] == nil)
        #expect(applied.extra["other"] == "kept")

        let untouched = AppRuleBook().resolved(for: "com.apple.mail").apply(to: context)
        #expect(untouched.extra == context.extra, "the defaults change nothing in a run")
    }

    @Test("word marks: 'No overlay' until S5 records the app as validated")
    func wordMarks() throws {
        let model = S7dFixture.model(marks: ["com.apple.Notes"])
        model.addApp(AppIdentity(bundleID: "com.apple.Notes", name: "Notes"))
        model.addApp(AppIdentity(bundleID: "com.google.docs", name: "Docs"))
        #expect(model.apps.first { $0.name == "Notes" }?.wordMarks == .supported)
        let docs = try #require(model.apps.first { $0.name == "Docs" })
        #expect(docs.wordMarks.tag == "No overlay")
        #expect(docs.wordMarks.detail == "Text can be inserted; word marks stay in Review.")

        let defaults = S7dFixture.defaults()
        let recorded = RecordedWordMarkCapability(defaults: defaults)
        #expect(recorded.wordMarks(for: "com.apple.TextEdit") == .unavailable, "never promised before validation")
        RecordedWordMarkCapability.record("com.apple.TextEdit", supported: true, defaults: defaults)
        #expect(recorded.wordMarks(for: "com.apple.TextEdit") == .supported)
        #expect(WordMarkSupport.supported.tag == "Word marks")
    }

    @Test("a failed rule save keeps the entered value, marks it unsaved, keeps the previous rule active (S02)")
    func failedRuleSave() throws {
        let store = ScriptedRuleStore()
        let model = S7dFixture.model(rules: store)
        model.addApp(AppIdentity(bundleID: "com.apple.mail", name: "Mail"))
        store.failSaves = true
        model.setStyle(.verbatim, for: "com.apple.mail")

        let row = try #require(model.apps.first)
        #expect(row.rule.style.value == .verbatim, "the control shows what was entered")
        #expect(row.isUnsaved)
        #expect(row.failure?.headline == "Changes weren’t saved")
        #expect(row.failure?.body == "Your previous setting is still active.")
        #expect(row.failure?.actionTitle == "Try again")
        #expect(model.book.rules["com.apple.mail"]?.style == nil, "the previous rule is still the active one")
        #expect(store.book.rules["com.apple.mail"]?.style == nil, "no silent policy change")

        store.failSaves = false
        model.retryRule("com.apple.mail")
        #expect(model.apps.first?.isUnsaved == false)
        #expect(model.apps.first?.failure == nil)
        #expect(model.book.rules["com.apple.mail"]?.style == .verbatim)
    }

    @Test("a failed never-inject save leaves Injection's list as it was")
    func failedNeverInjectSave() {
        let store = ScriptedRuleStore()
        let model = S7dFixture.model(rules: store)
        store.failSaves = true
        model.setNeverInject(true, bundleID: "com.apple.mail")
        #expect(!model.isNeverInject("com.apple.mail"))
        #expect(store.book.neverInject.isEmpty)
        #expect(model.apps.first?.neverInject == true, "the switch shows the entered value, marked unsaved")
        #expect(model.apps.first?.isUnsaved == true)
    }

    @Test("a failed defaults save keeps the entered default and the active one apart")
    func failedDefaultsSave() {
        let store = ScriptedRuleStore()
        let model = S7dFixture.model(rules: store)
        store.failSaves = true
        model.setDefaultStyle(.verbatim)
        #expect(model.defaultsDraft.entered.style == .verbatim)
        #expect(model.defaultsDraft.active.style == .natural)
        #expect(model.defaultsDraft.failure == .S02)
        #expect(model.book.defaults.style == .natural)
        store.failSaves = false
        model.retryDefaults()
        #expect(model.defaultsDraft.failure == nil)
        #expect(model.book.defaults.style == .verbatim)
    }

    @Test("unreadable rules: an error with Try again; never-inject still holds; consumers fall back to defaults")
    func unreadableRules() {
        let defaults = S7dFixture.defaults()
        defaults.set("{not json", forKey: UserDefaultsAppRuleStore.rulesKey)
        defaults.set("com.apple.keychainaccess", forKey: InjectionSettingsKeys.neverInject)
        let model = S7dFixture.model(rules: UserDefaultsAppRuleStore(defaults: defaults))
        #expect(model.appsState.rendering == .error)
        #expect(model.appsState.headline == "App rules can’t be read")
        #expect(model.appsState.actionTitle == "Try again")
        #expect(model.appsState.isWellFormed)
        #expect(UserDefaultsInjectionPolicy(defaults: defaults).neverInjectBundleIDs == ["com.apple.keychainaccess"])
        #expect(AppRules.current(defaults: defaults) == AppRuleBook())
        #expect(defaults.string(forKey: UserDefaultsAppRuleStore.rulesKey) == "{not json", "nothing was cleared")
    }

    @Test("removing an app returns it to the defaults; search filters apps by name or bundle ID")
    func removeAndSearch() {
        let model = S7dFixture.model()
        model.addApp(bundleID: "com.apple.mail")
        model.addApp(bundleID: "com.apple.Notes")
        #expect(model.apps.map(\.name) == ["Mail", "Notes"])
        #expect(model.filteredApps("note").map(\.name) == ["Notes"])
        #expect(model.filteredApps("com.apple.mail").map(\.name) == ["Mail"])
        #expect(model.runningApps().isEmpty, "apps that already have a rule are not offered again")
        model.setNeverInject(true, bundleID: "com.apple.mail")
        model.removeApp("com.apple.mail")
        #expect(model.apps.map(\.name) == ["Notes"])
        #expect(!model.isNeverInject("com.apple.mail"))
    }

    @Test("writing instructions live on the app's row; a save that does not stick is reported with the text kept")
    func writingInstructions() throws {
        let database = try AppDatabase.inMemory()
        let model = S7dFixture.model(personas: PersonasViewModel(database: database))
        model.addApp(bundleID: "com.apple.mail")
        #expect(model.saveInstructions("Casual, short, no sign-off.", for: "com.apple.mail"))
        let row = try #require(model.apps.first)
        #expect(row.persona == "Casual, short, no sign-off.")
        #expect(row.summary == "Writing instructions")
        #expect(!row.usesDefaults)

        let offline = S7dFixture.model(personas: PersonasViewModel(database: nil))
        offline.addApp(bundleID: "com.apple.mail")
        #expect(!offline.saveInstructions("Formal.", for: "com.apple.mail"))
        #expect(offline.personaFailures["com.apple.mail"] == "Formal.")
        #expect(offline.instructionsFailure(for: "com.apple.mail")?.headline == "Changes weren’t saved")
    }
}

// MARK: - Snippets copy

@Suite("S7d · snippets as rows: failed saves say what to do, never a raw error")
@MainActor
struct SnippetsRowsS7dTests {
    @Test("validation errors read as sentences")
    func snippetErrors() {
        #expect(SnippetsViewModel.describe(SnippetError.emptyTrigger) == "Add a trigger phrase first.")
        #expect(SnippetsViewModel.describe(SnippetError.duplicateTrigger("my address"))
                == "“my address” is already a trigger — choose another phrase.")
        let vm = SnippetsViewModel(store: InMemorySnippetStore())
        #expect(!vm.save(trigger: "", body: "x"))
        #expect(vm.lastError?.contains("emptyTrigger") == false)
    }

    @Test("an unreadable store is a scoped Try again that keeps the rows shown — never 'no snippets'")
    func unreadableSnippets() {
        let store = FlakySnippetStore([Snippet(id: "a", trigger: "my address", body: "1 Main St")])
        store.failReads = true
        let vm = SnippetsViewModel(store: store)
        #expect(vm.loadFailed && vm.snippets.isEmpty)
        #expect(vm.loadFailureBanner?.headline == "Snippets can’t be read")
        #expect(vm.loadFailureBanner?.actionTitle == "Try again")
        store.failReads = false
        vm.reload()
        #expect(!vm.loadFailed && vm.loadFailureBanner == nil && vm.snippets.map(\.trigger) == ["my address"])
        store.failReads = true
        vm.reload()
        #expect(vm.loadFailed && vm.snippets.map(\.trigger) == ["my address"])
    }

    @Test("a failed delete keeps the row and says so; a snippet already gone is simply removed")
    func failedSnippetDelete() {
        let store = FlakySnippetStore([Snippet(id: "a", trigger: "my address", body: "1 Main St"),
                                       Snippet(id: "b", trigger: "sig", body: "Best, A")])
        let vm = SnippetsViewModel(store: store)
        store.failDeletes = true
        #expect(!vm.delete(id: "a"))
        #expect(vm.snippets.count == 2)
        #expect(vm.lastError == "“my address” wasn’t deleted — Try again")
        store.failDeletes = false
        #expect(vm.delete(id: "a"))
        #expect(vm.lastError == nil && vm.snippets.map(\.id) == ["b"])
        _ = try? store.delete(id: "b") // removed elsewhere meanwhile
        #expect(vm.delete(id: "b"))
        #expect(vm.snippets.isEmpty && vm.lastError == nil)
    }
}

/// A snippet store whose reads or deletes can be made to fail.
final class FlakySnippetStore: SnippetStoring, @unchecked Sendable {
    struct Failure: Error {}
    private let inner: InMemorySnippetStore
    var failReads = false
    var failDeletes = false

    init(_ seed: [Snippet]) { inner = InMemorySnippetStore(seed) }

    func all() throws -> [Snippet] {
        if failReads { throw Failure() }
        return try inner.all()
    }

    func save(_ snippet: Snippet) throws { try inner.save(snippet) }

    func delete(id: String) throws {
        if failDeletes { throw Failure() }
        try inner.delete(id: id)
    }
}
