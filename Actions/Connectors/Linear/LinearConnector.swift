import Foundation
import Shared

/// Linear via its GraphQL API. OAuth 2.0 (https://linear.app/oauth/authorize) with the narrowest scopes that
/// cover create/comment/search: `read`, `issues:create`, `comments:create` (never `write`/`admin`).
public struct LinearConnector: Connector {
    public static let graphQLURL = URL(string: "https://api.linear.app/graphql")!
    public static let oauthConfig = ConnectorOAuthConfig(
        authorizationURL: URL(string: "https://linear.app/oauth/authorize")!,
        tokenURL: URL(string: "https://api.linear.app/oauth/token")!,
        clientID: "", scopes: ["read", "issues:create", "comments:create"],
        extraAuthParams: ["prompt": "consent"])
    public static let secretKey = "connector.linear.tokens"

    public let id = "linear"
    public let displayName = "Linear"
    public let capabilities: Set<ConnectorCapability> = [.create, .comment, .search]
    public var scopes: [String] { client.oauth.config.scopes }
    public var isSignedIn: Bool { client.oauth.isSignedIn }
    public let client: ConnectorClient

    public init(client: ConnectorClient) { self.client = client }
    public init(oauth: ConnectorOAuth, transport: HTTPTransport = URLSessionTransport(), log: @escaping NetworkLogSink) {
        client = ConnectorClient(providerID: "linear", oauth: oauth, transport: transport, log: log)
    }

    public func matches(_ target: ActionTarget) -> Bool {
        target.service == "linear" || target.urlHost?.hasSuffix("linear.app") == true
            || target.bundleID?.lowercased().contains("linear") == true
    }

    public func perform(_ action: ConnectorAction) async throws -> ConnectorOutcome {
        if let fb = routingFallback(for: action) { return fb }
        switch action.kind {
        case .create:
            let title = action["title"] ?? action.text
            guard !title.isEmpty else { return .fallbackToUI(reason: "no issue title") }
            guard let team = action["teamID"] ?? action["team"] else { return .fallbackToUI(reason: "no Linear team") }
            let teamID = try await resolveTeam(team)
            var input: [String: Any] = ["teamId": teamID, "title": title]
            if let t = action["title"], !action.text.isEmpty, t != action.text { input["description"] = action.text }
            let data = try await graphQL("mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }",
                                         variables: ["input": input], purpose: "linear.issueCreate")
            let issue = (data["issueCreate"] as? [String: Any])?["issue"] as? [String: Any] ?? [:]
            return .performed(ConnectorResult(id: issue["id"] as? String, url: issue["url"] as? String,
                                              summary: "Created \(issue["identifier"] as? String ?? "issue") “\(title)”",
                                              undoHint: (issue["id"] as? String).map { "issueArchive:\($0)" }))
        case .comment:
            guard let ref = action["parentID"] ?? action["issue"], !action.text.isEmpty else { return .fallbackToUI(reason: "no issue or comment body") }
            let issueID = try await resolveIssue(ref)
            let data = try await graphQL("mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id url } } }",
                                         variables: ["input": ["issueId": issueID, "body": action.text]], purpose: "linear.commentCreate")
            let c = (data["commentCreate"] as? [String: Any])?["comment"] as? [String: Any] ?? [:]
            return .performed(ConnectorResult(id: c["id"] as? String, url: c["url"] as? String, summary: "Commented on \(ref)",
                                              undoHint: (c["id"] as? String).map { "commentDelete:\($0)" }))
        case .search:
            let q = action["query"] ?? action.text
            guard !q.isEmpty else { return .fallbackToUI(reason: "empty query") }
            let data = try await graphQL("query($q: String!) { searchIssues(term: $q, first: 10) { nodes { identifier title url } } }",
                                         variables: ["q": q], purpose: "linear.search")
            let nodes = (data["searchIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let items = nodes.map { "\($0["identifier"] as? String ?? "?"): \($0["title"] as? String ?? "")" }
            return .performed(ConnectorResult(summary: "\(items.count) Linear issues for “\(q)”", items: items))
        default:
            return .fallbackToUI(reason: "unsupported")
        }
    }

    // MARK: GraphQL plumbing

    /// POSTs one operation; surfaces `errors[]` as `ConnectorError.http(200, message)`.
    public func graphQL(_ query: String, variables: [String: Any] = [:], purpose: String) async throws -> [String: Any] {
        let req = try client.request("POST", Self.graphQLURL, json: ["query": query, "variables": variables])
        let obj = try await client.send(req, purpose: purpose)
        if let errs = obj["errors"] as? [[String: Any]], let first = errs.first {
            throw ConnectorError.http(200, first["message"] as? String ?? "GraphQL error")
        }
        guard let data = obj["data"] as? [String: Any] else { throw ConnectorError.malformedResponse(purpose) }
        return data
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Team key ("ENG") or name → team id; UUIDs pass through.
    func resolveTeam(_ ref: String) async throws -> String {
        if Self.isUUID(ref) { return ref }
        let data = try await graphQL("query { teams { nodes { id key name } } }", purpose: "linear.teams")
        let nodes = (data["teams"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let hit = nodes.first { ($0["key"] as? String)?.caseInsensitiveCompare(ref) == .orderedSame }
            ?? nodes.first { ($0["name"] as? String)?.caseInsensitiveCompare(ref) == .orderedSame }
        guard let id = hit?["id"] as? String else { throw ConnectorError.unsupported("unknown Linear team \(ref)") }
        return id
    }

    /// Issue identifier ("ENG-123") → issue id; UUIDs pass through.
    func resolveIssue(_ ref: String) async throws -> String {
        if Self.isUUID(ref) { return ref }
        let data = try await graphQL("query($id: String!) { issue(id: $id) { id } }", variables: ["id": ref], purpose: "linear.issue")
        guard let id = (data["issue"] as? [String: Any])?["id"] as? String else { throw ConnectorError.unsupported("unknown Linear issue \(ref)") }
        return id
    }
}
