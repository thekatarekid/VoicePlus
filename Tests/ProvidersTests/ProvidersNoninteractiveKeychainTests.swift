import Foundation
import LocalAuthentication
import Security
import Shared
import Testing
@testable import Providers

@Suite("Providers Keychain never authenticates interactively")
struct ProvidersNoninteractiveKeychainTests {
    final class RecordingSecurity: SecurityItemClient, @unchecked Sendable {
        struct Call {
            let operation: String
            let query: [String: Any]
            let attributes: [String: Any]?
        }
        var calls: [Call] = []
        var copyStatus: OSStatus = errSecSuccess
        var updateStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var data = Data("provider-secret".utf8)
        func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus {
            calls.append(Call(operation: "get", query: query as! [String: Any], attributes: nil))
            result = data as CFData
            return copyStatus
        }
        func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
            calls.append(Call(operation: "update", query: query as! [String: Any], attributes: attributes as? [String: Any]))
            return updateStatus
        }
        func add(_ attributes: CFDictionary) -> OSStatus {
            calls.append(Call(operation: "add", query: attributes as! [String: Any], attributes: nil))
            return addStatus
        }
        func delete(_ query: CFDictionary) -> OSStatus {
            calls.append(Call(operation: "delete", query: query as! [String: Any], attributes: nil))
            return deleteStatus
        }
    }

    @Test func everyReadUpdateCreateAndDeleteForbidsAuthenticationUI() throws {
        let client = RecordingSecurity()
        let store = KeychainSecretStore(service: "test.noninteractive", security: client)
        let value = "provider-secret"
        client.data = Data(value.utf8)
        #expect(try store.get("oauth.connector.tokens") == value)
        try store.set(value, for: "oauth.connector.tokens")
        client.updateStatus = errSecItemNotFound
        try store.set(value, for: "oauth.connector.tokens")
        try store.delete("oauth.connector.tokens")
        #expect(client.calls.map(\.operation) == ["get", "update", "update", "add", "delete"])
        var contexts: [LAContext] = []
        for call in client.calls {
            let context = try #require(call.query[kSecUseAuthenticationContext as String] as? LAContext)
            #expect(context.interactionNotAllowed)
            #expect(call.query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            #expect(call.query[kSecAttrService as String] as? String == "test.noninteractive")
            #expect(call.query[kSecAttrAccount as String] as? String == "oauth.connector.tokens")
            contexts.append(context)
        }
        #expect(Set(contexts.map(ObjectIdentifier.init)).count == client.calls.count)
        let created = try #require(client.calls.first { $0.operation == "add" })
        #expect(created.query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(created.query[kSecValueData as String] as? Data == client.data)
        #expect(client.calls[1].attributes?[kSecValueData as String] as? Data == client.data)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func unavailableSecretsStayErrorsAndNeverFallBackToCreation(status: OSStatus) {
        let client = RecordingSecurity()
        let store = KeychainSecretStore(security: client)
        client.copyStatus = status
        expectStatus(status) { _ = try store.get("oauth.connector.tokens") }
        client.updateStatus = status
        expectStatus(status) { try store.set("provider-secret", for: "oauth.connector.tokens") }
        #expect(!client.calls.contains { $0.operation == "add" })
        client.updateStatus = errSecItemNotFound
        client.addStatus = status
        expectStatus(status) { try store.set("provider-secret", for: "oauth.connector.tokens") }
        client.deleteStatus = status
        expectStatus(status) { try store.delete("oauth.connector.tokens") }
        #expect(client.calls.map(\.operation) == ["get", "update", "update", "add", "delete"])
    }

    @Test func onlyItemNotFoundIsAnAbsentSecret() throws {
        let client = RecordingSecurity()
        let store = KeychainSecretStore(security: client)
        client.copyStatus = errSecItemNotFound
        #expect(try store.get("oauth.connector.tokens") == nil)
        client.deleteStatus = errSecItemNotFound
        try store.delete("oauth.connector.tokens")
        #expect(client.calls.map(\.operation) == ["get", "delete"])
    }

    private func expectStatus(_ status: OSStatus, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected Keychain failure \(status)")
        } catch let error as KeychainSecretStore.KeychainError {
            #expect(error.status == status)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
