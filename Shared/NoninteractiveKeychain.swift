import Foundation
import LocalAuthentication
import Security

/// Injectable Security entry points. Tests inspect requests without reading the user's Keychain.
public protocol SecurityItemClient: Sendable {
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

public struct SystemSecurityItemClient: SecurityItemClient {
    public init() {}
    public func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query, &result)
    }
    public func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    public func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    public func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

public enum NoninteractiveKeychainQuery {
    /// A fresh context for every request: never authenticate or reuse an interactive context.
    /// Security returns errSecInteractionNotAllowed when credentials require user interaction.
    public static func genericPassword(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        // The legacy macOS Keychain ACL bridge can still offer Allow/Deny with LAContext alone.
        // Keep its explicit UI-fail policy too, despite the SDK deprecation in favor of LAContext.
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
}
