import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Sync
import Testing
@testable import VoicePlusApp

/// Phase 6 acceptance — day-30 personal WER beats day-1 through the wired adaptation loop; a
/// corrected word is never re-mis-heard; the Hinglish fixture lands as one string through the
/// lander with a mock injector; the profile round-trips export → import; QR pairing derives
/// one shared key on both ends.
@Suite("Phase 6 acceptance — adaptation + code-switch + sync")
struct Phase6AcceptanceTests {
    static func adaptationService() throws -> AdaptationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p6-adapt-\(UUID())")
        return try AdaptationService(root: root,
                                     werFile: root.appendingPathComponent("wer.json"),
                                     toastFile: root.appendingPathComponent("toasts.json"))
    }

    @Test func day30PersonalWERBeatsDay1ThroughTheWiredLoop() async throws {
        let service = try Self.adaptationService()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day30 = day1.addingTimeInterval(29 * 86_400)

        // Day 1: the engine keeps mis-hearing the user's name; every repair is a correction.
        for i in 0..<4 {
            service.ingest(CorrectionRecord(utteranceID: "u\(i)", createdAt: day1,
                                            original: "email kotari about the deck",
                                            corrected: "email Kothari about the deck",
                                            audioRange: 0...1.2, source: "voiceRepair"))
        }
        let lexicon = service.retrain()
        #expect(lexicon.weight(of: "kothari") > 0)
        #expect(!lexicon.contextEntries().isEmpty, "lexicon feeds the biasing ranker")

        // Day 30: the wired regression guard fixes the mis-hearing before it lands —
        // the utterance needs no correction, so the day's WER sample is clean.
        let guardStage = RegressionGuardStage(lexicon: { service.loop.lexicon })
        let spans = [
            TranscriptSpan(text: "email", confidence: 0.9, audioRange: 0...0.3),
            TranscriptSpan(text: "kotari", confidence: 0.6, audioRange: 0.3...0.7),
            TranscriptSpan(text: "about", confidence: 0.9, audioRange: 0.7...1.0),
        ]
        let corrected = try await guardStage.process(spans, context: StageContext())
        #expect(corrected.map(\.text).contains("Kothari"), "corrected word never re-mis-heard")
        service.recordCleanLanding(text: corrected.joinedText, at: day30)

        let werDay1 = try #require(service.personalWER.wer(on: day1))
        let werDay30 = try #require(service.personalWER.wer(on: day30))
        #expect(werDay30 < werDay1, "day-30 (\(werDay30)) must beat day-1 (\(werDay1))")
    }

    @Test func postDictationEditsFeedTheLoopAndTheRememberToastShowsOnce() throws {
        let service = try Self.adaptationService()
        service.ingestEdit(utteranceID: "u9", original: "ship the musely build", edited: "ship the Muesli build")
        #expect(service.store.count > 0, "keyboard edit became a training pair")

        let toast = service.trainByVoice(word: "Kothari", samples: [Float](repeating: 0.1, count: 8000))
        #expect(toast?.contains("Kothari") == true, "first capture shows the remember toast")
        let again = service.trainByVoice(word: "Kothari", samples: [Float](repeating: 0.1, count: 8000))
        #expect(again == nil, "never repeat the toast for the same word")
        #expect(service.pronunciation?.entries(for: "Kothari").count == 2, "both clips are stored")
    }

    // MARK: Code-switch (P6.3)

    @Test func hinglishFixtureLandsAsOneStringThroughTheLander() async throws {
        let fixture = try TranscriptFixture.load(named: "hinglish")
        let spans = fixture.spans.map(\.span)

        let system = MockSystemAccess()
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: TextInjector(system: system),
                                     system: system, repair: nil, flags: .inMemory(), database: nil)
        let codeSwitch = CodeSwitchService()
        var badges: [String] = []
        codeSwitch.onIndicatorChange = { badges.append($0) }
        lander.textFinalizer = { codeSwitch.finalize($0) }

        let result = await lander.land(spans, startedAt: Date(), focus: system.frontmostApp())
        #expect(result.landed)

        // One injected string carrying both scripts — never split per script.
        let landed = system.field.value
        #expect(landed == result.text)
        #expect(landed.contains("बजे"))
        #expect(landed.contains("meeting"))
        #expect(landed.contains("भेज"))
        #expect(landed.contains("deck") || landed.contains("desk"))
        #expect(codeSwitch.lastSegments?.isCodeSwitched == true)
        #expect(badges.last == "EN·हि", "pill shows the mixed-script indicator")
        let scripts = codeSwitch.lastSegments?.scripts ?? []
        #expect(scripts.contains(.latin) && scripts.contains(.devanagari))
    }

    @Test func latinOnlyUtteranceKeepsDefaultTextAndBadge() {
        let codeSwitch = CodeSwitchService()
        var badge = "?"
        codeSwitch.onIndicatorChange = { badge = $0 }
        let spans = [TranscriptSpan(text: "hello world", confidence: 0.9, audioRange: 0...1)]
        #expect(codeSwitch.finalize(spans) == nil, "non-code-switched text keeps the joined default")
        #expect(badge == "EN" || badge.isEmpty)
    }

    // MARK: Sync (P6.4)

    static func syncService(database: AppDatabase?) -> SyncService {
        SyncService(database: database, snippets: InMemorySnippetStore(), settings: InMemorySettingsStore(),
                    keyStore: InMemorySyncKeyStore())
    }

    @Test func profileRoundTripsThroughTheEverythingFile() throws {
        let dbA = try AppDatabase.inMemory()
        try dbA.save(DictionaryRecord(term: "Kothari"))
        try dbA.save(DictionaryRecord(term: "Muesli"))
        let a = Self.syncService(database: dbA)
        try a.snippets.save(Pipeline.Snippet(trigger: "sig", body: "— Aditya"))

        let payload = a.payload()
        #expect(payload.dictionary.count == 2)
        #expect(payload.snippets.count == 1)
        #expect(SyncPayload.audit().isEmpty, "payload shape bans audio fields")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p6-\(UUID()).voiceplus")
        try a.exportEverything(to: url, passphrase: "hunter2 correct horse")

        // Fresh machine: import merges everything in.
        let dbB = try AppDatabase.inMemory()
        let b = Self.syncService(database: dbB)
        _ = try b.importEverything(from: url, passphrase: "hunter2 correct horse")
        let terms = Set((try dbB.dictionaryTerms()).map(\.term))
        #expect(terms == ["Kothari", "Muesli"])
        #expect((try b.snippets.all()).contains { $0.trigger == "sig" && $0.body == "— Aditya" })

        // Wrong passphrase never decrypts.
        #expect(throws: (any Error).self) { try b.importEverything(from: url, passphrase: "wrong") }
    }

    @Test func qrPairingDerivesTheSameKeyOnBothDevices() throws {
        let a = Self.syncService(database: nil)
        let b = Self.syncService(database: nil)
        let payloadA = a.startPairing()
        let payloadB = b.startPairing()
        #expect(a.qrPNG() != nil, "QR image renders for the pairing view")
        #expect(payloadA.qrString.hasPrefix("voiceplus-pair://"))

        let keyA = try a.completePairing(scanned: payloadB.qrString, confirmedPeerCode: payloadB.shortCode)
        let keyB = try b.completePairing(scanned: payloadA.qrString, confirmedPeerCode: payloadA.shortCode)
        #expect(keyA.fingerprint == keyB.fingerprint, "both ends hold the same derived key")
        #expect(a.keyFingerprint == keyA.fingerprint, "key persisted to the (test) keystore")

        // Sealed payloads round-trip across the pair.
        let sealed = try keyA.seal(SyncPayload(deviceID: "a"))
        #expect(try keyB.openPayload(sealed).deviceID == "a")
    }

    @Test func folderTransportSyncMergesPeers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p6-sync-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shared = SyncKey.random()

        let dbA = try AppDatabase.inMemory()
        try dbA.save(DictionaryRecord(term: "Kothari"))
        let a = Self.syncService(database: dbA)
        try shared.save(to: a.keyStore)
        a.folderURL = folder
        _ = try a.syncNow()

        let dbB = try AppDatabase.inMemory()
        try dbB.save(DictionaryRecord(term: "Muesli"))
        let b = Self.syncService(database: dbB)
        try shared.save(to: b.keyStore)
        b.folderURL = folder
        let result = try b.syncNow()
        #expect(result.peersApplied.count == 1)
        let terms = Set((try dbB.dictionaryTerms()).map(\.term))
        #expect(terms.isSuperset(of: ["Kothari", "Muesli"]))
    }
}
