import Foundation
import Shared

/// Gmail REST connector: send, draft, search. No comment/create.
public struct GmailConnector: Connector {
    public static let scopes = ["https://www.googleapis.com/auth/gmail.send",
                                "https://www.googleapis.com/auth/gmail.compose",
                                "https://www.googleapis.com/auth/gmail.readonly"]
    public static let hosts: Set<String> = ["mail.google.com"]
    public static func oauthConfig(clientID: String) -> ConnectorOAuthConfig { GoogleOAuth.config(clientID: clientID, scopes: scopes) }

    public let client: ConnectorClient
    public let baseURL: URL
    public init(client: ConnectorClient, baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!) { self.client = client; self.baseURL = baseURL }

    public var id: String { "connector.gmail" }
    public var displayName: String { "Gmail" }
    public var capabilities: Set<ConnectorCapability> { [.send, .draft, .search] }
    public var scopes: [String] { Self.scopes }
    public var isSignedIn: Bool { client.oauth.isSignedIn }

    public func matches(_ t: ActionTarget) -> Bool { t.service == "gmail" || Self.hosts.contains(t.urlHost ?? "") }

    public func perform(_ a: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: a) { return fb }
        switch a.kind {
        case .send, .draft:
            guard let to = a["to"], !to.isEmpty else { return .fallbackToUI(reason: "no recipient resolved") }
            let raw = Self.rawMessage(to: to, subject: a["subject"] ?? "", body: a.text, threadID: a["threadID"])
            var msg: [String: Any] = ["raw": raw]
            if let th = a["threadID"] { msg["threadId"] = th }
            if a.kind == .send {
                let r = try await client.send(try client.request("POST", baseURL.appendingPathComponent("messages/send"), json: msg), purpose: "gmail.send")
                return .performed(.init(id: r["id"] as? String, summary: "Email sent to \(to)"))
            }
            let r = try await client.send(try client.request("POST", baseURL.appendingPathComponent("drafts"), json: ["message": msg]), purpose: "gmail.draft")
            let id = r["id"] as? String
            return .performed(.init(id: id, summary: "Draft saved for \(to)", undoHint: id.map { "DELETE drafts/\($0)" }))
        case .search:
            let q = a["query"] ?? a.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            var c = URLComponents(url: baseURL.appendingPathComponent("messages"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "q", value: q), .init(name: "maxResults", value: "10")]
            let r = try await client.send(try client.request("GET", c.url!), purpose: "gmail.search")
            let ids = ((r["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            return .performed(.init(summary: "\(ids.count) results", items: ids))
        default: return .fallbackToUI(reason: "unsupported")
        }
    }

    /// RFC 2822 message, base64url (Gmail `raw` field).
    public static func rawMessage(to: String, subject: String, body: String, threadID: String?) -> String {
        var lines = ["To: \(to)", "Subject: \(subject)", "Content-Type: text/plain; charset=utf-8", "MIME-Version: 1.0"]
        if let threadID { lines.append("In-Reply-To: \(threadID)") }
        return ConnectorPKCE.base64URL(Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8))
    }
}

/// Google OAuth endpoints shared by Gmail and Calendar (one consent per product, minimal scopes each).
public enum GoogleOAuth {
    public static func config(clientID: String, scopes: [String]) -> ConnectorOAuthConfig {
        ConnectorOAuthConfig(authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                             tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                             clientID: clientID, scopes: scopes, extraAuthParams: ["access_type": "offline", "prompt": "consent"])
    }
}
