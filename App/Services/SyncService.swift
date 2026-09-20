import AppKit
import Foundation
import Pipeline
import Shared
import Sync

/// P6.4 integration — encrypted sync at the composition root: the master key lives in the
/// Keychain, the payload is dictionary + personas + snippets + settings (never audio), QR
/// pairing derives a shared key (X25519 + short-code confirmation), transport is a folder
/// (iCloud Drive or any synced directory), and the export-everything file is a passphrase-
/// encrypted `.voiceplus` bundle.
public final class SyncService: @unchecked Sendable {
    public static let deviceIDKey = "sync.deviceID"
    public static let folderKey = "sync.folder"

    public let keyStore: any SyncKeyStore
    public let database: AppDatabase?
    public let snippets: any SnippetStoring
    public let settings: SettingsStore
    public private(set) var pairingSession: PairingSession?
    private let lock = NSLock()
    private var knownKeyFingerprint: String?

    public init(database: AppDatabase?, snippets: any SnippetStoring, settings: SettingsStore,
                keyStore: (any SyncKeyStore)? = nil) {
        self.database = database
        self.snippets = snippets
        self.settings = settings
        self.keyStore = keyStore ?? KeychainSyncKeyStore()
    }

    // MARK: Identity + key

    public var deviceID: String {
        if let id = settings.string(Self.deviceIDKey) { return id }
        let id = UUID().uuidString
        settings.set(id, for: Self.deviceIDKey)
        return id
    }

    public var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// The master key: loaded from the Keychain, minted (and stored) on first use.
    public func key() throws -> SyncKey {
        let key: SyncKey
        if let existing = try SyncKey.load(from: keyStore) {
            key = existing
        } else {
            key = SyncKey.random()
            try key.save(to: keyStore)
        }
        lock.lock(); knownKeyFingerprint = key.fingerprint; lock.unlock()
        return key
    }

    /// Nonsecret display metadata from this session's explicit key use. Reading settings must
    /// never query or create a Keychain item, even when a key already exists or sync is enabled.
    public var keyFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return knownKeyFingerprint
    }

    // MARK: Payload (never audio — `SyncPayload.audit` enforces it)

    public func payload(now: Date = Date()) -> SyncPayload {
        var p = SyncPayload(deviceID: deviceID, generatedAt: now)
        if let database {
            let terms = (try? database.dictionaryTerms()) ?? []
            p.dictionary = terms.map { record in
                Sync.DictionaryEntry(id: record.id, word: record.term,
                                     pronunciationHint: record.spokenForms.isEmpty ? nil : record.spokenForms,
                                     updatedAt: record.createdAt)
            }
        }
        p.snippets = ((try? snippets.all()) ?? []).map { snippet in
            Sync.Snippet(id: snippet.id, trigger: snippet.trigger, expansion: snippet.body, updatedAt: snippet.createdAt)
        }
        return p
    }

    /// Merge a remote payload into the local stores (last-writer-wins already applied).
    public func apply(_ merged: SyncPayload) {
        if let database {
            for entry in merged.dictionary where !entry.deleted {
                let record = DictionaryRecord(id: entry.id, term: entry.word,
                                              spokenForms: entry.pronunciationHint ?? "", createdAt: entry.updatedAt)
                do { try database.save(record) } catch { Log.db.error("sync dictionary apply failed: \(error)") }
            }
        }
        let existing = ((try? snippets.all()) ?? [])
        for s in merged.snippets where !s.deleted {
            guard !existing.contains(where: { $0.id == s.id || $0.trigger == s.trigger }) else { continue }
            try? snippets.save(Pipeline.Snippet(id: s.id, trigger: s.trigger, body: s.expansion, createdAt: s.updatedAt))
        }
    }

    // MARK: QR pairing (P6.4)

    /// Start pairing: returns the payload to render as a QR code on this device.
    public func startPairing() -> PairingPayload {
        lock.lock(); defer { lock.unlock() }
        let session = PairingSession(deviceID: deviceID, deviceName: deviceName)
        pairingSession = session
        return session.payload
    }

    public func qrPNG(scale: CGFloat = 8) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let session = pairingSession else { return nil }
        return QRCode.pngData(for: session.payload, scale: scale)
    }

    /// Finish pairing with the peer's scanned QR string; the derived key replaces the local one.
    @discardableResult
    public func completePairing(scanned: String, confirmedPeerCode: String?) throws -> SyncKey {
        lock.lock()
        let session = pairingSession
        lock.unlock()
        guard let session else { throw PairingError.badPeerKey }
        let peer = try PairingPayload.parse(scanned)
        let shared = try session.complete(with: peer, confirmedPeerCode: confirmedPeerCode)
        try shared.save(to: keyStore)
        lock.lock(); pairingSession = nil; knownKeyFingerprint = shared.fingerprint; lock.unlock()
        return shared
    }

    // MARK: Folder transport + export

    public var folderURL: URL? {
        get { settings.string(Self.folderKey).map { URL(fileURLWithPath: $0) } }
        set { settings.set(newValue?.path, for: Self.folderKey) }
    }

    /// One sync round over the configured folder: push ours, pull + merge peers, apply.
    @discardableResult
    public func syncNow() throws -> SyncResult {
        guard let folder = folderURL else { throw SyncCryptoError.noKey }
        let transport = try DirectorySyncTransport(directory: folder)
        let engine = Sync.SyncEngine(deviceID: deviceID, key: try key(), transport: transport)
        let result = try engine.sync(payload())
        apply(result.merged)
        return result
    }

    /// Export-everything `.voiceplus` file (passphrase-encrypted; key never leaves the Keychain).
    public func exportEverything(to url: URL, passphrase: String) throws {
        try ExportBundle.export(payload(), passphrase: passphrase, to: url)
    }

    @discardableResult
    public func importEverything(from url: URL, passphrase: String) throws -> SyncPayload {
        let remote = try ExportBundle.import(from: url, passphrase: passphrase)
        let merged = SyncMerge.merge(payload(), remote)
        apply(merged)
        return merged
    }
}
