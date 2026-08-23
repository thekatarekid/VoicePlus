import Foundation
import Testing
import Shared
@testable import Providers

@Suite(.serialized) struct OAuthTests {
    @Test func pkceRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(p.method == "S256")
    }

    @Test func pkceRandomVerifierShape() {
        let a = PKCE(), b = PKCE()
        #expect(a.verifier != b.verifier)
        #expect(a.verifier.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(a.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    }

    @Test func authorizationURLCarriesPKCEAndState() {
        let s = OAuthSession(config: .chatGPT, secrets: InMemorySecretStore())
        let url = s.authorizationURL(pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), state: "st", redirectURI: "http://localhost:1455/auth/callback")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["code_challenge_method"] == "S256" && q["state"] == "st" && q["response_type"] == "code")
        #expect(q["scope"]?.contains("offline_access") == true)
    }

    /// End-to-end with a mock IdP: loopback listener, simulated browser redirect, stubbed token endpoint.
    @Test func signInFlowWithMockIdP() async throws {
        StubURLProtocol.register(host: "idp-signin.test") { _ in
            (200, Data(#"{"access_token":"AT1","refresh_token":"RT1","expires_in":3600}"#.utf8), [:])
        }
        let cfg = OAuthConfig(authorizationURL: URL(string: "https://idp-signin.test/authorize")!, tokenURL: URL(string: "https://idp-signin.test/token")!,
                              clientID: "cid", scopes: ["openid"], redirectPort: 0)
        let secrets = InMemorySecretStore()
        let s = OAuthSession(config: cfg, secrets: secrets, session: StubURLProtocol.session(), secretKey: "oauth.test")
        let tokens = try await s.signIn(openURL: { authURL in
            // Simulated browser: read redirect_uri + state from the auth URL and hit the loopback.
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            let cb = URL(string: "\(q["redirect_uri"]!)?code=abc123&state=\(q["state"]!)")!
            Task.detached { _ = try? await URLSession.shared.data(from: cb) }
        }, timeout: 10)
        #expect(tokens.accessToken == "AT1" && tokens.refreshToken == "RT1")
        let form = String(decoding: StubURLProtocol.lastRequest(host: "idp-signin.test")?.bodyData ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=authorization_code") && form.contains("code=abc123") && form.contains("code_verifier="))
        #expect(s.isSignedIn && s.storedTokens() == tokens)
        #expect(try await s.accessToken() == "AT1")
        try s.signOut()
        #expect(!s.isSignedIn)
    }

    @Test func stateMismatchRejected() async throws {
        let cfg = OAuthConfig(authorizationURL: URL(string: "https://idp.test/a")!, tokenURL: URL(string: "https://idp.test/t")!, clientID: "c", scopes: [], redirectPort: 0)
        let s = OAuthSession(config: cfg, secrets: InMemorySecretStore(), session: StubURLProtocol.session(), secretKey: "oauth.test2")
        await #expect(throws: ProviderError.unauthorized) {
            try await s.signIn(openURL: { authURL in
                let q = Dictionary(uniqueKeysWithValues: URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                let cb = URL(string: "\(q["redirect_uri"]!)?code=x&state=WRONG")!
                Task.detached { _ = try? await URLSession.shared.data(from: cb) }
            }, timeout: 10)
        }
    }

    @Test func refreshWhenExpiredAndPreservesRefreshToken() async throws {
        StubURLProtocol.register(host: "idp-refresh.test") { _ in (200, Data(#"{"access_token":"AT2","expires_in":120}"#.utf8), [:]) }
        let cfg = OAuthConfig(authorizationURL: URL(string: "https://idp-refresh.test/a")!, tokenURL: URL(string: "https://idp-refresh.test/token")!, clientID: "c", scopes: [])
        let s = OAuthSession(config: cfg, secrets: InMemorySecretStore(), session: StubURLProtocol.session(), secretKey: "oauth.test3")
        try s.store(OAuthTokens(accessToken: "AT1", refreshToken: "RT1", expiresAt: Date().addingTimeInterval(-10)))
        #expect(try await s.accessToken() == "AT2")
        let form = String(decoding: StubURLProtocol.lastRequest(host: "idp-refresh.test")?.bodyData ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token") && form.contains("refresh_token=RT1"))
        #expect(s.storedTokens()?.refreshToken == "RT1")
        #expect(s.storedTokens()?.isExpired == false)
    }

    @Test func refreshFailureIsUnauthorized() async throws {
        StubURLProtocol.register(host: "idp-bad.test") { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8), [:]) }
        let cfg = OAuthConfig(authorizationURL: URL(string: "https://idp-bad.test/a")!, tokenURL: URL(string: "https://idp-bad.test/token")!, clientID: "c", scopes: [])
        let s = OAuthSession(config: cfg, secrets: InMemorySecretStore(), session: StubURLProtocol.session(), secretKey: "oauth.test4")
        try s.store(OAuthTokens(accessToken: "AT1", refreshToken: "RT1", expiresAt: .distantPast))
        await #expect(throws: ProviderError.unauthorized) { _ = try await s.accessToken() }
    }

    @Test func chatGPTProviderIsPipelineOnlyAndSendsAccountHeader() async throws {
        let claims = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-42"}}"#
        let jwt = "h." + PKCE.base64URL(Data(claims.utf8)) + ".sig"
        StubURLProtocol.register(host: "chatgpt.com") { _ in (200, sse(["Hello kothari there"], responses: true), [:]) }
        let s = OAuthSession(config: .chatGPT, secrets: InMemorySecretStore(), session: StubURLProtocol.session(), secretKey: "oauth.test5")
        try s.store(OAuthTokens(accessToken: jwt, refreshToken: "r", expiresAt: .distantFuture))
        let p = ChatGPTSubscriptionProvider(oauth: s, session: StubURLProtocol.session())
        #expect(!p.capabilities.contains(.asr) && p.costClass == .subscription)
        #expect(await p.isAvailable())
        try await assertConformance(p)
        let req = try #require(StubURLProtocol.lastRequest(host: "chatgpt.com"))
        #expect(req.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-42")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
    }
}
