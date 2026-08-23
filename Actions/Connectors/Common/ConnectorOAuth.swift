import CryptoKit
import Foundation
import Shared

/// Minimal Keychain seam (mirrors Providers.SecretStore; Actions cannot depend on Providers).
public protocol ConnectorSecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

public final class InMemoryConnectorSecretStore: ConnectorSecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

/// RFC 7636 PKCE pair (same construction as Providers/OAuthPKCE.swift).
public struct ConnectorPKCE: Sendable, Equatable {
    public let verifier: String, challenge: String
    public let method = "S256"
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.init(verifier: ConnectorPKCE.base64URL(Data(bytes)))
    }
    public init(verifier: String) {
        self.verifier = verifier
        challenge = ConnectorPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct ConnectorOAuthConfig: Sendable, Equatable {
    public var authorizationURL: URL, tokenURL: URL, clientID: String, scopes: [String]
    public var redirectURI: String
    /// Extra authorize-URL params (e.g. Google `access_type=offline`, Slack `user_scope`).
    public var extraAuthParams: [String: String]
    public init(authorizationURL: URL, tokenURL: URL, clientID: String, scopes: [String],
                redirectURI: String = "http://localhost:1456/auth/callback", extraAuthParams: [String: String] = [:]) {
        self.authorizationURL = authorizationURL; self.tokenURL = tokenURL; self.clientID = clientID
        self.scopes = scopes; self.redirectURI = redirectURI; self.extraAuthParams = extraAuthParams
    }
}

public struct ConnectorTokens: Codable, Sendable, Equatable {
    public var accessToken: String, refreshToken: String?, expiresAt: Date
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt.addingTimeInterval(-60) }

    /// Parses `{access_token, refresh_token, expires_in}` (also Slack's `authed_user.access_token`); keeps old refresh token if omitted.
    public init(tokenResponse data: Data, previous: ConnectorTokens?, now: Date = Date()) throws {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorError.malformedResponse("token") }
        if obj["access_token"] == nil, let u = obj["authed_user"] as? [String: Any] { obj = u }
        guard let access = obj["access_token"] as? String else { throw ConnectorError.malformedResponse("token response") }
        let ttl = (obj["expires_in"] as? Double) ?? 3600 * 24 * 365
        self.init(accessToken: access, refreshToken: obj["refresh_token"] as? String ?? previous?.refreshToken, expiresAt: now.addingTimeInterval(ttl))
    }
}

/// Shared OAuth 2.0 + PKCE session for all connectors. Tokens live in the secret store under `secretKey`.
/// Interactive sign-in opens the browser via `openURL` and waits for the code via `codeReceiver` (loopback listener in the app).
public final class ConnectorOAuth: @unchecked Sendable {
    public let config: ConnectorOAuthConfig
    public let secrets: ConnectorSecretStore
    public let transport: HTTPTransport
    public let secretKey: String
    public let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(config: ConnectorOAuthConfig, secrets: ConnectorSecretStore, transport: HTTPTransport = URLSessionTransport(),
                secretKey: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.secrets = secrets; self.transport = transport; self.secretKey = secretKey; self.now = now
    }

    public func storedTokens() -> ConnectorTokens? {
        guard let json = try? secrets.get(secretKey) else { return nil }
        return try? JSONDecoder().decode(ConnectorTokens.self, from: Data(json.utf8))
    }
    public func store(_ t: ConnectorTokens) throws { try secrets.set(String(decoding: try JSONEncoder().encode(t), as: UTF8.self), for: secretKey) }
    public func signOut() throws { try secrets.delete(secretKey) }
    public var isSignedIn: Bool { storedTokens() != nil }

    public func authorizationURL(pkce: ConnectorPKCE, state: String) -> URL {
        var c = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI), .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
        ]
        items += config.extraAuthParams.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items
        return c.url!
    }

    /// Full flow: open browser → receive (code,state) → exchange → store.
    @discardableResult
    public func signIn(openURL: @Sendable (URL) -> Void,
                       codeReceiver: @Sendable () async throws -> (code: String, state: String)) async throws -> ConnectorTokens {
        let pkce = ConnectorPKCE()
        let state = ConnectorPKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        openURL(authorizationURL(pkce: pkce, state: state))
        let cb = try await codeReceiver()
        guard cb.state == state else { throw ConnectorError.unauthorized }
        let t = try await exchange(form: ["grant_type": "authorization_code", "code": cb.code, "redirect_uri": config.redirectURI,
                                          "client_id": config.clientID, "code_verifier": pkce.verifier], previous: nil)
        try store(t); return t
    }

    public func refresh(_ old: ConnectorTokens) async throws -> ConnectorTokens {
        guard let rt = old.refreshToken else { throw ConnectorError.unauthorized }
        let t = try await exchange(form: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": config.clientID], previous: old)
        try store(t); return t
    }

    /// Fresh access token; refreshes when within 60s of expiry. `nil` when not signed in.
    public func accessToken() async throws -> String? {
        guard let t = storedTokens() else { return nil }
        return t.isExpired(now: now()) ? try await refresh(t).accessToken : t.accessToken
    }

    private func exchange(form: [String: String], previous: ConnectorTokens?) async throws -> ConnectorTokens {
        var req = URLRequest(url: config.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").utf8)
        let (data, resp) = try await transport.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            if resp.statusCode == 400 || resp.statusCode == 401 { throw ConnectorError.unauthorized }
            throw ConnectorError.http(resp.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try ConnectorTokens(tokenResponse: data, previous: previous, now: now())
    }
}
