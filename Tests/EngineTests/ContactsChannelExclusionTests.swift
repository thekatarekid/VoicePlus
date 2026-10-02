import Foundation
import GRDB
import Testing
import Shared
@testable import Engine

/// N1 — Contacts-origin Dictionary rows (and the live Contacts source) reach none of the three
/// channels: CTC boost list, cleanup spell-exactly list, cleanup context.
@Suite("N1 — Contacts excluded from every channel")
struct ContactsChannelExclusionTests {
    /// The words that garbled real dictations (Terminal "Bucket"/"Cab"/"Comp" etc.).
    static let contactWords = ["Akash", "DOCUBE", "Bucket", "Cab", "Cleaning", "Code"]
    static let personalWords = ["Kothari", "gpt-4o"]

    /// An in-memory app database with personal rows, Contacts rows and the App's origin side table.
    static func database() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS dictionary_term_meta (termID TEXT PRIMARY KEY NOT NULL, language TEXT NOT NULL, source TEXT NOT NULL)")
            for w in personalWords {
                let r = DictionaryRecord(term: w); try r.save(d)
                try d.execute(sql: "INSERT INTO dictionary_term_meta VALUES (?, 'any', 'personal')", arguments: [r.id])
            }
            for w in contactWords {
                let r = DictionaryRecord(term: w); try r.save(d)
                try d.execute(sql: "INSERT INTO dictionary_term_meta VALUES (?, 'any', 'contacts')", arguments: [r.id])
            }
            try DictionaryRecord(term: "Muesli").save(d)   // no meta row: saved earlier
            let imported = DictionaryRecord(term: "Paperclip"); try imported.save(d)
            try d.execute(sql: "INSERT INTO dictionary_term_meta VALUES (?, 'any', 'imported')", arguments: [imported.id])
        }
        return db
    }

    static func hasContactWord(_ terms: [String]) -> Bool {
        let bad = Set(contactWords.map { $0.lowercased() })
        return terms.contains { bad.contains($0.lowercased()) }
    }

    @Test func originsAreCarriedFromTheSideTable() throws {
        let entries = try DictionaryOrigins.entries(Self.database())
        let byTerm = Dictionary(uniqueKeysWithValues: entries.map { ($0.term, $0.origin) })
        #expect(byTerm["Akash"] == .contacts)
        #expect(byTerm["Kothari"] == .personal)
        #expect(byTerm["Paperclip"] == .imported)
        #expect(byTerm["Muesli"] == .earlier)
    }

    @Test func missingSideTableMeansEarlierNotContacts() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { try DictionaryRecord(term: "Kothari").save($0) }
        let entries = try DictionaryOrigins.entries(db)
        #expect(entries.map(\.origin) == [.earlier])
        #expect(ContactsChannelPolicy.terms(entries, channel: .boost) == ["Kothari"])
    }

    @Test func policyRejectsContactsOnEveryChannel() {
        for channel in VocabularyChannel.allCases {
            #expect(!ContactsChannelPolicy.admits(ContextSourceKind.contacts, channel: channel))
            #expect(!ContactsChannelPolicy.admits(DictionaryEntryOrigin.contacts, channel: channel))
            for origin in [DictionaryEntryOrigin.personal, .imported, .earlier] {
                #expect(ContactsChannelPolicy.admits(origin, channel: channel))
            }
        }
    }

    // MARK: Channel 1 — CTC boost list

    @Test func boostListHasNoContactsTerms() throws {
        let db = try Self.database()
        let store = DatabaseCorrectionStore(database: db)
        let authored = ContextHarvester(sources: [CorrectionSource(store: store)])
        let ranker = ContextRanker()
        let controller = BoostingController(
            context: { now in ranker.rank(harvesting: authored, now: now) },
            dictionary: { ContactsChannelPolicy.terms((try? DictionaryOrigins.entries(db)) ?? [], channel: .boost) },
            makeBooster: { _ in PassthroughBooster() })
        _ = controller.makeBoosterForUtterance()
        let terms = controller.lastTerms
        #expect(!Self.hasContactWord(terms))
        #expect(terms.contains("Kothari"))
        #expect(terms.contains("Paperclip"))
        #expect(terms.contains("Muesli"))
    }

    @Test func boostAuthoredTierIgnoresContactsOnlyTerms() {
        let ctx = RankedContext(terms: [
            RankedContextTerm(text: "Bucket", tier: .authored, score: 1, sources: [.contacts]),
            RankedContextTerm(text: "Kothari", tier: .authored, score: 1, sources: [.dictionary]),
        ], cap: 400, considered: 2)
        #expect(BoostVocabulary.build(dictionary: [], corrections: [], context: ctx) == ["Kothari"])
    }

    // MARK: Channel 3 — cleanup context (ranked list → prompt)

    @Test func cleanupContextHasNoContactsTerms() throws {
        let db = try Self.database()
        let harvester = ContextHarvester(sources: [
            CorrectionSource(store: DatabaseCorrectionStore(database: db)),
            ContactsSource(provider: MockContacts(["Akash Bucket", "Cab"])),
        ])
        let ranked = ContextRanker().rank(harvesting: harvester)
        #expect(!Self.hasContactWord(ranked.texts))
        #expect(!ranked.texts.contains("Akash Bucket"))
        #expect(ranked.texts.contains("Kothari"))
        #expect(!ranked.terms.contains { $0.sources.contains(.contacts) })

        let session = ContextPromptSession(harvester: harvester)
        let prompt = session.prepareUtterance()
        #expect(prompt.contains("Kothari"))
        for w in Self.contactWords { #expect(!prompt.contains(w)) }
    }

    @Test func personalRowSurvivesWhenAlsoAContact() {
        // A word the user typed themselves stays, even if Contacts also has it.
        let store = MockCorrectionStore(dictionary: [("Akash", 1)], entries: [DictionaryEntry(term: "Akash", origin: .contacts)])
        let ranked = ContextRanker().rank(harvesting: ContextHarvester(sources: [CorrectionSource(store: store)]))
        #expect(ranked.texts == ["Akash"])
        #expect(ranked.terms.first?.sources == [.dictionary])
    }

    @Test func promptBuilderDropsContactsOnlyTerms() {
        let ctx = RankedContext(terms: [
            RankedContextTerm(text: "Cleaning", tier: .recent, score: 1, sources: [.contacts]),
            RankedContextTerm(text: "Kothari", tier: .authored, score: 1, sources: [.dictionary, .contacts]),
        ], cap: 400, considered: 2)
        let prompt = PromptBuilder().build(ctx).prompt
        #expect(prompt.contains("Kothari"))
        #expect(!prompt.contains("Cleaning"))
    }
}

private struct PassthroughBooster: VocabularyBooster {
    var terms: [String] = []
    func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? { nil }
}
