import Foundation
import Testing
import Shared
@testable import Actions

@Suite("P4.6 Linear connector")
struct ConnectorsLinearTests {
    func make(signedIn: Bool = true, responses: [MockHTTPTransport.Response] = [.init()]) -> (LinearConnector, ConnectorHarness) {
        let h = ConnectorHarness(config: LinearConnector.oauthConfig, key: LinearConnector.secretKey, signedIn: signedIn, responses: responses)
        return (LinearConnector(client: h.client("linear")), h)
    }
    let target = ActionTarget(service: "linear")

    @Test func scopesAreMinimal() {
        let (c, _) = make()
        #expect(Set(c.scopes) == ["read", "issues:create", "comments:create"])
        #expect(!c.scopes.contains("write") && !c.scopes.contains("admin"))
        #expect(c.capabilities == [.create, .comment, .search])
    }

    @Test func matchesByServiceHostAndBundle() {
        let (c, _) = make()
        #expect(c.matches(ActionTarget(service: "Linear")))
        #expect(c.matches(ActionTarget(urlHost: "linear.app")))
        #expect(c.matches(ActionTarget(bundleID: "com.linear.Linear")))
        #expect(!c.matches(ActionTarget(service: "slack", urlHost: "slack.com")))
    }

    @Test func wrongTargetOrSignedOutFallsBack() async throws {
        let (c, _) = make()
        #expect(fallback(try await c.perform(.init(kind: .create, target: ActionTarget(service: "notion"), text: "x"))) != nil)
        let (out, _) = make(signedIn: false)
        #expect(fallback(try await out.perform(.init(kind: .create, target: target, text: "x"))) == "Linear not signed in")
        #expect(fallback(try await c.perform(.init(kind: .send, target: target, text: "x"))) != nil)
    }

    @Test func createIssueResolvesTeamKeyAndShapesMutation() async throws {
        let (c, h) = make(responses: [
            .init(json: #"{"data":{"teams":{"nodes":[{"id":"11111111-1111-1111-1111-111111111111","key":"ENG","name":"Engineering"}]}}}"#),
            .init(json: #"{"data":{"issueCreate":{"success":true,"issue":{"id":"iss1","identifier":"ENG-42","url":"https://linear.app/x/issue/ENG-42"}}}}"#),
        ])
        let r = try #require(performed(try await c.perform(.init(kind: .create, target: target, text: "Details here", fields: ["title": "Fix login", "team": "eng"]))))
        #expect(r.id == "iss1" && r.url?.contains("ENG-42") == true && r.undoHint == "issueArchive:iss1")
        #expect(h.transport.requests.count == 2)
        let vars = h.transport.jsonBody(1)["variables"] as? [String: Any]
        let input = vars?["input"] as? [String: Any]
        #expect(input?["teamId"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(input?["title"] as? String == "Fix login" && input?["description"] as? String == "Details here")
        #expect(h.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(h.transport.requests[1].url == LinearConnector.graphQLURL)
    }

    @Test func createWithoutTeamOrTitleFallsBack() async throws {
        let (c, h) = make()
        #expect(fallback(try await c.perform(.init(kind: .create, target: target, text: "", fields: ["team": "ENG"]))) == "no issue title")
        #expect(fallback(try await c.perform(.init(kind: .create, target: target, text: "Title"))) == "no Linear team")
        #expect(h.transport.requests.isEmpty)
    }

    @Test func commentResolvesIdentifierThenCreates() async throws {
        let (c, h) = make(responses: [
            .init(json: #"{"data":{"issue":{"id":"uuid-issue"}}}"#),
            .init(json: #"{"data":{"commentCreate":{"success":true,"comment":{"id":"c9","url":"u"}}}}"#),
        ])
        let r = try #require(performed(try await c.perform(.init(kind: .comment, target: target, text: "LGTM", fields: ["parentID": "ENG-7"]))))
        #expect(r.id == "c9" && r.undoHint == "commentDelete:c9")
        let input = (h.transport.jsonBody(1)["variables"] as? [String: Any])?["input"] as? [String: Any]
        #expect(input?["issueId"] as? String == "uuid-issue" && input?["body"] as? String == "LGTM")
        #expect((h.transport.jsonBody(0)["variables"] as? [String: Any])?["id"] as? String == "ENG-7")
    }

    @Test func commentWithUUIDSkipsResolve() async throws {
        let (c, h) = make(responses: [.init(json: #"{"data":{"commentCreate":{"comment":{"id":"c1"}}}}"#)])
        _ = try await c.perform(.init(kind: .comment, target: target, text: "hi", fields: ["parentID": "22222222-2222-2222-2222-222222222222"]))
        #expect(h.transport.requests.count == 1)
    }

    @Test func searchListsIdentifiers() async throws {
        let (c, _) = make(responses: [.init(json: #"{"data":{"searchIssues":{"nodes":[{"identifier":"ENG-1","title":"A"},{"identifier":"ENG-2","title":"B"}]}}}"#)])
        let r = try #require(performed(try await c.perform(.init(kind: .search, target: target, text: "login"))))
        #expect(r.items == ["ENG-1: A", "ENG-2: B"])
    }

    @Test func graphQLErrorsSurfaceAsThrow() async throws {
        let (c, _) = make(responses: [.init(json: #"{"errors":[{"message":"Access denied"}]}"#)])
        await #expect(throws: ConnectorError.http(200, "Access denied")) {
            _ = try await c.perform(.init(kind: .search, target: target, text: "x"))
        }
    }

    @Test func everyCallIsLoggedToDataPanel() async throws {
        let (c, h) = make(responses: [.init(json: #"{"data":{"teams":{"nodes":[{"id":"t","key":"ENG"}]}}}"#),
                                      .init(json: #"{"data":{"issueCreate":{"issue":{"id":"i"}}}}"#)])
        _ = try await c.perform(.init(kind: .create, target: target, text: "T", fields: ["team": "ENG"]))
        #expect(h.log.count == 2)
        #expect(h.log.allSatisfy { $0.host == "api.linear.app" && $0.provider == "linear" && $0.stage == "act.connector" && $0.bytesOut > 0 })
        #expect(h.log.map(\.purpose) == ["linear.teams", "linear.issueCreate"])
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        let (c, h) = make(responses: [.init(status: 401, json: "{}"),
                                      .init(json: #"{"access_token":"new","expires_in":3600}"#),
                                      .init(json: #"{"data":{"searchIssues":{"nodes":[]}}}"#)])
        _ = try await c.perform(.init(kind: .search, target: target, text: "q"))
        #expect(h.transport.requests.count == 3)
        #expect(h.transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new")
        #expect(h.oauth.storedTokens()?.accessToken == "new")
    }
}
