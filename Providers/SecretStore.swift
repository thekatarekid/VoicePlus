import Foundation
import Security

/// Keychain abstraction so tests never touch the real Keychain.
public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

public extension SecretStore {
    func getData(_ key: String) throws -> Data? { try get(key).map { Data($0.utf8) } }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

/// Security.framework wrapper. Generic-password items under one service name.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "in.adityakatare.voiceplus") { self.service = service }

    public struct KeychainError: Error, Equatable { public let status: OSStatus }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func get(_ key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Well-known secret keys.
public enum SecretKey {
    public static func apiKey(_ provider: ProviderID) -> String { "apikey.\(provider.rawValue)" }
    public static let chatGPTOAuthTokens = "oauth.chatgpt.tokens"
}
