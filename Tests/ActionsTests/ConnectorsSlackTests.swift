import Foundation
import Testing
@testable import Actions

private func harness(_ r: [MockHTTPTransport.Response] = [.init(json: #"{"ok":true,"ts":"17.5"}"#)], signedIn: Bool = true, expired: Bool = false) -> (ConnectorAHarness, SlackConnector) {
    let h = ConnectorAHarness(responses: r, config: SlackConnector.oauthConfig(clientID: "c"), key: "slack", signedIn: signedIn, expired: expired)
    return (h, SlackConnector(client: h.client("connector.slack")))
}
private let slack = ActionTarget(service: "slack")

@Suite struct ConnectorsSlackTests {
    @Test func scopesAreMinimalAndInAuthURL() {
        let (_, s) = harness()
        #expect(s.scopes == ["chat:write", "search:read"])
        let cfg = SlackConnector.oauthConfig(clientID: "c")
        #expect(cfg.extraAuthParams["user_scope"] == "chat:write,search:read" && cfg.authorizationURL.host == "slack.com")
    }

    @Test func sendShapesPostMessage() async throws {
        let (h, s) = harness()
        let r = try await s.perform(.init(kind: .send, target: slack, text: "hi team", fields: ["channel": "C123"]))
        let req = h.transport.requests[0]
        #expect(req.httpMethod == "POST" && req.url?.path == "/api/chat.postMessage")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok1")
        let b = h.transport.jsonBody(0)
        #expect(b["channel"] as? String == "C123" && b["text"] as? String == "hi team" && b["thread_ts"] == nil)
        #expect(performed(r)?.id == "17.5" && performed(r)?.undoHint?.contains("chat.delete") == true)
    }

    @Test func commentRepliesInThread() async throws {
        let (h, s) = harness()
        _ = try await s.perform(.init(kind: .comment, target: slack, text: "+1", fields: ["channel": "C1", "threadID": "1.0"]))
        #expect(h.transport.jsonBody(0)["thread_ts"] as? String == "1.0")
    }

    @Test func searchShapesQuery() async throws {
        let (h, s) = harness([.init(json: #"{"ok":true,"messages":{"matches":[{"text":"a"},{"text":"b"}]}}"#)])
        let r = try await s.perform(.init(kind: .search, target: slack, fields: ["query": "deploy failed"]))
        let u = h.transport.requests[0].url!
        #expect(u.path == "/api/search.messages" && u.query?.contains("query=deploy%20failed") == true)
        #expect(performed(r)?.items == ["a", "b"])
    }

    @Test func fallbackWhenTargetIsNotSlack() async throws {
        let (h, s) = harness()
        #expect(fallback(try await s.perform(.init(kind: .send, target: .init(service: "gmail"), text: "x", fields: ["channel": "C"]))) != nil)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func fallbackForDraftAndMissingChannel() async throws {
        let (_, s) = harness()
        #expect(fallback(try await s.perform(.init(kind: .draft, target: slack, text: "x"))) != nil)
        #expect(fallback(try await s.perform(.init(kind: .send, target: slack, text: "x"))) == "no channel resolved")
    }

    @Test func fallbackWhenNotSignedIn() async throws {
        let (_, s) = harness(signedIn: false)
        #expect(fallback(try await s.perform(.init(kind: .send, target: slack, text: "x", fields: ["channel": "C"])))?.contains("not signed in") == true)
    }

    @Test func matchesBundleAndHost() {
        let (_, s) = harness()
        #expect(s.matches(.init(bundleID: "com.tinyspeck.slackmacgap")) && s.matches(.init(urlHost: "myteam.slack.com")) && !s.matches(.init(urlHost: "mail.google.com")))
    }

    @Test func refreshesExpiredTokenBeforeSend() async throws {
        let (h, s) = harness([.init(json: #"{"access_token":"fresh"}"#), .init(json: #"{"ok":true,"ts":"1"}"#)], expired: true)
        _ = try await s.perform(.init(kind: .send, target: slack, text: "x", fields: ["channel": "C"]))
        #expect(h.transport.requests[0].url?.path == "/api/oauth.v2.access")
        #expect(h.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func okFalseBecomesError() async {
        let (_, s) = harness([.init(json: #"{"ok":false,"error":"channel_not_found"}"#)])
        await #expect(throws: ConnectorError.http(200, "channel_not_found")) {
            _ = try await s.perform(.init(kind: .send, target: slack, text: "x", fields: ["channel": "C"]))
        }
    }

    @Test func everyCallIsLogged() async throws {
        let (h, s) = harness()
        _ = try await s.perform(.init(kind: .send, target: slack, text: "x", fields: ["channel": "C"]))
        #expect(h.log.count == 1 && h.log[0].host == "slack.com" && h.log[0].purpose == "slack.send" && h.log[0].provider == "connector.slack")
    }
}
