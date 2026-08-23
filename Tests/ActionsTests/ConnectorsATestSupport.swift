import Foundation
import Shared
@testable import Actions

/// P4.6-a harness (Slack/Gmail/Calendar): adds a fixed clock + expired-token option. `performed`/`fallback` helpers live in ConnectorsTestSupport.swift.
final class ConnectorAHarness: @unchecked Sendable {
    let transport: MockHTTPTransport
    let secrets = InMemoryConnectorSecretStore()
    let oauth: ConnectorOAuth
    private let lock = NSLock(); private var _log: [NetworkLogRecord] = []
    var log: [NetworkLogRecord] { lock.lock(); defer { lock.unlock() }; return _log }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    init(responses: [MockHTTPTransport.Response] = [.init()], config: ConnectorOAuthConfig, key: String, signedIn: Bool = true, expired: Bool = false) {
        transport = MockHTTPTransport(responses)
        let n = now
        oauth = ConnectorOAuth(config: config, secrets: secrets, transport: transport, secretKey: key, now: { n })
        if signedIn {
            try! oauth.store(ConnectorTokens(accessToken: "tok1", refreshToken: "rt1", expiresAt: n.addingTimeInterval(expired ? 10 : 3600)))
        }
    }
    func client(_ id: String) -> ConnectorClient {
        ConnectorClient(providerID: id, oauth: oauth, transport: transport) { [self] r in lock.lock(); _log.append(r); lock.unlock() }
    }
}
