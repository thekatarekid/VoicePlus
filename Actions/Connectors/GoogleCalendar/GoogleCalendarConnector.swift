import Foundation
import Shared

/// Google Calendar connector: create events, search events. `calendar.events` is the minimal read/write scope.
public struct GoogleCalendarConnector: Connector {
    public static let scopes = ["https://www.googleapis.com/auth/calendar.events"]
    public static let hosts: Set<String> = ["calendar.google.com"]
    public static func oauthConfig(clientID: String) -> ConnectorOAuthConfig { GoogleOAuth.config(clientID: clientID, scopes: scopes) }

    public let client: ConnectorClient
    public let baseURL: URL
    public let timeZone: String
    public init(client: ConnectorClient, baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!,
                timeZone: String = TimeZone.current.identifier) {
        self.client = client; self.baseURL = baseURL; self.timeZone = timeZone
    }

    public var id: String { "connector.googlecalendar" }
    public var displayName: String { "Google Calendar" }
    public var capabilities: Set<ConnectorCapability> { [.create, .search] }
    public var scopes: [String] { Self.scopes }
    public var isSignedIn: Bool { client.oauth.isSignedIn }

    public func matches(_ t: ActionTarget) -> Bool {
        t.service == "calendar" || t.service == "google calendar" || Self.hosts.contains(t.urlHost ?? "")
    }

    public func perform(_ a: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: a) { return fb }
        switch a.kind {
        case .create:
            guard let start = a["start"], let end = a["end"] else { return .fallbackToUI(reason: "no start/end resolved") }
            var ev: [String: Any] = ["summary": a["title"] ?? a.text, "start": ["dateTime": start, "timeZone": timeZone],
                                     "end": ["dateTime": end, "timeZone": timeZone]]
            if a["title"] != nil, !a.text.isEmpty { ev["description"] = a.text }
            if let att = a["attendees"], !att.isEmpty { ev["attendees"] = att.split(separator: ",").map { ["email": $0.trimmingCharacters(in: .whitespaces)] } }
            let r = try await client.send(try client.request("POST", baseURL.appendingPathComponent("events"), json: ev), purpose: "calendar.create")
            let id = r["id"] as? String
            return .performed(.init(id: id, url: r["htmlLink"] as? String, summary: "Event created", undoHint: id.map { "DELETE events/\($0)" }))
        case .search:
            let q = a["query"] ?? a.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            var c = URLComponents(url: baseURL.appendingPathComponent("events"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "q", value: q), .init(name: "maxResults", value: "10"), .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime")]
            let r = try await client.send(try client.request("GET", c.url!), purpose: "calendar.search")
            let items = ((r["items"] as? [[String: Any]]) ?? []).compactMap { $0["summary"] as? String }
            return .performed(.init(summary: "\(items.count) events", items: items))
        default: return .fallbackToUI(reason: "unsupported")
        }
    }
}
