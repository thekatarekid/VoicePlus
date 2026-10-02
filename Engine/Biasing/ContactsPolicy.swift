import Foundation
import GRDB
import Shared

// N1 — Contacts out of every biasing channel.
//
// Imported Contacts names ("Akash", "Bucket", "Cab", "Code", "Cleaning") were reaching the CTC boost
// list, the cleanup "spell exactly" list and the cleanup context as if the user had typed them, and
// rewrote ordinary words everywhere. Each Dictionary row now carries its real origin, and a
// Contacts-origin row is kept out of all three channels. N11 will re-admit them only on chat, email
// and name-field surfaces (at a reduced weight); until then they are excluded everywhere.

/// Where a Dictionary row came from. Mirrors the App's `DictionaryTermSource` raw values, which are
/// stored in the additive `dictionary_term_meta` side table (Shared's `DictionaryRecord` has no
/// source column).
public enum DictionaryEntryOrigin: String, CaseIterable, Sendable, Codable {
    /// Typed in the Dictionary by the user.
    case personal
    /// Chosen in a Contacts import.
    case contacts
    /// Chosen in a file import.
    case imported
    /// Saved before origins were recorded (or synced from a paired Mac).
    case earlier

    /// The harvest kind a row of this origin is tagged with: Contacts rows are `.contacts`, so
    /// they never land in the `.authored` tier.
    public var contextSource: ContextSourceKind { self == .contacts ? .contacts : .dictionary }
}

/// One Dictionary row with its origin.
public struct DictionaryEntry: Hashable, Sendable {
    public var term: String
    public var weight: Double
    public var origin: DictionaryEntryOrigin
    public init(term: String, weight: Double = 1.0, origin: DictionaryEntryOrigin = .personal) {
        self.term = term
        self.weight = weight
        self.origin = origin
    }
}

/// The three channels user vocabulary reaches.
public enum VocabularyChannel: String, CaseIterable, Sendable {
    /// The per-utterance CTC boost list (`BoostVocabulary`).
    case boost
    /// The cleanup prompt's "Spell these exactly as written" list (`personal.dictionary`).
    case spellList
    /// The ranked context primed into the cleanup prompt (`ContextRanker` → `PromptBuilder`).
    case cleanupContext
}

/// Which harvest sources each channel admits. N1: Contacts are admitted by none.
public enum ContactsChannelPolicy {
    /// Without a surface, Contacts are excluded from every channel (N1). See the surface-aware overload.
    public static func admits(_ source: ContextSourceKind, channel: VocabularyChannel) -> Bool {
        source != .contacts
    }

    /// N11 — surface-aware admission: Contacts are re-admitted only on chat, email and name-field
    /// surfaces (the rubric gives them weight 0.6 there, 0 elsewhere). Unknown surface → excluded.
    public static func admits(_ source: ContextSourceKind, channel: VocabularyChannel, surface: SurfaceKind?) -> Bool {
        guard source == .contacts else { return true }
        guard let surface else { return false }
        return ContextRubric.isConversational(surface)
    }

    public static func admits(_ origin: DictionaryEntryOrigin, channel: VocabularyChannel) -> Bool {
        admits(origin.contextSource, channel: channel)
    }

    /// The terms of `entries` a channel may use, in order.
    public static func terms(_ entries: [DictionaryEntry], channel: VocabularyChannel) -> [String] {
        entries.filter { admits($0.origin, channel: channel) }.map(\.term)
    }
}

/// Reads Dictionary rows together with their origin from the app database.
public enum DictionaryOrigins {
    /// The App's side table (`DatabaseDictionaryTermStore.metaTable`).
    public static let metaTable = "dictionary_term_meta"

    /// Every Dictionary row with its origin. A missing side table or row means `.earlier`.
    public static func entries(_ database: AppDatabase) throws -> [DictionaryEntry] {
        let records = try database.dictionaryTerms()
        let origins = (try? originsByID(database)) ?? [:]
        return records.map { DictionaryEntry(term: $0.term, weight: $0.weight, origin: origins[$0.id] ?? .earlier) }
    }

    static func originsByID(_ database: AppDatabase) throws -> [String: DictionaryEntryOrigin] {
        try database.reader.read { db in
            guard try db.tableExists(metaTable) else { return [:] }
            var out: [String: DictionaryEntryOrigin] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT termID, source FROM \(metaTable)") {
                let id: String = row["termID"]
                let raw: String = row["source"]
                out[id] = DictionaryEntryOrigin(rawValue: raw) ?? .earlier
            }
            return out
        }
    }
}
