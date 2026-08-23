import Foundation
import Testing
import Shared
@testable import Actions

@Suite("P4.6 Notion connector")
struct ConnectorsNotionTests {
    func make(signedIn: Bool = true, responses: [MockHTTPTransport.Response] = [.init()]) -> (NotionConnector, ConnectorHarness) {
        let h = ConnectorHarness(config: NotionConnector.oauthConfig, key: NotionConnector.secretKey, signedIn: signedIn, responses: responses)
        return (NotionConnector(client: h.client("notion")), h)
    }
    let target = ActionTarget(service: "notion")

    @Test func capabilitiesAndNoDeleteScope() {
        let (c, _) = make()
        #expect(c.capabilities == [.create, .comment, .search])
        #expect(!c.scopes.contains { $0.contains("update") || $0.contains("delete") })
        #expect(NotionConnector.oauthConfig.extraAuthParams["owner"] == "user")
    }

    @Test func matching() {
        let (c, _) = make()
        #expect(c.matches(ActionTarget(urlHost: "www.notion.so")))
        #expect(c.matches(ActionTarget(bundleID: "notion.id")))
        #expect(c.matches(ActionTarget(service: "NOTION")))
        #expect(!c.matches(ActionTarget(urlHost: "github.com")))
    }

    @Test func routingFallbacks() async throws {
        let (c, _) = make()
        #expect(fallback(try await c.perform(.init(kind: .create, target: ActionTarget(service: "linear"), text: "x"))) != nil)
        #expect(fallback(try await c.perform(.init(kind: .draft, target: target, text: "x"))) != nil)
        let (out, _) = make(signedIn: false)
        #expect(fallback(try await out.perform(.init(kind: .search, target: target, text: "x"))) == "Notion not signed in")
    }

    @Test func createPageUnderPage() async throws {
        let (c, h) = make(responses: [.init(json: #"{"id":"p1","url":"https://notion.so/p1"}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .create, target: target, text: "Body text", fields: ["title": "Meeting notes", "parentID": "parent1"]))))
        #expect(r.id == "p1" && r.undoHint == "archivePage:p1")
        let body = h.transport.jsonBody(0)
        #expect((body["parent"] as? [String: Any])?["page_id"] as? String == "parent1")
        let title = ((body["properties"] as? [String: Any])?["title"] as? [String: Any])?["title"] as? [[String: Any]]
        #expect((title?.first?["text"] as? [String: Any])?["content"] as? String == "Meeting notes")
        #expect((body["children"] as? [[String: Any]])?.first?["type"] as? String == "paragraph")
        let req = h.transport.requests[0]
        #expect(req.url?.path == "/v1/pages" && req.value(forHTTPHeaderField: "Notion-Version") == NotionConnector.apiVersion)
    }

    @Test func createPageInDatabaseUsesNameProperty() async throws {
        let (c, h) = make(responses: [.init(json: #"{"id":"p2"}"#)])
        _ = try await c.perform(.init(kind: .create, target: target, text: "Task", fields: ["parentID": "db1", "parentType": "database"]))
        let body = h.transport.jsonBody(0)
        #expect((body["parent"] as? [String: Any])?["database_id"] as? String == "db1")
        #expect((body["properties"] as? [String: Any])?["Name"] != nil)
        #expect(body["children"] == nil)
    }

    @Test func createWithoutParentFallsBack() async throws {
        let (c, h) = make()
        #expect(fallback(try await c.perform(.init(kind: .create, target: target, text: "T"))) == "no parent page/database")
        #expect(h.transport.requests.isEmpty)
    }

    @Test func commentOnPageAndInDiscussion() async throws {
        let (c, h) = make(responses: [.init(json: #"{"id":"c1"}"#), .init(json: #"{"id":"c2"}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .comment, target: target, text: "Nice", fields: ["parentID": "pg"]))))
        #expect(r.id == "c1")
        #expect((h.transport.jsonBody(0)["parent"] as? [String: Any])?["page_id"] as? String == "pg")
        _ = try await c.perform(.init(kind: .comment, target: target, text: "Reply", fields: ["parentID": "pg", "threadID": "disc"]))
        #expect(h.transport.jsonBody(1)["discussion_id"] as? String == "disc" && h.transport.jsonBody(1)["parent"] == nil)
        #expect(h.transport.requests.allSatisfy { $0.url?.path == "/v1/comments" })
    }

    @Test func searchExtractsTitles() async throws {
        let (c, h) = make(responses: [.init(json: #"{"results":[{"id":"a","object":"page","properties":{"title":{"title":[{"plain_text":"Road"},{"plain_text":"map"}]}}},{"id":"b","object":"database","title":[{"plain_text":"Tasks"}]}]}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .search, target: target, text: "road"))))
        #expect(r.items == ["Roadmap", "Tasks"])
        #expect(h.transport.jsonBody(0)["query"] as? String == "road")
    }

    @Test func richTextIsCappedAt2000() {
        let s = String(repeating: "a", count: 5000)
        #expect(((NotionConnector.richText(s)["text"] as? [String: Any])?["content"] as? String)?.count == 2000)
    }

    @Test func egressLoggedAndHTTPErrorsThrow() async throws {
        let (c, h) = make(responses: [.init(json: "{}"), .init(status: 403, json: #"{"message":"restricted"}"#)])
        _ = try await c.perform(.init(kind: .search, target: target, text: "a"))
        #expect(h.log.count == 1 && h.log[0].host == "api.notion.com" && h.log[0].purpose == "notion.search")
        await #expect(throws: ConnectorError.self) { _ = try await c.perform(.init(kind: .search, target: target, text: "b")) }
        #expect(h.log.count == 2)
    }

    @Test func oauthExchangeUsesBasicAuthAndStoresToken() async throws {
        let h = ConnectorHarness(config: ConnectorOAuthConfig(authorizationURL: NotionConnector.oauthConfig.authorizationURL,
                                                              tokenURL: NotionConnector.oauthConfig.tokenURL, clientID: "cid", scopes: []),
                                 key: NotionConnector.secretKey, signedIn: false,
                                 responses: [.init(json: #"{"access_token":"ntn_x","workspace_name":"W"}"#)])
        let t = try await NotionOAuth.exchange(code: "abc", clientSecret: "sec", oauth: h.oauth)
        #expect(t.accessToken == "ntn_x" && h.oauth.isSignedIn)
        let req = h.transport.requests[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("cid:sec".utf8).base64EncodedString())
        #expect(h.transport.jsonBody(0)["grant_type"] as? String == "authorization_code")
    }
}
