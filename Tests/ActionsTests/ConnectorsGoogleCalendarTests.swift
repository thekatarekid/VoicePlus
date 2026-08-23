import Foundation
import Testing
@testable import Actions

private func harness(_ r: [MockHTTPTransport.Response] = [.init(json: #"{"id":"e1","htmlLink":"https://cal/e1"}"#)], signedIn: Bool = true, expired: Bool = false) -> (ConnectorAHarness, GoogleCalendarConnector) {
    let h = ConnectorAHarness(responses: r, config: GoogleCalendarConnector.oauthConfig(clientID: "c"), key: "gcal", signedIn: signedIn, expired: expired)
    return (h, GoogleCalendarConnector(client: h.client("connector.googlecalendar"), timeZone: "Asia/Kolkata"))
}
private let cal = ActionTarget(service: "calendar")
private let ev = ["title": "Standup", "start": "2026-08-25T10:00:00", "end": "2026-08-25T10:30:00", "attendees": "a@x.com, b@x.com"]

@Suite struct ConnectorsGoogleCalendarTests {
    @Test func scopeIsEventsOnly() {
        let (_, c) = harness()
        #expect(c.scopes == ["https://www.googleapis.com/auth/calendar.events"])
        #expect(GoogleCalendarConnector.oauthConfig(clientID: "c").scopes == c.scopes)
    }

    @Test func createShapesEventInsert() async throws {
        let (h, c) = harness()
        let r = try await c.perform(.init(kind: .create, target: cal, text: "notes", fields: ev))
        let req = h.transport.requests[0]
        #expect(req.httpMethod == "POST" && req.url?.path == "/calendar/v3/calendars/primary/events")
        let b = h.transport.jsonBody(0)
        #expect(b["summary"] as? String == "Standup" && b["description"] as? String == "notes")
        #expect((b["start"] as? [String: String]) == ["dateTime": ev["start"]!, "timeZone": "Asia/Kolkata"])
        #expect((b["attendees"] as? [[String: String]])?.map { $0["email"]! } == ["a@x.com", "b@x.com"])
        #expect(performed(r)?.id == "e1" && performed(r)?.url == "https://cal/e1" && performed(r)?.undoHint == "DELETE events/e1")
    }

    @Test func createUsesTextAsTitleWhenMissing() async throws {
        let (h, c) = harness()
        _ = try await c.perform(.init(kind: .create, target: cal, text: "Dentist", fields: ["start": "s", "end": "e"]))
        #expect(h.transport.jsonBody(0)["summary"] as? String == "Dentist" && h.transport.jsonBody(0)["description"] == nil && h.transport.jsonBody(0)["attendees"] == nil)
    }

    @Test func searchShapesEventsList() async throws {
        let (h, c) = harness([.init(json: #"{"items":[{"summary":"A"},{"summary":"B"}]}"#)])
        let r = try await c.perform(.init(kind: .search, target: cal, text: "standup"))
        let q = h.transport.requests[0].url?.query ?? ""
        #expect(h.transport.requests[0].httpMethod == "GET" && q.contains("q=standup") && q.contains("singleEvents=true"))
        #expect(performed(r)?.items == ["A", "B"])
    }

    @Test func fallbackCases() async throws {
        let (h, c) = harness()
        #expect(fallback(try await c.perform(.init(kind: .create, target: .init(service: "slack"), fields: ev))) != nil)
        #expect(fallback(try await c.perform(.init(kind: .send, target: cal, text: "x"))) != nil)
        #expect(fallback(try await c.perform(.init(kind: .create, target: cal, fields: ["title": "x"]))) == "no start/end resolved")
        #expect(fallback(try await c.perform(.init(kind: .search, target: cal))) == "empty query")
        #expect(h.transport.requests.isEmpty)
    }

    @Test func fallbackWhenNotSignedIn() async throws {
        let (_, c) = harness(signedIn: false)
        #expect(fallback(try await c.perform(.init(kind: .create, target: cal, fields: ev))) != nil)
    }

    @Test func matchesHostAndNames() {
        let (_, c) = harness()
        #expect(c.matches(.init(urlHost: "calendar.google.com")) && c.matches(.init(service: "Google Calendar")) && !c.matches(.init(service: "gmail")))
    }

    @Test func refreshesExpiredToken() async throws {
        let (h, c) = harness([.init(json: #"{"access_token":"fresh","expires_in":3600}"#), .init(json: #"{"id":"e"}"#)], expired: true)
        _ = try await c.perform(.init(kind: .create, target: cal, fields: ev))
        #expect(h.transport.requests[0].url?.host == "oauth2.googleapis.com" && h.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func httpErrorSurfaces() async {
        let (_, c) = harness([.init(status: 403, json: #"{"error":"forbidden"}"#)])
        await #expect(throws: ConnectorError.http(403, #"{"error":"forbidden"}"#)) { _ = try await c.perform(.init(kind: .create, target: cal, fields: ev)) }
    }

    @Test func egressLogged() async throws {
        let (h, c) = harness()
        _ = try await c.perform(.init(kind: .create, target: cal, fields: ev))
        #expect(h.log.count == 1 && h.log[0].host == "www.googleapis.com" && h.log[0].purpose == "calendar.create")
    }
}
