import Foundation
import Shared
@testable import Actions

/// Shared fixture for connector tests: signed-in OAuth over a mock transport with a captured Data Panel log.
final class ConnectorHarness: @unchecked Sendable {
    let transport: MockHTTPTransport
    let oauth: ConnectorOAuth
    let secrets = InMemoryConnectorSecretStore()
    private let lock = NSLock()
    private(set) var log: [NetworkLogRecord] = []

    init(config: ConnectorOAuthConfig, key: String, signedIn: Bool = true, responses: [MockHTTPTransport.Response] = [.init()]) {
        transport = MockHTTPTransport(responses)
        oauth = ConnectorOAuth(config: config, secrets: secrets, transport: transport, secretKey: key)
        if signedIn { try! oauth.store(ConnectorTokens(accessToken: "tok", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600))) }
    }

    var sink: NetworkLogSink { { [self] r in lock.lock(); log.append(r); lock.unlock() } }
    func client(_ id: String) -> ConnectorClient { ConnectorClient(providerID: id, oauth: oauth, transport: transport, log: sink) }
}

func performed(_ o: ConnectorOutcome) -> ConnectorResult? { if case .performed(let r) = o { return r }; return nil }
func fallback(_ o: ConnectorOutcome) -> String? { if case .fallbackToUI(let r) = o { return r }; return nil }
