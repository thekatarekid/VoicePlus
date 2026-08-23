import Foundation
import Shared

/// Slack Web API connector. Scopes are the minimum for send / thread reply / search.
public struct SlackConnector: Connector {
    public static let scopes = ["chat:write", "search:read"]
    public static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]
    public static let hosts: Set<String> = ["slack.com", "app.slack.com"]
    public static func oauthConfig(clientID: String) -> ConnectorOAuthConfig {
        ConnectorOAuthConfig(authorizationURL: URL(string: "https://slack.com/oauth/v2/authorize")!,
                             tokenURL: URL(string: "https://slack.com/api/oauth.v2.access")!,
                             clientID: clientID, scopes: scopes, extraAuthParams: ["user_scope": scopes.joined(separator: ",")])
    }

    public let client: ConnectorClient
    public let baseURL: URL
    public init(client: ConnectorClient, baseURL: URL = URL(string: "https://slack.com/api")!) { self.client = client; self.baseURL = baseURL }

    public var id: String { "connector.slack" }
    public var displayName: String { "Slack" }
    public var capabilities: Set<ConnectorCapability> { [.send, .comment, .search] }
    public var scopes: [String] { Self.scopes }
    public var isSignedIn: Bool { client.oauth.isSignedIn }

    public func matches(_ t: ActionTarget) -> Bool {
        t.service == "slack" || Self.bundleIDs.contains(t.bundleID ?? "") || Self.hosts.contains { h in t.urlHost == h || t.urlHost?.hasSuffix("." + h) == true }
    }

    public func perform(_ a: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: a) { return fb }
        switch a.kind {
        case .send, .comment:
            guard let channel = a["channel"], !a.text.isEmpty else { return .fallbackToUI(reason: "no channel resolved") }
            var body: [String: Any] = ["channel": channel, "text": a.text]
            if a.kind == .comment { guard let ts = a["threadID"] else { return .fallbackToUI(reason: "no thread resolved") }; body["thread_ts"] = ts }
            let r = try await call("chat.postMessage", json: body, purpose: a.kind == .send ? "slack.send" : "slack.reply")
            let ts = r["ts"] as? String
            return .performed(.init(id: ts, summary: "Sent to \(channel)", undoHint: ts.map { "chat.delete channel=\(channel) ts=\($0)" }))
        case .search:
            let q = a["query"] ?? a.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            var c = URLComponents(url: baseURL.appendingPathComponent("search.messages"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "query", value: q), .init(name: "count", value: "10")]
            let r = try await client.send(try client.request("GET", c.url!), purpose: "slack.search")
            try ok(r)
            let matches = ((r["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
            return .performed(.init(summary: "\(matches.count) results", items: matches.compactMap { $0["text"] as? String }))
        default: return .fallbackToUI(reason: "unsupported")
        }
    }

    private func call(_ method: String, json: [String: Any], purpose: String) async throws -> [String: Any] {
        let r = try await client.send(try client.request("POST", baseURL.appendingPathComponent(method), json: json), purpose: purpose)
        try ok(r); return r
    }
    /// Slack returns HTTP 200 with `ok:false` on errors.
    private func ok(_ r: [String: Any]) throws {
        if (r["ok"] as? Bool) == false {
            let e = r["error"] as? String ?? "unknown"
            throw e.contains("auth") || e == "token_revoked" || e == "invalid_auth" ? ConnectorError.unauthorized : .http(200, e)
        }
    }
}
