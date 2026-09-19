import Engine
import Foundation
import GRDB
import Shared

// S7d — the Dictionary half of Dictionary & Apps (design §8.3): what one word is (spelling, spoken
// variants, language, source), how a new or edited word is checked against the rest (duplicates and
// spoken-form conflicts, resolved inline), and the one store every change goes through — atomically,
// so a failed save leaves the previous words exactly as they were (design §9: "Unsaved input retained;
// prior persisted value stays active").
//
// Words live in the app database's existing `dictionary` table (biasing, sync and Contacts import
// read it there). Language and source are not columns of `DictionaryRecord` (Shared is closed), so
// they sit in a small additive side table, created here the way `TurnStore` creates its own.

// MARK: - One word

/// The language a word is spoken in. Only what the recogniser can tell apart (`SpokenLanguage`).
public enum DictionaryTermLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case any, english, hindi

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: return "Any language"
        case .english: return "English"
        case .hindi: return "Hindi"
        }
    }

    /// The engine's language, for a consumer that biases per language. `nil` for any.
    public var spokenLanguage: SpokenLanguage? {
        switch self {
        case .any: return nil
        case .english: return .english
        case .hindi: return .hindi
        }
    }
}

/// Where a word came from, said plainly in its row.
public enum DictionaryTermSource: String, CaseIterable, Codable, Sendable {
    /// Typed in the Dictionary.
    case personal
    /// Chosen in a Contacts import preview.
    case contacts
    /// Chosen in a file import preview.
    case imported
    /// Saved before sources were recorded (or by a paired Mac): nothing is claimed about how.
    case earlier

    public var label: String {
        switch self {
        case .personal: return "Added by you"
        case .contacts: return "From Contacts"
        case .imported: return "Imported"
        case .earlier: return "Saved earlier"
        }
    }
}

/// One word in the Dictionary.
public struct DictionaryTerm: Identifiable, Equatable, Sendable {
    public var id: String
    public var spelling: String
    /// How it is said, when that differs from how it is spelled ("mee rah").
    public var spokenForms: [String]
    public var language: DictionaryTermLanguage
    public var source: DictionaryTermSource
    public var weight: Double
    public var createdAt: Date

    public init(id: String = UUID().uuidString, spelling: String, spokenForms: [String] = [],
                language: DictionaryTermLanguage = .any, source: DictionaryTermSource = .personal,
                weight: Double = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.spelling = spelling
        self.spokenForms = spokenForms
        self.language = language
        self.source = source
        self.weight = weight
        self.createdAt = createdAt
    }

    /// The stored record's `spokenForms` is one comma-separated string (the form sync and the R7
    /// editor already write).
    public init(record: DictionaryRecord, language: DictionaryTermLanguage = .any, source: DictionaryTermSource = .earlier) {
        self.init(id: record.id, spelling: record.term, spokenForms: DictionaryRules.spokenForms(record.spokenForms),
                  language: language, source: source, weight: record.weight, createdAt: record.createdAt)
    }

    public var record: DictionaryRecord {
        DictionaryRecord(id: id, term: spelling, spokenForms: spokenForms.joined(separator: ", "),
                         weight: weight, createdAt: createdAt)
    }

    /// The row's second line (prototype `row('Meera', 'mee rah · Name')`): spoken variant, language,
    /// source — each only when there is something to say.
    public var detail: String {
        var parts: [String] = []
        if !spokenForms.isEmpty { parts.append(spokenForms.joined(separator: ", ")) }
        if language != .any { parts.append(language.title) }
        parts.append(source.label)
        return parts.joined(separator: " · ")
    }

    func matches(_ query: String) -> Bool {
        spelling.localizedCaseInsensitiveContains(query)
            || spokenForms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Rules: validation, duplicates, conflicts

/// What the user typed in the add / edit form, kept exactly as typed until a save succeeds.
public struct DictionaryTermDraft: Equatable, Sendable {
    /// The word being edited; `nil` for a new word.
    public var editingID: String?
    public var spelling: String
    /// As typed: comma-separated spoken variants.
    public var spokenForms: String
    public var language: DictionaryTermLanguage

    public init(editingID: String? = nil, spelling: String = "", spokenForms: String = "",
                language: DictionaryTermLanguage = .any) {
        self.editingID = editingID
        self.spelling = spelling
        self.spokenForms = spokenForms
        self.language = language
    }

    public init(editing term: DictionaryTerm) {
        self.init(editingID: term.id, spelling: term.spelling, spokenForms: term.spokenForms.joined(separator: ", "),
                  language: term.language)
    }

    public var isNew: Bool { editingID == nil }
    public var trimmedSpelling: String { DictionaryRules.collapse(spelling) }
    public var spokenFormList: [String] { DictionaryRules.spokenForms(spokenForms) }
}

/// A new or edited word that collides with one already saved. Shown inline in the form with one way
/// to resolve it; "Keep editing" leaves everything as it is (design §8.3).
public enum DictionaryConflict: Equatable, Sendable {
    /// The spelling is already in the dictionary (ignoring case).
    case duplicate(DictionaryTerm)
    /// A spoken variant already spells another word, or *is* another word.
    case spokenForm(String, owner: DictionaryTerm)

    public var existing: DictionaryTerm {
        switch self {
        case .duplicate(let term), .spokenForm(_, let term): return term
        }
    }

    /// The inline sentence.
    public var message: String {
        switch self {
        case .duplicate(let term):
            return "“\(term.spelling)” is already in your dictionary."
        case let .spokenForm(form, owner) where DictionaryRules.key(form) == DictionaryRules.key(owner.spelling):
            return "“\(form)” is how “\(owner.spelling)” is spelled."
        case let .spokenForm(form, owner):
            return "“\(form)” already spells “\(owner.spelling)”."
        }
    }

    /// The one resolving action for `draft`, or `nil` when the only way on is to change the entry
    /// (a spoken variant that is another word's own spelling cannot be taken from it).
    public func resolveTitle(for draft: DictionaryTermDraft) -> String? {
        switch self {
        case .duplicate(let term):
            return draft.isNew ? "Update “\(term.spelling)”" : "Merge into “\(term.spelling)”"
        case let .spokenForm(form, owner):
            guard DictionaryRules.key(form) != DictionaryRules.key(owner.spelling) else { return nil }
            return "Use it for “\(draft.trimmedSpelling)”"
        }
    }
}

/// The dictionary's rules, pure: normalising, validating, and finding what an entry collides with.
public enum DictionaryRules {
    public static let emptySpelling = "Enter a spelling first."
    public static let notASpelling = "A spelling, not a sentence — up to four words."
    public static let notAWord = "A spelling needs at least one letter."

    /// Single spaces, no edges.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Comma-, semicolon- or newline-separated spoken variants, trimmed, empty ones dropped, each once.
    public static func spokenForms(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { collapse(String($0)) }
            .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
    }

    /// How two spellings or spoken forms are compared: case, accents and spacing ignored.
    public static func key(_ text: String) -> String {
        collapse(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Why `spelling` cannot be saved, or `nil`. Uses the lexicon's own "a spelling, never a
    /// paragraph" rule (`LexiconSanity`), so a typed word and a trained word obey the same limit.
    public static func validate(spelling: String) -> String? {
        let text = collapse(spelling)
        guard !text.isEmpty else { return emptySpelling }
        guard text.rangeOfCharacter(from: .letters) != nil else { return notAWord }
        guard LexiconSanity.isPlausibleCorrection(heard: "", corrected: text), text.count <= 64 else { return notASpelling }
        return nil
    }

    /// The first collision of `draft` with `terms` (the word being edited excluded), or `nil`.
    public static func conflict(for draft: DictionaryTermDraft, in terms: [DictionaryTerm]) -> DictionaryConflict? {
        let spelling = key(draft.spelling)
        let others = terms.filter { $0.id != draft.editingID }
        if let duplicate = others.first(where: { key($0.spelling) == spelling }) {
            return .duplicate(duplicate)
        }
        for form in draft.spokenFormList {
            let formKey = key(form)
            guard formKey != spelling else { continue }
            if let owner = others.first(where: { key($0.spelling) == formKey || $0.spokenForms.contains { key($0) == formKey } }) {
                return .spokenForm(form, owner: owner)
            }
        }
        return nil
    }

    /// The changes that save `draft`, applying `resolution` when the user chose to resolve a
    /// conflict. `nil` when the conflict cannot be resolved by an action (see `resolveTitle`).
    public static func changes(saving draft: DictionaryTermDraft, over terms: [DictionaryTerm],
                               resolving resolution: DictionaryConflict?) -> DictionaryChangeSet? {
        let editing = draft.editingID.flatMap { id in terms.first { $0.id == id } }
        var term = editing ?? DictionaryTerm(spelling: draft.trimmedSpelling, source: .personal)
        term.spelling = draft.trimmedSpelling
        term.spokenForms = draft.spokenFormList
        term.language = draft.language

        switch resolution {
        case nil:
            return DictionaryChangeSet(upserts: [term])
        case .duplicate(let existing):
            // One word, not two: the saved one takes the typed spelling and every spoken variant.
            var merged = existing
            merged.spelling = draft.trimmedSpelling
            merged.spokenForms = union(existing.spokenForms, draft.spokenFormList)
            if draft.language != .any { merged.language = draft.language }
            return DictionaryChangeSet(upserts: [merged], deletions: editing.map { [$0.id] } ?? [])
        case let .spokenForm(form, owner):
            guard key(form) != key(owner.spelling) else { return nil }
            var released = owner
            released.spokenForms.removeAll { key($0) == key(form) }
            return DictionaryChangeSet(upserts: [released, term])
        }
    }

    static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert(key($0)).inserted }
    }
}

// MARK: - The store

/// One atomic change to the dictionary: every upsert and deletion lands, or none does.
public struct DictionaryChangeSet: Equatable, Sendable {
    public var upserts: [DictionaryTerm]
    public var deletions: [String]

    public init(upserts: [DictionaryTerm] = [], deletions: [String] = []) {
        self.upserts = upserts
        self.deletions = deletions
    }

    public var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
}

/// Where the Dictionary reads and writes words.
public protocol DictionaryTermStoring: AnyObject {
    func loadTerms() throws -> [DictionaryTerm]
    /// All or nothing: a throw means nothing changed.
    func apply(_ changes: DictionaryChangeSet) throws
}

/// The app database: words in `dictionary`, their language and source in `dictionary_term_meta`.
public final class DatabaseDictionaryTermStore: DictionaryTermStoring {
    static let metaTable = "dictionary_term_meta"

    private let database: AppDatabase
    private var metaReady: Bool

    public init(database: AppDatabase) {
        self.database = database
        metaReady = Self.prepareMeta(database)
    }

    /// Additive and idempotent: no existing table is touched.
    private static func prepareMeta(_ database: AppDatabase) -> Bool {
        do {
            try database.writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS \(metaTable) (
                        termID TEXT PRIMARY KEY NOT NULL,
                        language TEXT NOT NULL,
                        source TEXT NOT NULL
                    )
                    """)
            }
            return true
        } catch {
            Log.db.error("dictionary: could not prepare \(metaTable): \(error)")
            return false
        }
    }

    public func loadTerms() throws -> [DictionaryTerm] {
        if !metaReady { metaReady = Self.prepareMeta(database) }
        let withMeta = metaReady
        return try database.reader.read { db in
            let records = try DictionaryRecord.fetchAll(db)
            var meta: [String: (DictionaryTermLanguage, DictionaryTermSource)] = [:]
            if withMeta {
                for row in try Row.fetchAll(db, sql: "SELECT termID, language, source FROM \(Self.metaTable)") {
                    let id: String = row["termID"]
                    meta[id] = (DictionaryTermLanguage(rawValue: row["language"]) ?? .any,
                                DictionaryTermSource(rawValue: row["source"]) ?? .earlier)
                }
            }
            return records.map { record in
                let (language, source) = meta[record.id] ?? (.any, .earlier)
                return DictionaryTerm(record: record, language: language, source: source)
            }
            .sorted(by: DictionaryTermStoreOrder.alphabetical)
        }
    }

    public func apply(_ changes: DictionaryChangeSet) throws {
        guard !changes.isEmpty else { return }
        if !metaReady { metaReady = Self.prepareMeta(database) }
        let withMeta = metaReady
        try database.writer.write { db in
            for id in changes.deletions {
                _ = try DictionaryRecord.deleteOne(db, key: id)
                if withMeta { try db.execute(sql: "DELETE FROM \(Self.metaTable) WHERE termID = ?", arguments: [id]) }
            }
            for term in changes.upserts {
                try term.record.save(db)
                if withMeta {
                    try db.execute(sql: "INSERT OR REPLACE INTO \(Self.metaTable) (termID, language, source) VALUES (?, ?, ?)",
                                   arguments: [term.id, term.language.rawValue, term.source.rawValue])
                }
            }
        }
    }
}

enum DictionaryTermStoreOrder {
    static func alphabetical(_ a: DictionaryTerm, _ b: DictionaryTerm) -> Bool {
        a.spelling.localizedStandardCompare(b.spelling) == .orderedAscending
    }
}

// MARK: - Import preview (file or Contacts)

/// One line of an import, and what would happen to it. Nothing is written until the user commits
/// the rows they kept selected (design §8.3 "import preview"; X04: "Preview valid entries and list
/// rejected rows").
public struct DictionaryImportCandidate: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Would be added. Selected by default.
        case new
        /// Already in the dictionary (or listed twice in the import). Never added.
        case duplicate(String)
        /// A spoken variant already spells another word. Added only if selected, which moves the
        /// variant to this word (the inline resolution). Not selected by default.
        case conflict(DictionaryConflict)
        /// Cannot be a dictionary word; the reason is shown.
        case rejected(String)
    }

    public var id: Int
    /// 1-based line in the imported file; `nil` for Contacts.
    public var line: Int?
    public var spelling: String
    public var spokenForms: [String]
    public var status: Status
    public var isSelected: Bool

    public var isSelectable: Bool {
        switch status {
        case .new, .conflict: return true
        case .duplicate, .rejected: return false
        }
    }

    /// The row's second line.
    public var detail: String {
        switch status {
        case .new: return spokenForms.isEmpty ? "New" : "New · \(spokenForms.joined(separator: ", "))"
        case .duplicate(let reason): return reason
        case .conflict(let conflict): return "\(conflict.message) Select to use it for “\(spelling)”."
        case .rejected(let reason): return line.map { "Line \($0) · \(reason)" } ?? reason
        }
    }
}

public struct DictionaryImportPreview: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case file(String)
        case contacts

        var source: DictionaryTermSource { self == .contacts ? .contacts : .imported }
    }

    public static let alreadyInDictionary = "Already in your dictionary"
    public static let listedTwice = "Listed twice"
    public static let emptyEntry = "Nothing to add on this line"

    public var origin: Origin
    public var candidates: [DictionaryImportCandidate]

    /// Builds the preview of `entries` against the words already saved.
    public static func build(origin: Origin, entries: [DictionaryImportEntry], existing: [DictionaryTerm]) -> DictionaryImportPreview {
        var seen = Set<String>()
        var candidates: [DictionaryImportCandidate] = []
        for (index, entry) in entries.enumerated() {
            let spelling = DictionaryRules.collapse(entry.spelling)
            let forms = DictionaryRules.spokenForms(entry.spokenForms)
            let status: DictionaryImportCandidate.Status
            if let reason = spelling.isEmpty ? emptyEntry : DictionaryRules.validate(spelling: spelling) {
                status = .rejected(reason)
            } else if !seen.insert(DictionaryRules.key(spelling)).inserted {
                status = .duplicate(listedTwice)
            } else if let conflict = DictionaryRules.conflict(for: DictionaryTermDraft(spelling: spelling, spokenForms: forms.joined(separator: ", ")),
                                                              in: existing) {
                switch conflict {
                case .duplicate:
                    status = .duplicate(alreadyInDictionary)
                case let .spokenForm(form, owner) where DictionaryRules.key(form) == DictionaryRules.key(owner.spelling):
                    status = .rejected(conflict.message) // another word's own spelling cannot be taken from it
                case .spokenForm:
                    status = .conflict(conflict)
                }
            } else {
                status = .new
            }
            candidates.append(DictionaryImportCandidate(id: index, line: entry.line, spelling: spelling, spokenForms: forms,
                                                        status: status, isSelected: status == .new))
        }
        return DictionaryImportPreview(origin: origin, candidates: candidates)
    }

    public var selected: [DictionaryImportCandidate] { candidates.filter { $0.isSelected && $0.isSelectable } }
    public var newCount: Int { candidates.filter { $0.status == .new }.count }
    public var duplicateCount: Int { candidates.filter { if case .duplicate = $0.status { return true } else { return false } }.count }
    public var conflictCount: Int { candidates.filter { if case .conflict = $0.status { return true } else { return false } }.count }
    public var rejectedCount: Int { candidates.filter { if case .rejected = $0.status { return true } else { return false } }.count }

    /// True when not one row could ever be added: the import is malformed (X04).
    public var hasNothingValid: Bool { !candidates.contains { $0.isSelectable } }

    public mutating func toggle(_ id: Int) {
        guard let i = candidates.firstIndex(where: { $0.id == id }), candidates[i].isSelectable else { return }
        candidates[i].isSelected.toggle()
    }

    public mutating func setAll(_ selected: Bool) {
        for i in candidates.indices where candidates[i].isSelectable { candidates[i].isSelected = selected }
    }

    /// The counts line under the preview title.
    public var summary: String {
        var parts = ["\(newCount) new"]
        if conflictCount > 0 { parts.append("\(conflictCount) to resolve") }
        if duplicateCount > 0 { parts.append("\(duplicateCount) already in your dictionary") }
        if rejectedCount > 0 { parts.append("\(rejectedCount) can’t be imported") }
        return parts.joined(separator: " · ")
    }

    /// The commit button: "Add 12 words".
    public var commitTitle: String {
        let n = selected.count
        return n == 1 ? "Add 1 word" : "Add \(n) words"
    }

    /// The selected rows as one change set; a selected conflict moves its spoken variant here.
    public func changes(over existing: [DictionaryTerm]) -> DictionaryChangeSet {
        var released: [String: DictionaryTerm] = [:]
        var upserts: [DictionaryTerm] = []
        for candidate in selected {
            if case let .conflict(.spokenForm(form, owner)) = candidate.status {
                var current = released[owner.id] ?? existing.first { $0.id == owner.id } ?? owner
                current.spokenForms.removeAll { DictionaryRules.key($0) == DictionaryRules.key(form) }
                released[owner.id] = current
            }
            upserts.append(DictionaryTerm(spelling: candidate.spelling, spokenForms: candidate.spokenForms,
                                          source: origin.source))
        }
        return DictionaryChangeSet(upserts: released.values.sorted(by: DictionaryTermStoreOrder.alphabetical) + upserts)
    }
}

/// One entry read from an import source.
public struct DictionaryImportEntry: Equatable, Sendable {
    public var line: Int?
    public var spelling: String
    public var spokenForms: String

    public init(line: Int? = nil, spelling: String, spokenForms: String = "") {
        self.line = line
        self.spelling = spelling
        self.spokenForms = spokenForms
    }
}

/// Reads a word list: one word per line, optionally followed by its spoken form after a tab or the
/// first comma ("Meera, mee rah"). Blank lines and `#` comments are skipped; a `term,spoken` header
/// line is skipped too.
public enum DictionaryImportParser {
    public static func parse(_ text: String) -> [DictionaryImportEntry] {
        var entries: [DictionaryImportEntry] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separator: Character? = line.contains("\t") ? "\t" : (line.contains(",") ? "," : nil)
            var spelling = line
            var spoken = ""
            if let separator, let cut = line.firstIndex(of: separator) {
                spelling = String(line[..<cut])
                spoken = String(line[line.index(after: cut)...]).replacingOccurrences(of: "\t", with: ",")
            }
            spelling = unquote(spelling)
            spoken = unquote(spoken)
            if entries.isEmpty, isHeader(spelling) { continue }
            entries.append(DictionaryImportEntry(line: index + 1, spelling: spelling, spokenForms: spoken))
        }
        return entries
    }

    static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }

    static func isHeader(_ first: String) -> Bool {
        ["term", "word", "spelling"].contains(first.lowercased())
    }
}
