import Foundation
import Pipeline
import Shared
import Sync
import Testing
@testable import VoicePlusApp

private final class ObservedSyncKeys: SyncKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var readCount = 0
    private var writeCount = 0
    private var deleteCount = 0
    init(value: Data? = nil) { self.value = value }
    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return [readCount, writeCount, deleteCount]
    }
    func get(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return value
    }
    func set(_ value: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        self.value = value
    }
    func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        value = nil
    }
}

@Suite("Sync settings never unlock Keychain on opening")
@MainActor
struct SyncSettingsKeyAccessTests {
    private func service(keys: ObservedSyncKeys, settings: InMemorySettingsStore = InMemorySettingsStore()) -> SyncService {
        SyncService(database: nil, snippets: InMemorySnippetStore(), settings: settings, keyStore: keys)
    }

    @Test(arguments: [false, true])
    func openingSettingsDoesNotReadOrCreateAKey(existing: Bool) {
        let keys = ObservedSyncKeys(value: existing ? SyncKey.random().rawBytes : nil)
        let service = service(keys: keys)
        let model = SyncSettingsViewModel(service: service)
        #expect(model.syncStatus == .off && model.fingerprint == nil)
        #expect(service.keyFingerprint == nil)
        #expect(keys.counts == [0, 0, 0])
        service.folderURL = URL(fileURLWithPath: "/configured/sync")
        let configured = SyncSettingsViewModel(service: service, folderReachable: { _ in true })
        #expect(configured.canSyncNow && configured.fingerprint == nil)
        #expect(keys.counts == [0, 0, 0], "Opening configured sync must also avoid Keychain")
    }

    @Test(arguments: [false, true])
    func explicitSyncUsesTheKeyAndRefreshesOnlyNonsecretDisplayMetadata(existing: Bool) throws {
        let key = SyncKey.random()
        let keys = ObservedSyncKeys(value: existing ? key.rawBytes : nil)
        let service = service(keys: keys)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        service.folderURL = folder
        let model = SyncSettingsViewModel(service: service)
        #expect(keys.counts == [0, 0, 0])
        model.syncNow()
        #expect(model.failure == nil && model.lastRound != nil)
        let fingerprint = try #require(model.fingerprint)
        if existing { #expect(fingerprint == key.fingerprint) }
        #expect(keys.counts == [1, existing ? 0 : 1, 0])
        let reopened = SyncSettingsViewModel(service: service)
        #expect(reopened.fingerprint == fingerprint && service.keyFingerprint == fingerprint)
        #expect(keys.counts == [1, existing ? 0 : 1, 0], "Reopening uses metadata, not another key read")
    }

    @Test func onlyConfirmedPairingWritesAKeyAndUpdatesFingerprint() throws {
        let keys = ObservedSyncKeys()
        let service = service(keys: keys)
        let model = SyncSettingsViewModel(service: service)
        model.startPairing()
        #expect(keys.counts == [0, 0, 0])
        let peer = PairingSession(deviceID: "peer", deviceName: "Peer Mac")
        model.scannedPeer = peer.payload.qrString
        model.peerCode = peer.shortCode == "000000" ? "111111" : "000000"
        model.completePairing()
        #expect(model.failure != nil && model.fingerprint == nil)
        #expect(keys.counts == [0, 0, 0])
        model.peerCode = peer.shortCode
        model.completePairing()
        #expect(model.failure == nil && model.fingerprint != nil)
        #expect(service.keyFingerprint == model.fingerprint)
        #expect(keys.counts == [0, 1, 0])
        let reopened = SyncSettingsViewModel(service: service)
        #expect(reopened.fingerprint == model.fingerprint && keys.counts == [0, 1, 0])
    }
}
