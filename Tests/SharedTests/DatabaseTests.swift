import Foundation
import GRDB
import Testing
@testable import Shared

@Suite struct DatabaseTests {
    @Test func migrationsCreateAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        #expect(tables == [
            // R8.2 added `ambient_search_index` (and nothing else) — see AmbientSearchIndexTests.
            "ambient_search_index",
            "corrections", "dictation_history", "dictionary", "feature_flags", "injection_outcomes",
            "lab_runs", "network_log", "personas", "snippets",
        ])
        let applied = try db.reader.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        #expect(applied == Set(AppDatabase.migrationIdentifiers))
    }

    @Test func dictationAndCorrectionsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let utterance = Utterance(
            spans: [TranscriptSpan(text: "ping", confidence: 0.9, audioRange: 0...0.3, provenance: [.asr]),
                    TranscriptSpan(text: "kotari", confidence: 0.3, audioRange: 0.3...0.9, provenance: [.asr])],
            endedAt: Date(), register: .chat, route: .dictate
        )
        let record = try DictationRecord(utterance: utterance, finalText: "ping Kothari", appBundleID: "com.apple.Notes")
        try db.insert(record)

        let fetched = try #require(try db.dictation(id: utterance.id.uuidString))
        #expect(fetched.finalText == "ping Kothari")
        #expect(try fetched.spans() == utterance.spans)
        #expect(try db.recentDictations().count == 1)

        let correction = try db.insert(CorrectionRecord(
            utteranceID: record.id, original: "kotari", corrected: "Kothari", audioRange: 0.3...0.9, source: "voiceRepair"
        ))
        #expect(correction.id != nil)
        #expect(try db.corrections(forUtterance: record.id).map(\.corrected) == ["Kothari"])
    }

    @Test func correctionRequiresExistingUtterance() throws {
        let db = try AppDatabase.inMemory()
        #expect(throws: (any Error).self) {
            try db.insert(CorrectionRecord(utteranceID: "missing", original: "a", corrected: "b", audioRange: 0...1, source: "test"))
        }
    }

    @Test func networkLogAndEgressTotal() throws {
        let db = try AppDatabase.inMemory()
        let start = Date(timeIntervalSinceNow: -10)
        try db.insert(NetworkLogRecord(stage: "style", provider: "openrouter", host: "openrouter.ai", bytesOut: 1200, bytesIn: 800, purpose: "rewrite"))
        try db.insert(NetworkLogRecord(stage: "models", provider: "huggingface", host: "huggingface.co", bytesOut: 300, bytesIn: 5_000_000, purpose: "download"))
        #expect(try db.networkLog().count == 2)
        #expect(try db.bytesEgressed(since: start) == 1500)
        #expect(try db.bytesEgressed(since: Date(timeIntervalSinceNow: 60)) == 0)
    }

    @Test func flagsLabRunsInjectionOutcomes() throws {
        let db = try AppDatabase.inMemory()
        try db.upsert(FeatureFlagRecord(id: "contextBiasing", enabled: false))
        try db.upsert(FeatureFlagRecord(id: "contextBiasing", enabled: true))
        #expect(try db.featureFlags().map(\.enabled) == [true])

        let run = try db.insert(LabRunRecord(name: "biasing on/off", configJSON: "{}", metricsJSON: "{\"wer\":0.08}", hardware: "M1"))
        #expect(try db.labRuns().first?.id == run.id)

        try db.insert(InjectionOutcomeRecord(utteranceID: nil, appBundleID: "com.apple.Terminal", method: "paste", succeeded: true, latencyMs: 42))
        #expect(try db.injectionOutcomes(appBundleID: "com.apple.Terminal").count == 1)
        #expect(try db.injectionOutcomes(appBundleID: "other").count == 0)
    }

    @Test func snippetsPersonasDictionary() throws {
        let db = try AppDatabase.inMemory()
        try db.save(SnippetRecord(trigger: "sig", body: "Best,\nAditya"))
        #expect(try db.snippets().map(\.trigger) == ["sig"])

        try db.save(PersonaRecord(appBundleID: "com.tinyspeck.slackmacgap", instructions: "casual, lowercase"))
        #expect(try db.persona(forApp: "com.tinyspeck.slackmacgap")?.instructions == "casual, lowercase")
        #expect(try db.persona(forApp: "com.apple.mail") == nil)

        let term = DictionaryRecord(term: "Kothari", spokenForms: "[\"ko-tah-ree\"]", weight: 2)
        try db.save(term)
        #expect(try db.dictionaryTerms().map(\.term) == ["Kothari"])
        try db.deleteDictionaryTerm(id: term.id)
        #expect(try db.dictionaryTerms().isEmpty)
    }

    @Test func onDiskDatabaseUsesWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appendingPathComponent("voiceplus.sqlite"))
        let mode = try db.reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode?.lowercased() == "wal")
    }
}
