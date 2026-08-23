import Foundation
import Testing
import Shared
@testable import Actions

@Suite("P4.6 GitHub connector")
struct ConnectorsGitHubTests {
    func make(signedIn: Bool = true, responses: [MockHTTPTransport.Response] = [.init()]) -> (GitHubConnector, ConnectorHarness) {
        let h = ConnectorHarness(config: GitHubConnector.placeholderConfig, key: GitHubConnector.secretKey, signedIn: signedIn, responses: responses)
        return (GitHubConnector(client: h.client("github")), h)
    }
    let target = ActionTarget(service: "github")

    @Test func scopesAndCapabilities() {
        let (c, _) = make()
        #expect(c.scopes == ["repo"] && c.capabilities == [.create, .comment, .search])
    }

    @Test func matching() {
        let (c, _) = make()
        #expect(c.matches(ActionTarget(urlHost: "github.com")))
        #expect(c.matches(ActionTarget(urlHost: "gist.github.com")))
        #expect(c.matches(ActionTarget(bundleID: "com.github.GitHubClient")))
        #expect(!c.matches(ActionTarget(urlHost: "githubusercontent.com")))
    }

    @Test func repoAndNumberParsing() {
        let a = ConnectorAction(kind: .comment, target: target, fields: ["url": "https://github.com/acme/widgets/pull/17/files"])
        #expect(GitHubConnector.repo(from: a) == "acme/widgets" && GitHubConnector.number(from: a) == 17)
        let b = ConnectorAction(kind: .comment, target: target, fields: ["repo": "acme/widgets", "parentID": "#9"])
        #expect(GitHubConnector.repo(from: b) == "acme/widgets" && GitHubConnector.number(from: b) == 9)
        #expect(GitHubConnector.repo(from: ConnectorAction(kind: .comment, target: target, fields: ["repo": "bad"])) == nil)
    }

    @Test func createIssueShapesRequest() async throws {
        let (c, h) = make(responses: [.init(json: #"{"number":5,"html_url":"https://github.com/acme/widgets/issues/5"}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .create, target: target, text: "Steps...", fields: ["title": "Crash on launch", "repo": "acme/widgets"]))))
        #expect(r.id == "5" && r.undoHint == "closeIssue:acme/widgets#5")
        let req = h.transport.requests[0]
        #expect(req.httpMethod == "POST" && req.url?.path == "/repos/acme/widgets/issues")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(h.transport.jsonBody(0)["title"] as? String == "Crash on launch" && h.transport.jsonBody(0)["body"] as? String == "Steps...")
    }

    @Test func createWithoutRepoFallsBack() async throws {
        let (c, h) = make()
        #expect(fallback(try await c.perform(.init(kind: .create, target: target, text: "T"))) == "no repository")
        #expect(fallback(try await c.perform(.init(kind: .create, target: ActionTarget(service: "gmail"), text: "T"))) != nil)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func commentOnPRFromURL() async throws {
        let (c, h) = make(responses: [.init(json: #"{"id":777,"html_url":"u"}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .comment, target: target, text: "Looks good", fields: ["url": "https://github.com/acme/widgets/pull/17"]))))
        #expect(r.id == "777" && r.undoHint == "deleteComment:acme/widgets/777")
        #expect(h.transport.requests[0].url?.path == "/repos/acme/widgets/issues/17/comments")
        #expect(h.transport.jsonBody(0)["body"] as? String == "Looks good")
    }

    @Test func commentWithoutNumberFallsBack() async throws {
        let (c, _) = make()
        #expect(fallback(try await c.perform(.init(kind: .comment, target: target, text: "x", fields: ["repo": "a/b"]))) != nil)
    }

    @Test func searchScopesToRepo() async throws {
        let (c, h) = make(responses: [.init(json: #"{"items":[{"number":1,"title":"Bug"}]}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .search, target: target, text: "flaky test", fields: ["repo": "acme/widgets"]))))
        #expect(r.items == ["#1: Bug"])
        let q = URLComponents(url: h.transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "flaky test repo:acme/widgets" && h.transport.requests[0].httpMethod == "GET")
    }

    @Test func egressLogged() async throws {
        let (c, h) = make(responses: [.init(json: #"{"items":[]}"#)])
        _ = try await c.perform(.init(kind: .search, target: target, text: "q"))
        #expect(h.log.count == 1 && h.log[0].host == "api.github.com" && h.log[0].provider == "github" && h.log[0].purpose == "github.search")
    }

    @Test func patStoredInSecretStoreAndUsedAsBearer() async throws {
        let (c, h) = make(signedIn: false, responses: [.init(json: #"{"items":[]}"#)])
        #expect(throws: ConnectorError.self) { try GitHubAuth.storePAT("not-a-token", in: h.oauth) }
        try GitHubAuth.storePAT(" ghp_abc123\n", in: h.oauth)
        #expect(h.secrets.values(contain: "ghp_abc123"))
        _ = try await c.perform(.init(kind: .search, target: target, text: "q"))
        #expect(h.transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer ghp_abc123")
    }

    @Test func deviceFlowPollsUntilApproved() async throws {
        let h = ConnectorHarness(config: GitHubConnector.placeholderConfig, key: GitHubConnector.secretKey, signedIn: false, responses: [
            .init(json: #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":1,"expires_in":900}"#),
            .init(json: #"{"error":"authorization_pending"}"#),
            .init(json: #"{"error":"slow_down"}"#),
            .init(json: #"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#),
        ])
        let slept = SleepLog()
        let flow = GitHubDeviceFlow(oauth: h.oauth, clientID: "cid", sleep: { await slept.add($0) })
        let p = try await flow.start()
        #expect(p.userCode == "ABCD-1234" && flow.scope == "repo")
        #expect(h.transport.jsonBody(0)["scope"] as? String == "repo")
        let t = try await flow.poll(p)
        #expect(t.accessToken == "gho_x" && h.oauth.isSignedIn)
        #expect(await slept.values == [1, 6])
        #expect(h.transport.jsonBody(1)["grant_type"] as? String == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(GitHubDeviceFlow(oauth: h.oauth, clientID: "c", publicOnly: true).scope == "public_repo")
    }

    @Test func deviceFlowDeniedThrows() async throws {
        let h = ConnectorHarness(config: GitHubConnector.placeholderConfig, key: GitHubConnector.secretKey, signedIn: false,
                                 responses: [.init(json: #"{"error":"access_denied"}"#)])
        let flow = GitHubDeviceFlow(oauth: h.oauth, clientID: "cid", sleep: { _ in })
        let p = GitHubDeviceFlow.Pending(deviceCode: "d", userCode: "u", verificationURL: "v", interval: 1, expiresAt: .distantFuture)
        await #expect(throws: ConnectorError.unauthorized) { _ = try await flow.poll(p) }
        #expect(!h.oauth.isSignedIn)
    }
}

actor SleepLog { var values: [TimeInterval] = []; func add(_ v: TimeInterval) { values.append(v) } }

extension InMemoryConnectorSecretStore {
    func values(contain s: String) -> Bool { (try? get(GitHubConnector.secretKey))?.contains(s) == true }
}
