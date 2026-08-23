import Foundation
import Testing
@testable import Actions

private func harness(_ r: [MockHTTPTransport.Response] = [.init(json: #"{"id":"m1"}"#)], signedIn: Bool = true, expired: Bool = false) -> (ConnectorAHarness, GmailConnector) {
    let h = ConnectorAHarness(responses: r, config: GmailConnector.oauthConfig(clientID: "c"), key: "gmail", signedIn: signedIn, expired: expired)
    return (h, GmailConnector(client: h.client("connector.gmail")))
}
private let gmail = ActionTarget(service: "gmail")

@Suite struct ConnectorsGmailTests {
    @Test func scopesAreMinimalGoogleOffline() {
        let (_, g) = harness()
        #expect(g.scopes.count == 3 && g.scopes.allSatisfy { $0.hasPrefix("https://www.googleapis.com/auth/gmail.") })
        let cfg = GmailConnector.oauthConfig(clientID: "c")
        #expect(cfg.extraAuthParams["access_type"] == "offline" && cfg.tokenURL.host == "oauth2.googleapis.com")
    }

    @Test func sendEncodesRFC2822Raw() async throws {
        let (h, g) = harness()
        let r = try await g.perform(.init(kind: .send, target: gmail, text: "body here", fields: ["to": "a@b.c", "subject": "Hi"]))
        let req = h.transport.requests[0]
        #expect(req.httpMethod == "POST" && req.url?.path.hasSuffix("/messages/send") == true)
        let raw = try #require(h.transport.jsonBody(0)["raw"] as? String)
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let mime = String(decoding: Data(base64Encoded: b64)!, as: UTF8.self)
        #expect(mime.contains("To: a@b.c\r\nSubject: Hi") && mime.hasSuffix("\r\n\r\nbody here"))
        #expect(performed(r)?.id == "m1")
    }

    @Test func draftWrapsMessageAndOffersUndo() async throws {
        let (h, g) = harness([.init(json: #"{"id":"d9"}"#)])
        let r = try await g.perform(.init(kind: .draft, target: gmail, text: "x", fields: ["to": "a@b.c"]))
        #expect(h.transport.requests[0].url?.path.hasSuffix("/drafts") == true)
        #expect((h.transport.jsonBody(0)["message"] as? [String: Any])?["raw"] != nil)
        #expect(performed(r)?.undoHint == "DELETE drafts/d9")
    }

    @Test func replyCarriesThreadID() async throws {
        let (h, g) = harness()
        _ = try await g.perform(.init(kind: .send, target: gmail, text: "x", fields: ["to": "a@b.c", "threadID": "t7"]))
        #expect(h.transport.jsonBody(0)["threadId"] as? String == "t7")
    }

    @Test func searchShapesQuery() async throws {
        let (h, g) = harness([.init(json: #"{"messages":[{"id":"1"},{"id":"2"}]}"#)])
        let r = try await g.perform(.init(kind: .search, target: gmail, fields: ["query": "from:bob"]))
        #expect(h.transport.requests[0].httpMethod == "GET" && h.transport.requests[0].url?.query?.contains("q=from:bob") == true)
        #expect(performed(r)?.items == ["1", "2"])
    }

    @Test func fallbackCases() async throws {
        let (h, g) = harness()
        #expect(fallback(try await g.perform(.init(kind: .send, target: .init(service: "slack"), text: "x", fields: ["to": "a"]))) != nil)
        #expect(fallback(try await g.perform(.init(kind: .comment, target: gmail, text: "x"))) != nil)
        #expect(fallback(try await g.perform(.init(kind: .send, target: gmail, text: "x"))) == "no recipient resolved")
        #expect(h.transport.requests.isEmpty)
    }

    @Test func fallbackWhenNotSignedIn() async throws {
        let (_, g) = harness(signedIn: false)
        #expect(fallback(try await g.perform(.init(kind: .draft, target: gmail, text: "x", fields: ["to": "a"]))) != nil)
    }

    @Test func matchesWebHost() {
        let (_, g) = harness()
        #expect(g.matches(.init(urlHost: "mail.google.com")) && !g.matches(.init(urlHost: "calendar.google.com")))
    }

    @Test func refreshesExpiredToken() async throws {
        let (h, g) = harness([.init(json: #"{"access_token":"fresh","expires_in":3600}"#), .init(json: #"{"id":"m"}"#)], expired: true)
        _ = try await g.perform(.init(kind: .send, target: gmail, text: "x", fields: ["to": "a"]))
        #expect(h.transport.requests[0].url?.host == "oauth2.googleapis.com")
        #expect(h.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func egressLogged() async throws {
        let (h, g) = harness()
        _ = try await g.perform(.init(kind: .send, target: gmail, text: "x", fields: ["to": "a"]))
        #expect(h.log.count == 1 && h.log[0].host == "gmail.googleapis.com" && h.log[0].purpose == "gmail.send" && h.log[0].bytesOut > 0)
    }
}
