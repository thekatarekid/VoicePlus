import Foundation
import Shared

/// GitHub REST v3. Auth is either a fine-grained PAT stored in Keychain (`GitHubAuth.storePAT`) or the OAuth device
/// flow (`GitHubDeviceFlow`) with scope `repo` only (`public_repo` when `publicOnly`). No PKCE/loopback needed.
public struct GitHubConnector: Connector {
    public static let apiBase = URL(string: "https://api.github.com")!
    public static let secretKey = "connector.github.tokens"
    public static let placeholderConfig = ConnectorOAuthConfig(
        authorizationURL: URL(string: "https://github.com/login/device")!,
        tokenURL: URL(string: "https://github.com/login/oauth/access_token")!, clientID: "", scopes: ["repo"])

    public let id = "github"
    public let displayName = "GitHub"
    public let capabilities: Set<ConnectorCapability> = [.create, .comment, .search]
    public let scopes = ["repo"]
    public var isSignedIn: Bool { client.oauth.isSignedIn }
    public let client: ConnectorClient

    public init(client: ConnectorClient) { self.client = client }
    public init(oauth: ConnectorOAuth, transport: HTTPTransport = URLSessionTransport(), log: @escaping NetworkLogSink) {
        client = ConnectorClient(providerID: "github", oauth: oauth, transport: transport, log: log)
    }

    public func matches(_ target: ActionTarget) -> Bool {
        target.service == "github" || target.urlHost == "github.com" || target.urlHost?.hasSuffix(".github.com") == true
            || target.bundleID?.lowercased().contains("github") == true
    }

    /// `owner/name` from the `repo` field or a github.com URL in `url`.
    static func repo(from action: ConnectorAction) -> String? {
        if let r = action["repo"], r.split(separator: "/").count == 2 { return r }
        if let u = action["url"], let c = URLComponents(string: u), c.host == "github.com" {
            let parts = c.path.split(separator: "/")
            if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        }
        return nil
    }

    /// Issue/PR number from `parentID`/`number` or the URL (`/issues/12`, `/pull/12`).
    static func number(from action: ConnectorAction) -> Int? {
        if let n = (action["parentID"] ?? action["number"]).flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) { return n }
        if let u = action["url"], let c = URLComponents(string: u) {
            let parts = c.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(where: { $0 == "issues" || $0 == "pull" }), i + 1 < parts.count { return Int(parts[i + 1]) }
        }
        return nil
    }

    public func perform(_ action: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: action) { return fb }
        switch action.kind {
        case .create:
            let title = action["title"] ?? action.text
            guard !title.isEmpty else { return .fallbackToUI(reason: "no issue title") }
            guard let repo = Self.repo(from: action) else { return .fallbackToUI(reason: "no repository") }
            var body: [String: Any] = ["title": title]
            if action["title"] != nil, !action.text.isEmpty, action.text != title { body["body"] = action.text }
            let obj = try await send("POST", "repos/\(repo)/issues", json: body, purpose: "github.issues.create")
            let n = obj["number"] as? Int
            return .performed(ConnectorResult(id: n.map(String.init), url: obj["html_url"] as? String,
                                              summary: "Opened \(repo)#\(n ?? 0) “\(title)”", undoHint: n.map { "closeIssue:\(repo)#\($0)" }))
        case .comment:
            guard !action.text.isEmpty, let repo = Self.repo(from: action), let n = Self.number(from: action) else {
                return .fallbackToUI(reason: "no repository/issue number or body")
            }
            let obj = try await send("POST", "repos/\(repo)/issues/\(n)/comments", json: ["body": action.text], purpose: "github.issues.comment")
            let cid = (obj["id"] as? Int).map(String.init)
            return .performed(ConnectorResult(id: cid, url: obj["html_url"] as? String, summary: "Commented on \(repo)#\(n)",
                                              undoHint: cid.map { "deleteComment:\(repo)/\($0)" }))
        case .search:
            var q = action["query"] ?? action.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            if let repo = Self.repo(from: action) { q += " repo:\(repo)" }
            var c = URLComponents(url: Self.apiBase.appendingPathComponent("search/issues"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "per_page", value: "10")]
            let req = try client.request("GET", c.url!, headers: Self.headers)
            let obj = try await client.send(req, purpose: "github.search")
            let items = (obj["items"] as? [[String: Any]] ?? []).map { "#\($0["number"] as? Int ?? 0): \($0["title"] as? String ?? "")" }
            return .performed(ConnectorResult(summary: "\(items.count) GitHub results for “\(q)”", items: items))
        default:
            return .fallbackToUI(reason: "unsupported")
        }
    }

    static let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]

    func send(_ method: String, _ path: String, json: [String: Any]? = nil, purpose: String) async throws -> [String: Any] {
        let req = try client.request(method, Self.apiBase.appendingPathComponent(path), json: json, headers: Self.headers)
        return try await client.send(req, purpose: purpose)
    }
}

/// PAT path: token lives in Keychain via the shared `ConnectorOAuth` slot (no refresh token, no expiry).
public enum GitHubAuth {
    public static func storePAT(_ pat: String, in oauth: ConnectorOAuth) throws {
        let trimmed = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ghp_") || trimmed.hasPrefix("github_pat_") else { throw ConnectorError.unsupported("not a GitHub token") }
        try oauth.store(ConnectorTokens(accessToken: trimmed, refreshToken: nil, expiresAt: .distantFuture))
    }
}

/// OAuth device flow (RFC 8628). `start` returns the code the pill shows; `poll` blocks until the user approves.
public struct GitHubDeviceFlow: Sendable {
    public struct Pending: Sendable, Equatable { public let deviceCode: String, userCode: String, verificationURL: String, interval: TimeInterval, expiresAt: Date }
    public let oauth: ConnectorOAuth
    public let clientID: String
    public let publicOnly: Bool
    public let sleep: @Sendable (TimeInterval) async throws -> Void
    public var scope: String { publicOnly ? "public_repo" : "repo" }

    public init(oauth: ConnectorOAuth, clientID: String, publicOnly: Bool = false,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.oauth = oauth; self.clientID = clientID; self.publicOnly = publicOnly; self.sleep = sleep
    }

    public func start() async throws -> Pending {
        let obj = try await post(URL(string: "https://github.com/login/device/code")!, ["client_id": clientID, "scope": scope])
        guard let d = obj["device_code"] as? String, let u = obj["user_code"] as? String, let v = obj["verification_uri"] as? String else {
            throw ConnectorError.malformedResponse("device code")
        }
        let interval = (obj["interval"] as? Double) ?? 5, ttl = (obj["expires_in"] as? Double) ?? 900
        return Pending(deviceCode: d, userCode: u, verificationURL: v, interval: interval, expiresAt: oauth.now().addingTimeInterval(ttl))
    }

    public func poll(_ p: Pending) async throws -> ConnectorTokens {
        var interval = p.interval
        while oauth.now() < p.expiresAt {
            let obj = try await post(oauth.config.tokenURL, ["client_id": clientID, "device_code": p.deviceCode,
                                                               "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if let access = obj["access_token"] as? String {
                let t = ConnectorTokens(accessToken: access, refreshToken: obj["refresh_token"] as? String,
                                        expiresAt: oauth.now().addingTimeInterval((obj["expires_in"] as? Double) ?? 3600 * 24 * 3650))
                try oauth.store(t); return t
            }
            switch obj["error"] as? String {
            case "authorization_pending": break
            case "slow_down": interval += 5
            case "expired_token": throw ConnectorError.timeout
            default: throw ConnectorError.unauthorized
            }
            try await sleep(interval)
        }
        throw ConnectorError.timeout
    }

    private func post(_ url: URL, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, resp) = try await oauth.transport.send(req)
        guard (200..<300).contains(resp.statusCode) else { throw ConnectorError.http(resp.statusCode, "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
