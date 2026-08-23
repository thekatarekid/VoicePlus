import Foundation
import Shared

/// Notion public-integration OAuth (https://api.notion.com/v1/oauth/authorize, `owner=user`). Notion has no scope
/// strings — capabilities are fixed on the integration (insert content + read content + comments only; no update/delete).
/// Token exchange needs HTTP Basic (client id:secret) which `ConnectorOAuth` does not send → `NotionOAuth.exchange`.
public struct NotionConnector: Connector {
    public static let apiBase = URL(string: "https://api.notion.com/v1")!
    public static let apiVersion = "2022-06-28"
    public static let oauthConfig = ConnectorOAuthConfig(
        authorizationURL: URL(string: "https://api.notion.com/v1/oauth/authorize")!,
        tokenURL: URL(string: "https://api.notion.com/v1/oauth/token")!,
        clientID: "", scopes: [], extraAuthParams: ["owner": "user"])
    public static let secretKey = "connector.notion.tokens"

    public let id = "notion"
    public let displayName = "Notion"
    public let capabilities: Set<ConnectorCapability> = [.create, .comment, .search]
    /// Documented integration capabilities (Notion has no OAuth scope parameter).
    public let scopes = ["content:insert", "content:read", "comment:read", "comment:insert"]
    public var isSignedIn: Bool { client.oauth.isSignedIn }
    public let client: ConnectorClient

    public init(client: ConnectorClient) { self.client = client }
    public init(oauth: ConnectorOAuth, transport: HTTPTransport = URLSessionTransport(), log: @escaping NetworkLogSink) {
        client = ConnectorClient(providerID: "notion", oauth: oauth, transport: transport, log: log)
    }

    public func matches(_ target: ActionTarget) -> Bool {
        target.service == "notion" || target.urlHost?.hasSuffix("notion.so") == true || target.urlHost?.hasSuffix("notion.site") == true
            || target.bundleID?.lowercased() == "notion.id"
    }

    public func perform(_ action: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: action) { return fb }
        switch action.kind {
        case .create:
            let title = action["title"] ?? action.text
            guard !title.isEmpty else { return .fallbackToUI(reason: "no page title") }
            guard let parent = action["parentID"] else { return .fallbackToUI(reason: "no parent page/database") }
            let parentKey = action["parentType"] == "database" ? "database_id" : "page_id"
            let titleProp = parentKey == "database_id" ? "Name" : "title"
            var body: [String: Any] = [
                "parent": [parentKey: parent],
                "properties": [titleProp: ["title": [Self.richText(title)]]],
            ]
            if action["title"] != nil, !action.text.isEmpty, action.text != title {
                body["children"] = [["object": "block", "type": "paragraph", "paragraph": ["rich_text": [Self.richText(action.text)]]]]
            }
            let obj = try await post("pages", body, purpose: "notion.pages.create")
            return .performed(ConnectorResult(id: obj["id"] as? String, url: obj["url"] as? String, summary: "Created Notion page “\(title)”",
                                              undoHint: (obj["id"] as? String).map { "archivePage:\($0)" }))
        case .comment:
            guard let page = action["parentID"], !action.text.isEmpty else { return .fallbackToUI(reason: "no page or comment body") }
            var body: [String: Any] = ["rich_text": [Self.richText(action.text)]]
            if let d = action["threadID"] { body["discussion_id"] = d } else { body["parent"] = ["page_id": page] }
            let obj = try await post("comments", body, purpose: "notion.comments.create")
            return .performed(ConnectorResult(id: obj["id"] as? String, summary: "Commented on Notion page", undoHint: nil))
        case .search:
            let q = action["query"] ?? action.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            let obj = try await post("search", ["query": q, "page_size": 10], purpose: "notion.search")
            let results = obj["results"] as? [[String: Any]] ?? []
            let items = results.map { Self.titleOf($0) }
            return .performed(ConnectorResult(summary: "\(items.count) Notion results for “\(q)”", items: items))
        default:
            return .fallbackToUI(reason: "unsupported")
        }
    }

    func post(_ path: String, _ body: [String: Any], purpose: String) async throws -> [String: Any] {
        let req = try client.request("POST", Self.apiBase.appendingPathComponent(path), json: body,
                                     headers: ["Notion-Version": Self.apiVersion])
        return try await client.send(req, purpose: purpose)
    }

    static func richText(_ s: String) -> [String: Any] { ["type": "text", "text": ["content": String(s.prefix(2000))]] }

    static func titleOf(_ obj: [String: Any]) -> String {
        let props = obj["properties"] as? [String: Any] ?? [:]
        for (_, v) in props {
            if let p = v as? [String: Any], let t = p["title"] as? [[String: Any]] {
                return t.compactMap { $0["plain_text"] as? String }.joined()
            }
        }
        if let t = (obj["title"] as? [[String: Any]])?.compactMap({ $0["plain_text"] as? String }).joined(), !t.isEmpty { return t }
        return obj["id"] as? String ?? "?"
    }
}

/// Notion's token endpoint: Basic auth + JSON body. Stores into the shared `ConnectorOAuth` secret slot.
public enum NotionOAuth {
    public static func exchange(code: String, clientSecret: String, oauth: ConnectorOAuth) async throws -> ConnectorTokens {
        var req = URLRequest(url: oauth.config.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(oauth.config.clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "authorization_code", "code": code, "redirect_uri": oauth.config.redirectURI])
        let (data, resp) = try await oauth.transport.send(req)
        guard (200..<300).contains(resp.statusCode) else { throw ConnectorError.unauthorized }
        let t = try ConnectorTokens(tokenResponse: data, previous: nil, now: oauth.now())
        try oauth.store(t); return t
    }
}
