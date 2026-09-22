import Foundation
import Shared
@preconcurrency import CryptoKit

/// Keychain abstraction mirroring Providers' `SecretStore`; Sync keeps its own to avoid a module dependency.
public protocol SyncKeyStore: Sendable {
    func get(_ key: String) throws -> Data?
    func set(_ value: Data, for key: String) throws
    func delete(_ key: String) throws
}

public final class InMemorySyncKeyStore: SyncKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    public init() {}
    public func get(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: Data, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

public enum SyncCryptoError: Error, Equatable { case tampered, badFormat, noKey, keyMismatch }

/// 256-bit symmetric sync key. Only ever stored through a `SyncKeyStore` (Keychain in production).
public struct SyncKey: Equatable, Sendable {
    public static let storeKey = "sync.masterKey"
    public static let keyInfo = Data("voiceplus.sync.v1".utf8)
    let symmetric: SymmetricKey

    public init(symmetric: SymmetricKey) { self.symmetric = symmetric }
    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw SyncCryptoError.badFormat }
        symmetric = SymmetricKey(data: rawBytes)
    }
    public static func random() -> SyncKey { SyncKey(symmetric: SymmetricKey(size: .bits256)) }

    /// HKDF-SHA256: pairing secret (X25519 shared secret or passphrase bytes) + salt → key.
    public static func derive(fromPairingSecret secret: Data, salt: Data) -> SyncKey {
        let ikm = SymmetricKey(data: secret)
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: keyInfo, outputByteCount: 32)
        return SyncKey(symmetric: k)
    }
    public static func derive(fromSharedSecret s: SharedSecret, salt: Data) -> SyncKey {
        SyncKey(symmetric: s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: keyInfo, outputByteCount: 32))
    }

    public var rawBytes: Data { symmetric.withUnsafeBytes { Data($0) } }
    /// Short fingerprint for on-screen verification (no key material revealed).
    public var fingerprint: String { SHA256.hash(data: rawBytes).prefix(4).map { String(format: "%02x", $0) }.joined() }

    public static func == (a: SyncKey, b: SyncKey) -> Bool { a.symmetric == b.symmetric }

    // MARK: persistence (Keychain via store; never plaintext on disk)
    public func save(to store: SyncKeyStore) throws { try store.set(rawBytes, for: Self.storeKey) }
    public static func load(from store: SyncKeyStore) throws -> SyncKey? { try store.get(storeKey).map { try SyncKey(rawBytes: $0) } }

    // MARK: ChaChaPoly envelope
    /// Format: "VPS1" magic + combined (nonce|ciphertext|tag). `aad` binds context (e.g. record id) into the tag.
    static let magic = Data("VPS1".utf8)
    public func seal(_ plaintext: Data, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: symmetric, authenticating: aad)
        return Self.magic + box.combined
    }
    public func open(_ envelope: Data, aad: Data = Data()) throws -> Data {
        guard envelope.count > Self.magic.count + 28, envelope.prefix(Self.magic.count) == Self.magic else { throw SyncCryptoError.badFormat }
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.dropFirst(Self.magic.count))
            return try ChaChaPoly.open(box, using: symmetric, authenticating: aad)
        } catch { throw SyncCryptoError.tampered }
    }
}

public extension SyncKey {
    func seal(_ payload: SyncPayload) throws -> Data { try seal(payload.encoded(), aad: Data("payload".utf8)) }
    func openPayload(_ envelope: Data) throws -> SyncPayload { try SyncPayload.decode(try open(envelope, aad: Data("payload".utf8))) }
}

#if canImport(Security)
import Security
/// Real Keychain store. Authentication UI is forbidden; tests inject Security calls.
public struct KeychainSyncKeyStore: SyncKeyStore {
    public let service: String
    private let security: any SecurityItemClient
    public init(service: String = "in.adityakatare.voiceplus.sync", security: any SecurityItemClient = SystemSecurityItemClient()) {
        self.service = service
        self.security = security
    }
    public struct KeychainError: Error, Equatable { public let status: OSStatus }
    private func query(_ key: String) -> [String: Any] {
        NoninteractiveKeychainQuery.genericPassword(service: service, account: key)
    }
    public func get(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = security.copyMatching(q as CFDictionary, result: &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data
    }
    public func set(_ value: Data, for key: String) throws {
        let update = security.update(query(key) as CFDictionary, attributes: [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var q = query(key); q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = security.add(q as CFDictionary)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }
    public func delete(_ key: String) throws {
        let status = security.delete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
