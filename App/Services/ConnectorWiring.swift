import Actions
import AppKit
import Foundation
import Network
import Providers
import Shared

/// P4.6 — connector composition: Keychain-backed token storage, OAuth loopback receiver,
/// registry of the six connectors, every call logged to the Data Panel.

/// `Actions` can't import `Providers`, so the Keychain seam is adapted here (same 3 methods).
public struct KeychainConnectorSecretStore: ConnectorSecretStore {
    private let inner: any SecretStore
    public init(inner: any SecretStore = KeychainSecretStore(service: "in.adityakatare.voiceplus.connectors")) {
        self.inner = inner
    }
    public func get(_ key: String) throws -> String? { try inner.get(key) }
    public func set(_ value: String, for key: String) throws { try inner.set(value, for: key) }
    public func delete(_ key: String) throws { try inner.delete(key) }
}

/// Minimal loopback receiver for the OAuth redirect (default `http://localhost:1456/auth/callback`).
/// Listens once, parses `code` + `state` from the query, answers with a small HTML page, stops.
public final class LoopbackCodeReceiver: @unchecked Sendable {
    public let port: UInt16
    public init(port: UInt16 = 1456) { self.port = port }

    public func receive() async throws -> (code: String, state: String) {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let result = Self.parse(request: request)
                    let body = result != nil
                        ? "<html><body><h3>VoicePlus is connected.</h3>You can close this window.</body></html>"
                        : "<html><body><h3>Missing code.</h3></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        if let result { resumed.resume { continuation.resume(returning: result) } }
                    })
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { resumed.resume { continuation.resume(throwing: error) } }
            }
            listener.start(queue: .global())
        }
    }

    /// `GET /auth/callback?code=…&state=… HTTP/1.1` → (code, state).
    public static func parse(request: String) -> (code: String, state: String)? {
        guard let line = request.split(separator: "\r\n").first, line.hasPrefix("GET ") else { return nil }
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://localhost\(target)") else { return nil }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        let state = items.first(where: { $0.name == "state" })?.value ?? ""
        return (code, state)
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ f: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            f()
        }
    }
}

/// One row per service in the "Connected services" tab.
public struct ConnectorDescriptor: Identifiable, Sendable {
    public enum AuthKind: Sendable { case oauthLoopback, githubPAT }
    public let id: String
    public let displayName: String
    public let scopes: [String]
    public let authKind: AuthKind
    /// Environment/settings key holding the OAuth client ID.
    public let clientIDKey: String
}

/// Builds and holds the six connectors over one Keychain store + one Data Panel log sink.
public final class ConnectorHub: @unchecked Sendable {
    public let secrets: ConnectorSecretStore
    public let log: NetworkLogSink
    private let transport: HTTPTransport
    private let environment: [String: String]
    private var oauths: [String: ConnectorOAuth] = [:]
    private let lock = NSLock()

    public static let descriptors: [ConnectorDescriptor] = [
        ConnectorDescriptor(id: "slack", displayName: "Slack", scopes: SlackConnector.scopes,
                            authKind: .oauthLoopback, clientIDKey: "VOICEPLUS_SLACK_CLIENT_ID"),
        ConnectorDescriptor(id: "gmail", displayName: "Gmail", scopes: GmailConnector.scopes,
                            authKind: .oauthLoopback, clientIDKey: "VOICEPLUS_GOOGLE_CLIENT_ID"),
        ConnectorDescriptor(id: "googlecalendar", displayName: "Google Calendar", scopes: GoogleCalendarConnector.scopes,
                            authKind: .oauthLoopback, clientIDKey: "VOICEPLUS_GOOGLE_CLIENT_ID"),
        ConnectorDescriptor(id: "linear", displayName: "Linear", scopes: [],
                            authKind: .oauthLoopback, clientIDKey: "VOICEPLUS_LINEAR_CLIENT_ID"),
        ConnectorDescriptor(id: "notion", displayName: "Notion", scopes: [],
                            authKind: .oauthLoopback, clientIDKey: "VOICEPLUS_NOTION_CLIENT_ID"),
        ConnectorDescriptor(id: "github", displayName: "GitHub", scopes: ["repo"],
                            authKind: .githubPAT, clientIDKey: "VOICEPLUS_GITHUB_CLIENT_ID"),
    ]

    public init(secrets: ConnectorSecretStore = KeychainConnectorSecretStore(),
                transport: HTTPTransport = URLSessionTransport(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                log: @escaping NetworkLogSink) {
        self.secrets = secrets
        self.transport = transport
        self.environment = environment
        self.log = log
    }

    public func clientID(for descriptor: ConnectorDescriptor) -> String? {
        let value = environment[descriptor.clientIDKey] ?? ""
        return value.isEmpty ? nil : value
    }

    func oauth(for descriptor: ConnectorDescriptor) -> ConnectorOAuth {
        lock.lock(); defer { lock.unlock() }
        if let existing = oauths[descriptor.id] { return existing }
        let clientID = { let v = environment[descriptor.clientIDKey] ?? ""; return v }()
        var config: ConnectorOAuthConfig
        switch descriptor.id {
        case "slack": config = SlackConnector.oauthConfig(clientID: clientID)
        case "gmail": config = GmailConnector.oauthConfig(clientID: clientID)
        case "googlecalendar": config = GoogleCalendarConnector.oauthConfig(clientID: clientID)
        case "linear": config = LinearConnector.oauthConfig; config.clientID = clientID
        case "notion": config = NotionConnector.oauthConfig; config.clientID = clientID
        default: config = GitHubConnector.placeholderConfig
        }
        let oauth = ConnectorOAuth(config: config, secrets: secrets, transport: transport,
                                   secretKey: "connector.\(descriptor.id).tokens")
        oauths[descriptor.id] = oauth
        return oauth
    }

    func client(for descriptor: ConnectorDescriptor) -> ConnectorClient {
        ConnectorClient(providerID: descriptor.id, oauth: oauth(for: descriptor), transport: transport, log: log)
    }

    /// All six connectors, routing through the registry (API when target matches, UI fallback otherwise).
    public func registry() -> ConnectorRegistry {
        ConnectorRegistry(Self.descriptors.map { connector(for: $0) })
    }

    public func connector(for descriptor: ConnectorDescriptor) -> any Connector {
        switch descriptor.id {
        case "slack": return SlackConnector(client: client(for: descriptor))
        case "gmail": return GmailConnector(client: client(for: descriptor))
        case "googlecalendar": return GoogleCalendarConnector(client: client(for: descriptor))
        case "linear": return LinearConnector(client: client(for: descriptor))
        case "notion": return NotionConnector(client: client(for: descriptor))
        default: return GitHubConnector(client: client(for: descriptor))
        }
    }

    public func isSignedIn(_ descriptor: ConnectorDescriptor) -> Bool {
        oauth(for: descriptor).isSignedIn
    }

    /// OAuth start (loopback flow). Throws when no client ID is configured.
    public func signIn(_ descriptor: ConnectorDescriptor) async throws {
        guard clientID(for: descriptor) != nil else {
            throw ConnectorError.unsupported("Set \(descriptor.clientIDKey) to enable \(descriptor.displayName) sign-in")
        }
        let oauth = oauth(for: descriptor)
        let receiver = LoopbackCodeReceiver()
        _ = try await oauth.signIn(openURL: { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }, codeReceiver: { try await receiver.receive() })
    }

    public func storeGitHubPAT(_ pat: String) throws {
        let descriptor = Self.descriptors.first { $0.id == "github" }!
        try GitHubAuth.storePAT(pat, in: oauth(for: descriptor))
    }

    public func signOut(_ descriptor: ConnectorDescriptor) throws {
        try oauth(for: descriptor).signOut()
    }
}
