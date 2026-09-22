import Foundation
import LocalAuthentication
import Security
import Shared
import Testing
@testable import Sync

@Suite("Sync Keychain never authenticates interactively")
struct SyncNoninteractiveKeychainTests {
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
        let store = KeychainSyncKeyStore(service: "test.noninteractive", security: client)
        let value = Data(repeating: 7, count: 32)
        client.data = value
        #expect(try store.get("sync.masterKey") == value)
        try store.set(value, for: "sync.masterKey")
        client.updateStatus = errSecItemNotFound
        try store.set(value, for: "sync.masterKey")
        try store.delete("sync.masterKey")
        #expect(client.calls.map(\.operation) == ["get", "update", "update", "add", "delete"])
        var contexts: [LAContext] = []
        for call in client.calls {
            let context = try #require(call.query[kSecUseAuthenticationContext as String] as? LAContext)
            #expect(context.interactionNotAllowed)
            #expect(call.query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            #expect(call.query[kSecAttrService as String] as? String == "test.noninteractive")
            #expect(call.query[kSecAttrAccount as String] as? String == "sync.masterKey")
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
        let store = KeychainSyncKeyStore(security: client)
        client.copyStatus = status
        expectStatus(status) { _ = try store.get("sync.masterKey") }
        client.updateStatus = status
        expectStatus(status) { try store.set(Data(repeating: 7, count: 32), for: "sync.masterKey") }
        #expect(!client.calls.contains { $0.operation == "add" })
        client.updateStatus = errSecItemNotFound
        client.addStatus = status
        expectStatus(status) { try store.set(Data(repeating: 7, count: 32), for: "sync.masterKey") }
        client.deleteStatus = status
        expectStatus(status) { try store.delete("sync.masterKey") }
        #expect(client.calls.map(\.operation) == ["get", "update", "update", "add", "delete"])
    }

    @Test func onlyItemNotFoundIsAnAbsentSecret() throws {
        let client = RecordingSecurity()
        let store = KeychainSyncKeyStore(security: client)
        client.copyStatus = errSecItemNotFound
        #expect(try store.get("sync.masterKey") == nil)
        client.deleteStatus = errSecItemNotFound
        try store.delete("sync.masterKey")
        #expect(client.calls.map(\.operation) == ["get", "delete"])
    }

    @Test func lockedSyncKeyIsUnavailableRatherThanMissing() {
        let client = RecordingSecurity()
        client.copyStatus = errSecInteractionNotAllowed
        let store = KeychainSyncKeyStore(security: client)
        expectStatus(errSecInteractionNotAllowed) { _ = try SyncKey.load(from: store) }
        #expect(client.calls.map(\.operation) == ["get"])
    }

    private func expectStatus(_ status: OSStatus, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected Keychain failure \(status)")
        } catch let error as KeychainSyncKeyStore.KeychainError {
            #expect(error.status == status)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
