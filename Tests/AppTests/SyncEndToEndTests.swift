import Engine
import Foundation
import GRDB
import Pipeline
import Shared
import Sync
import Testing
@testable import VoicePlusApp

/// V5 F4 — Sync end to end over two app instances (two in-memory databases, two key stores, one
/// shared folder): QR pairing → encrypted push → pull + merge → apply on the second Mac, the
/// passphrase export into a fresh instance, and recordings never in either.
/// Hardware-only (T1): a real camera QR scan between two Macs and an iCloud Drive folder in sync.
@Suite struct SyncEndToEndTests {
    static let mail = "com.apple.mail", slack = "com.tinyspeck.slackmacgap"

    struct Mac {
        let database: AppDatabase
        let service: SyncService
        let keys = InMemorySyncKeyStore()
        init() throws {
            database = try AppDatabase.inMemory()
            service = SyncService(database: database, snippets: InMemorySnippetStore(), settings: InMemorySettingsStore(),
                                  keyStore: keys)
        }
        var personas: DatabasePersonaStore { DatabasePersonaStore(database: database) }
        func terms() throws -> Set<String> { Set(try database.dictionaryTerms().map(\.term)) }
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vp-sync-\(UUID().uuidString)", isDirectory: true)
    }

    static func pair(_ a: Mac, _ b: Mac) throws {
        let qrA = a.service.startPairing(), qrB = b.service.startPairing()
        try a.service.completePairing(scanned: qrB.qrString, confirmedPeerCode: qrB.shortCode)
        try b.service.completePairing(scanned: qrA.qrString, confirmedPeerCode: qrA.shortCode)
    }

    @Test func pairingThenFolderRoundsMergeBothWays() throws {
        let a = try Mac(), b = try Mac()
        try Self.pair(a, b)
        #expect(try a.service.key() == b.service.key(), "both sides derive the same key")
        #expect(a.service.keyFingerprint == b.service.keyFingerprint)

        try a.database.save(DictionaryRecord(term: "Kothari"))
        try a.personas.save(Pipeline.Persona(appBundleID: Self.mail, text: "Warm, brief, sign off Cheers"))
        try a.personas.save(Pipeline.Persona(appBundleID: Self.slack, text: "auto draft", isAutoDrafted: true))
        try a.service.snippets.save(Pipeline.Snippet(trigger: "sig", body: "— Aditya"))
        try b.database.save(DictionaryRecord(term: "Muesli"))

        let folder = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        a.service.folderURL = folder
        b.service.folderURL = folder

        // The folder only ever holds ciphertext.
        let first = try a.service.syncNow()
        #expect(first.peersApplied.isEmpty)
        let blob = try Data(contentsOf: folder.appendingPathComponent(a.service.deviceID).appendingPathExtension(DirectorySyncTransport.ext))
        #expect(blob.range(of: Data("Kothari".utf8)) == nil && blob.range(of: Data("Cheers".utf8)) == nil)

        let second = try b.service.syncNow()
        #expect(second.peersApplied == [a.service.deviceID] && second.rejected.isEmpty)
        #expect(try b.terms() == ["Kothari", "Muesli"])
        #expect(try b.personas.persona(for: Self.mail)?.text == "Warm, brief, sign off Cheers")
        #expect(try b.personas.persona(for: Self.mail)?.isAutoDrafted == false)
        #expect(try b.personas.persona(for: Self.slack) == nil, "auto-drafts are re-learned per Mac, not synced")
        #expect(try b.service.snippets.all().map(\.trigger) == ["sig"])

        try a.service.syncNow()
        #expect(try a.terms() == ["Kothari", "Muesli"], "B's word came back to A")
    }

    @Test func newerEditWinsAndOlderOneDoesNot() throws {
        let a = try Mac(), b = try Mac()
        try Self.pair(a, b)
        let folder = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        a.service.folderURL = folder; b.service.folderURL = folder
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try a.personas.save(Pipeline.Persona(appBundleID: Self.mail, text: "old", updatedAt: t0))
        try b.personas.save(Pipeline.Persona(appBundleID: Self.mail, text: "new", updatedAt: t0.addingTimeInterval(60)))
        try a.service.syncNow()
        try b.service.syncNow()
        #expect(try b.personas.persona(for: Self.mail)?.text == "new", "B's newer edit is kept")
        try a.service.syncNow()
        #expect(try a.personas.persona(for: Self.mail)?.text == "new", "A takes the newer edit")
    }

    @Test func unpairedDeviceIsRejectedAndAppliesNothing() throws {
        let a = try Mac(), b = try Mac(), stranger = try Mac()
        try Self.pair(a, b)
        let folder = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        stranger.service.folderURL = folder; a.service.folderURL = folder
        try stranger.database.save(DictionaryRecord(term: "Intruder"))
        try stranger.service.syncNow()
        let r = try a.service.syncNow()
        #expect(r.rejected == [stranger.service.deviceID])
        #expect(try !a.terms().contains("Intruder"))
    }

    @Test func passphraseExportMergesIntoAFreshInstance() throws {
        let a = try Mac(), fresh = try Mac()
        try a.database.save(DictionaryRecord(term: "Kothari"))
        try a.personas.save(Pipeline.Persona(appBundleID: Self.mail, text: "Formal"))
        try fresh.database.save(DictionaryRecord(term: "Paperclip"))
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("me").appendingPathExtension(ExportBundle.fileExtension)
        try a.service.exportEverything(to: file, passphrase: "correct horse")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.range(of: Data("Kothari".utf8)) == nil, "export is encrypted")

        #expect(throws: SyncCryptoError.tampered) { try fresh.service.importEverything(from: file, passphrase: "wrong") }
        #expect(try fresh.terms() == ["Paperclip"], "a failed import applies nothing")
        try fresh.service.importEverything(from: file, passphrase: "correct horse")
        #expect(try fresh.terms() == ["Kothari", "Paperclip"])
        #expect(try fresh.personas.persona(for: Self.mail)?.text == "Formal")
    }

    /// F3 — dictation audio and its transcripts stay on the Mac: neither the sync envelope nor the
    /// export file carries a clip, its path, the dictation text or a training pair.
    @Test func recordingsAreExcludedByDefault() throws {
        let a = try Mac()
        let secret = "zanzibarquokka"
        let dictation = DictationRecord(startedAt: Date(), endedAt: Date(), register: "prose", route: "local",
                                            appBundleID: Self.mail, rawText: "the \(secret) memo", finalText: "The \(secret) memo.",
                                            spansJSON: "[]")
        try a.database.writer.write { try dictation.insert($0) }
        let root = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = InMemoryUtteranceAudio(utterances: ["u1": [Float](repeating: 0.25, count: 32_000)])
        let pairs = try TrainingPairStore(root: root, audio: audio)
        try pairs.add(TrainingPair(utteranceID: "u1", original: "kotari", corrected: "Kothari", audioRange: 0...1,
                                   source: secret))
        let clipNames = (try? FileManager.default.contentsOfDirectory(atPath: pairs.clipsDirectory.path)) ?? []

        #expect(SyncPayload.audit().isEmpty, "the payload shape has no audio field")
        let payload = a.service.payload()
        let text = try #require(String(data: try payload.encoded(), encoding: .utf8))
        #expect(!text.contains(secret) && !text.contains("kotari"))
        for name in clipNames { #expect(!text.contains(name)) }
        #expect(!text.lowercased().contains("clip") && !text.lowercased().contains(".wav"))

        let round = try ExportBundle.import(try ExportBundle.export(payload, passphrase: "pw"), passphrase: "pw")
        let roundText = try #require(String(data: try round.encoded(), encoding: .utf8))
        #expect(!roundText.contains(secret))
        #expect(try a.database.reader.read { try DictationRecord.fetchCount($0) } == 1, "the recording's row stays local")
    }
}
