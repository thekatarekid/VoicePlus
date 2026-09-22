import Foundation
import Providers
import Testing
@testable import VoicePlusApp

@Suite("Optional credentials never block local use")
@MainActor
struct OptionalCredentialStorageTests {
    final class LockedStore: SecretStore, @unchecked Sendable {
        struct Locked: Error {}
        var locked = true
        var writes = 0
        var deletes = 0
        func get(_ key: String) throws -> String? {
            if locked { throw Locked() }
            return "test-credential"
        }
        func set(_ value: String, for key: String) throws { writes += 1 }
        func delete(_ key: String) throws { deletes += 1 }
    }

    final class Probe: ProviderConnectivityProbing, @unchecked Sendable {
        var calls = 0
        func test(_ endpoint: APIEndpoint, key: String) async -> ProviderServiceStatus {
            calls += 1
            return .reachable
        }
    }

    @Test func unavailableStorageIsNotMistakenForMissingCredentialsOrSentToAProvider() async throws {
        let store = LockedStore()
        let probe = Probe()
        let model = ProviderCredentialsModel(secrets: store, probe: probe)
        let service = try #require(model.services.first)
        #expect(model.hasStorageFailure && !model.hasAnyKey)
        #expect(model.status(service) == .storageUnavailable)
        #expect(!model.status(service).hasKey)
        #expect(model.status(service).line.contains("Local dictation still works"))
        await model.test(service)
        #expect(probe.calls == 0 && model.status(service) == .storageUnavailable)
        model.reload()
        #expect(store.writes == 0 && store.deletes == 0)

        store.locked = false
        model.reload()
        #expect(!model.hasStorageFailure && model.hasAnyKey)
        #expect(model.status(service) == .saved)
        await model.test(service)
        #expect(probe.calls == 1 && model.status(service) == .reachable)
        #expect(store.writes == 0 && store.deletes == 0)
    }
}
