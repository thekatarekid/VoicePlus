import Foundation
import Shared

/// What a connector can do natively. Anything else falls back to UI automation.
public enum ConnectorCapability: String, CaseIterable, Sendable { case send, draft, create, comment, search }

/// Where the user is / what they pointed at. Filled by the act router from the frontmost app + AX context.
public struct ActionTarget: Sendable, Equatable {
    /// Explicit service name spoken or inferred ("slack", "gmail", "calendar"), lowercased.
    public var service: String?
    public var bundleID: String?
    public var urlHost: String?
    public init(service: String? = nil, bundleID: String? = nil, urlHost: String? = nil) {
        self.service = service?.lowercased(); self.bundleID = bundleID; self.urlHost = urlHost?.lowercased()
    }
}

/// Service-neutral action vocabulary. Connectors map these to REST calls.
public struct ConnectorAction: Sendable, Equatable {
    public var kind: ConnectorCapability
    public var target: ActionTarget
    public var text: String
    /// Free-form fields: `channel`, `to`, `subject`, `threadID`, `title`, `start`, `end`, `attendees`, `query`, `parentID`.
    public var fields: [String: String]
    public init(kind: ConnectorCapability, target: ActionTarget, text: String = "", fields: [String: String] = [:]) {
        self.kind = kind; self.target = target; self.text = text; self.fields = fields
    }
    public subscript(_ key: String) -> String? { fields[key] }
}

public struct ConnectorResult: Sendable, Equatable {
    public var id: String?          // message ts / draft id / event id
    public var url: String?
    public var summary: String
    /// Compensating action for the consent engine's undo toast (P4.4), if the API supports it.
    public var undoHint: String?
    public var items: [String]      // search hits
    public init(id: String? = nil, url: String? = nil, summary: String, undoHint: String? = nil, items: [String] = []) {
        self.id = id; self.url = url; self.summary = summary; self.undoHint = undoHint; self.items = items
    }
}

public enum ConnectorOutcome: Sendable, Equatable {
    case performed(ConnectorResult)
    /// Target does not match this service, capability missing, or required fields absent → UI automation path.
    case fallbackToUI(reason: String)
}

public protocol Connector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: Set<ConnectorCapability> { get }
    /// Minimal OAuth scopes requested (documented per service).
    var scopes: [String] { get }
    var isSignedIn: Bool { get }
    /// True when the action target refers to this service (spoken name, bundle id, or web host).
    func matches(_ target: ActionTarget) -> Bool
    func perform(_ action: ConnectorAction) async throws -> ConnectorOutcome
}

public extension Connector {
    /// Default routing decision: wrong target or unsupported kind → fallback, else nil (proceed).
    func routingFallback(for action: ConnectorAction) -> ConnectorOutcome? {
        if !matches(action.target) { return .fallbackToUI(reason: "target is not \(displayName)") }
        if !capabilities.contains(action.kind) { return .fallbackToUI(reason: "\(displayName) has no native \(action.kind.rawValue)") }
        if !isSignedIn { return .fallbackToUI(reason: "\(displayName) not signed in") }
        return nil
    }
}

/// Every egress byte → Data Panel (`NetworkLogRecord`). Injected closure so tests capture records.
public typealias NetworkLogSink = @Sendable (NetworkLogRecord) -> Void

/// Authenticated JSON client shared by connectors: bearer auth, one 401-driven refresh, egress logging.
public struct ConnectorClient: Sendable {
    public let providerID: String
    public let oauth: ConnectorOAuth
    public let transport: HTTPTransport
    public let log: NetworkLogSink
    public static let stage = "act.connector"

    public init(providerID: String, oauth: ConnectorOAuth, transport: HTTPTransport, log: @escaping NetworkLogSink) {
        self.providerID = providerID; self.oauth = oauth; self.transport = transport; self.log = log
    }

    public func request(_ method: String, _ url: URL, json: [String: Any]? = nil, form: [String: String]? = nil,
                        headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = method
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]); r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        if let form {
            r.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        return r
    }

    /// Sends with bearer token; on 401 refreshes once and retries. Logs each attempt.
    public func send(_ req: URLRequest, purpose: String) async throws -> [String: Any] {
        guard var token = try await oauth.accessToken() else { throw ConnectorError.notSignedIn }
        var attempt = 0
        while true {
            var r = req
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await transport.send(r)
            log(NetworkLogRecord(stage: Self.stage, provider: providerID, host: req.url?.host ?? "?",
                                 bytesOut: r.httpBody?.count ?? 0, bytesIn: data.count, purpose: purpose))
            if resp.statusCode == 401, attempt == 0, let old = oauth.storedTokens() {
                attempt += 1; token = try await oauth.refresh(old).accessToken; continue
            }
            guard (200..<300).contains(resp.statusCode) else {
                throw resp.statusCode == 401 ? .unauthorized : ConnectorError.http(resp.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
            }
            if data.isEmpty { return [:] }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorError.malformedResponse(purpose) }
            return obj
        }
    }
}

/// Routes an action to the first matching connector; none → `.fallbackToUI`.
public struct ConnectorRegistry: Sendable {
    public let connectors: [any Connector]
    public init(_ connectors: [any Connector]) { self.connectors = connectors }
    public func perform(_ action: ConnectorAction) async throws -> ConnectorOutcome {
        for c in connectors where c.matches(action.target) { return try await c.perform(action) }
        return .fallbackToUI(reason: "no connector for target")
    }
}
