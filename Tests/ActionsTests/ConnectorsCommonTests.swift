import Foundation
import Shared
import Testing
@testable import Actions

private let cfg = ConnectorOAuthConfig(authorizationURL: URL(string: "https://x.test/auth")!, tokenURL: URL(string: "https://x.test/token")!,
                                       clientID: "cid", scopes: ["a", "b"], extraAuthParams: ["access_type": "offline"])

@Suite struct ConnectorsCommonTests {
    @Test func pkceChallengeIsS256OfVerifier() {
        let p = ConnectorPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")   // RFC 7636 appendix B
        #expect(ConnectorPKCE().verifier.count == 43)
    }

    @Test func authorizationURLCarriesPKCEScopesAndExtras() {
        let h = ConnectorAHarness(config: cfg, key: "k")
        let u = h.oauth.authorizationURL(pkce: ConnectorPKCE(verifier: "v"), state: "s1")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(q["scope"] == "a b" && q["code_challenge_method"] == "S256" && q["state"] == "s1" && q["access_type"] == "offline" && q["client_id"] == "cid")
    }

    @Test func signInExchangesCodeWithVerifierAndStores() async throws {
        let h = ConnectorAHarness(responses: [.init(json: #"{"access_token":"A","refresh_token":"R","expires_in":100}"#)], config: cfg, key: "k", signedIn: false)
        let seen = InMemoryConnectorSecretStore()
        let t = try await h.oauth.signIn(openURL: { u in
            try! seen.set(URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!, for: "state")
        }, codeReceiver: { ("code123", try seen.get("state") ?? "") })
        #expect(t.accessToken == "A" && t.refreshToken == "R")
        let body = String(decoding: h.transport.requests[0].httpBody!, as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code") && body.contains("code=code123") && body.contains("code_verifier="))
        #expect(h.oauth.storedTokens()?.accessToken == "A")
    }

    @Test func signInRejectsStateMismatch() async {
        let h = ConnectorAHarness(config: cfg, key: "k", signedIn: false)
        await #expect(throws: ConnectorError.unauthorized) { try await h.oauth.signIn(openURL: { _ in }, codeReceiver: { ("c", "wrong") }) }
    }

    @Test func accessTokenRefreshesNearExpiry() async throws {
        let h = ConnectorAHarness(responses: [.init(json: #"{"access_token":"A2","expires_in":3600}"#)], config: cfg, key: "k", expired: true)
        #expect(try await h.oauth.accessToken() == "A2")
        let body = String(decoding: h.transport.requests[0].httpBody!, as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=rt1"))
        #expect(h.oauth.storedTokens()?.refreshToken == "rt1")   // kept when omitted from response
    }

    @Test func clientRetriesOnceAfter401ViaRefresh() async throws {
        let h = ConnectorAHarness(responses: [.init(status: 401, json: "{}"), .init(json: #"{"access_token":"A2"}"#), .init(json: #"{"ok":true}"#)], config: cfg, key: "k")
        let c = h.client("p")
        let r = try await c.send(try c.request("POST", URL(string: "https://api.test/x")!, json: ["a": 1]), purpose: "t")
        #expect(r["ok"] as? Bool == true)
        #expect(h.transport.requests.count == 3)
        #expect(h.transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer A2")
        #expect(h.log.count == 2 && h.log.allSatisfy { $0.host == "api.test" && $0.stage == "act.connector" })
    }

    @Test func clientLogsEgressBytesAndPurpose() async throws {
        let h = ConnectorAHarness(responses: [.init(json: #"{"x":1}"#)], config: cfg, key: "k")
        let c = h.client("p")
        _ = try await c.send(try c.request("POST", URL(string: "https://api.test/x")!, json: ["k": "v"]), purpose: "why")
        let l = try #require(h.log.first)
        #expect(l.provider == "p" && l.purpose == "why" && l.bytesOut == #"{"k":"v"}"#.utf8.count && l.bytesIn == 7)
    }

    @Test func clientThrowsNotSignedIn() async {
        let h = ConnectorAHarness(config: cfg, key: "k", signedIn: false)
        let c = h.client("p")
        await #expect(throws: ConnectorError.notSignedIn) { _ = try await c.send(URLRequest(url: URL(string: "https://a.test")!), purpose: "t") }
        #expect(h.transport.requests.isEmpty)
    }

    @Test func registryRoutesOrFallsBack() async throws {
        let h = ConnectorAHarness(responses: [.init(json: #"{"ok":true,"ts":"1.2"}"#)], config: cfg, key: "k")
        let reg = ConnectorRegistry([SlackConnector(client: h.client("s"))])
        #expect(fallback(try await reg.perform(.init(kind: .send, target: .init(service: "notion"), text: "x"))) == "no connector for target")
        #expect(performed(try await reg.perform(.init(kind: .send, target: .init(service: "Slack"), text: "x", fields: ["channel": "C1"])))?.id == "1.2")
    }
}
