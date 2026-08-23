import Foundation
import Testing
import Shared
@testable import Engine

@Suite("Biasing: harvester + ranker (T1/T2)")
struct BiasingHarvesterTests {
    @Test func entityExtractorKeepsEntitiesDropsFunctionWords() {
        let text = "Please call TeamViewer AG about kubectl and gpt-4o, then ping Kothari."
        let terms = EntityExtractor.extract(from: text)
        #expect(terms.contains("TeamViewer"))
        #expect(terms.contains("TeamViewer AG"))
        #expect(terms.contains("gpt-4o"))
        #expect(terms.contains("Kothari"))
        #expect(!terms.contains("call") && !terms.contains("about") && !terms.contains("kubectl"))
        let weighted = EntityExtractor.extractWeighted(from: text)
        #expect(weighted.first { $0.term == "kubectl" }?.strength == 0.35)   // on-screen jargon, low weight
        #expect(weighted.first { $0.term == "Kothari" }?.strength == 1)
        #expect(!weighted.contains { $0.term == "and" })
    }

    @Test func allSourcesAreTaggedAndDeduped() {
        let now = Date()
        let ring = RecentWordsRing()
        ring.record("deploy the Kothari service", at: now.addingTimeInterval(-60))
        ring.record("old words here", at: now.addingTimeInterval(-700))   // outside 10 min
        let parts = ParticipantsSource(); parts.set(["Priya Kothari"])
        let h = ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText([("Meeting with TeamViewer AG", 1.0), ("kubectl get pods", 0.5)])),
            ring,
            CorrectionSource(store: MockCorrectionStore(corrections: [("Kothari", now.addingTimeInterval(-86_400))], dictionary: [("gpt-4o", 1.0)])),
            CodeSymbolSource(provider: MockOpenDocuments(["/src/ShallowFusionBiaser.swift"])),
            ContactsSource(provider: MockContacts(["Aditya"])),
            parts,
        ])
        let entries = h.harvest(now: now)
        let byKind = Dictionary(grouping: entries, by: \.source)
        #expect(Set(byKind.keys) == Set(ContextSourceKind.allCases))
        #expect(byKind[.recentWords]!.map(\.text).contains("Kothari"))
        #expect(!entries.contains { $0.text == "words" })
        #expect(byKind[.codeSymbols]!.map(\.text).contains("ShallowFusionBiaser"))
        #expect(byKind[.codeSymbols]!.map(\.text).contains("Fusion"))
        #expect(byKind[.dictionary]!.map(\.text) == ["gpt-4o"])
        // Dedup is per (text, source): Kothari appears for corrections, recentWords (and not twice in either).
        #expect(byKind[.corrections]!.filter { $0.text == "Kothari" }.count == 1)
    }

    @Test func rankerHardCapsAt400AndPrefersCorrectionsAndRecency() {
        let now = Date()
        var entries: [ContextEntry] = (0..<1_000).map {
            ContextEntry(text: "Screen\($0)", source: .axTree, observedAt: now.addingTimeInterval(-Double($0) * 10), salience: 0.5)
        }
        entries.append(ContextEntry(text: "Kothari", source: .corrections, observedAt: now.addingTimeInterval(-86_400 * 30)))
        entries.append(ContextEntry(text: "Kothari", source: .axTree, observedAt: now))
        let ranked = Ranker().rank(entries, now: now)
        #expect(ranked.count == 400)
        #expect(ranked.first?.text == "Kothari")
        #expect(ranked.first?.sources == [.corrections, .axTree])
        #expect(ranked.map(\.text).contains("Screen0"))
        #expect(!ranked.map(\.text).contains("Screen999"))
        #expect(ranked.allSatisfy { $0.weight > 0 && $0.weight <= 1 })
        #expect(Ranker(cap: 10).rank(entries, now: now).count == 10)
    }

    @Test func databaseCorrectionStoreReadsRecords() throws {
        let db = try AppDatabase.inMemory()
        try db.insert(DictationRecord(id: "u1", startedAt: Date(), endedAt: Date(), register: "prose", route: "local", appBundleID: nil, rawText: "", finalText: "", spansJSON: "[]"))
        _ = try db.insert(CorrectionRecord(utteranceID: "u1", original: "Kriya", corrected: "Priya", audioRange: 0...1, source: "voiceRepair"))
        try db.save(DictionaryRecord(term: "kubectl", weight: 2))
        let store = DatabaseCorrectionStore(database: db)
        #expect(try store.correctedTerms().map(\.term) == ["Priya"])
        #expect(try store.dictionaryTerms().map(\.term) == ["kubectl"])
        let entries = CorrectionSource(store: store).harvest(now: Date())
        #expect(entries.map(\.text).sorted() == ["Priya", "kubectl"])
    }
}
