import CryptoKit
import Foundation
import Network
import Shared

/// T4. "Sign in with ChatGPT" — OAuth 2.0 authorization-code flow with PKCE (RFC 7636),
/// loopback redirect (RFC 8252 §7.3), refresh tokens in Keychain. Pipeline stages only.
public enum OAuthCopy {
    /// Must appear next to the sign-in button. Subscriptions never help ASR (Part 4.6).
    public static let subscriptionsDoNotHelpASR =
        "Signing in with ChatGPT uses your subscription for formatting and rewrites only. It does not improve speech recognition — transcription always runs on this Mac."
}

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// RFC 7636 §4.1: 43–128 chars from [A-Za-z0-9-._~]. We use 32 random bytes, base64url.
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.init(verifier: PKCE.base64URL(Data(bytes)))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OAuthConfig: Sendable, Equatable {
    public var authorizationURL: URL
    public var tokenURL: URL
    public var clientID: String
    public var scopes: [String]
    public var redirectPort: UInt16   // 0 = ephemeral
    public var redirectPath: String

    public init(authorizationURL: URL, tokenURL: URL, clientID: String, scopes: [String], redirectPort: UInt16 = 0, redirectPath: String = "/auth/callback") {
        self.authorizationURL = authorizationURL; self.tokenURL = tokenURL; self.clientID = clientID
        self.scopes = scopes; self.redirectPort = redirectPort; self.redirectPath = redirectPath
    }

    /// OpenAI's public native-app client (the one Codex CLI uses; Muesli-proven).
    public static let chatGPT = OAuthConfig(
        authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: ["openid", "profile", "email", "offline_access"],
        redirectPort: 1455
    )
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String?, idToken: String? = nil, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken; self.expiresAt = expiresAt
    }
    public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }

    /// Parses `{access_token, refresh_token, id_token, expires_in}`; keeps the old refresh token if omitted.
    public init(tokenResponse data: Data, previous: OAuthTokens? = nil) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else { throw ProviderError.malformedResponse("token response") }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        self.init(accessToken: access, refreshToken: obj["refresh_token"] as? String ?? previous?.refreshToken,
                  idToken: obj["id_token"] as? String ?? previous?.idToken, expiresAt: Date().addingTimeInterval(ttl))
    }
}

/// Loopback HTTP listener that captures exactly one redirect (`code` + `state`).
public final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let path: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    public private(set) var port: UInt16 = 0

    public init(port: UInt16, path: String) throws {
        self.path = path
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    }

    public var redirectURI: String { "http://localhost:\(port)\(path)" }

    /// Starts listening; returns once the port is bound.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? 0
                    once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Waits for the browser to hit the redirect. Cancel by calling `stop()`.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> (code: String, state: String) {
        try await withThrowingTaskGroup(of: (code: String, state: String).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock(); self.continuation = cont; self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw ProviderError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    public func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else {
                conn.cancel(); return
            }
            let parts = head.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let comps = URLComponents(string: "http://localhost\(target)")
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let ok = comps?.path == self.path && query["code"] != nil
            let body = ok ? "<html><body style='font-family:-apple-system'><h2>Signed in. You can return to VoicePlus.</h2></body></html>"
                          : "<html><body><h2>Missing authorization code.</h2><p>\(query["error"] ?? "")</p></body></html>"
            let resp = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.lock.lock(); let cont = self.continuation; self.continuation = nil; self.lock.unlock()
            if ok { cont?.resume(returning: (query["code"]!, query["state"] ?? "")) }
            else { cont?.resume(throwing: ProviderError.unauthorized) }
        }
    }
}

final class OnceBox: @unchecked Sendable {
    private var done = false; private let lock = NSLock()
    var didRun: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
}

/// Drives the flow and owns the tokens. `openURL` is injected so tests can simulate the browser.
public final class OAuthSession: TokenSource, @unchecked Sendable {
    public let config: OAuthConfig
    public let secrets: SecretStore
    public let session: URLSession
    public let secretKey: String
    private let lock = NSLock()

    public init(config: OAuthConfig, secrets: SecretStore, session: URLSession = .shared, secretKey: String = SecretKey.chatGPTOAuthTokens) {
        self.config = config; self.secrets = secrets; self.session = session; self.secretKey = secretKey
    }

    public func storedTokens() -> OAuthTokens? {
        guard let json = try? secrets.get(secretKey) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
    }
    public func store(_ tokens: OAuthTokens) throws {
        try secrets.set(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self), for: secretKey)
    }
    public func signOut() throws { try secrets.delete(secretKey) }
    public var isSignedIn: Bool { storedTokens() != nil }

    public func authorizationURL(pkce: PKCE, state: String, redirectURI: String) -> URL {
        var c = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    /// Full interactive sign-in. Returns tokens and stores them.
    @discardableResult
    public func signIn(openURL: @Sendable (URL) -> Void, timeout: TimeInterval = 300) async throws -> OAuthTokens {
        let listener = try LoopbackListener(port: config.redirectPort, path: config.redirectPath)
        try await listener.start()
        defer { listener.stop() }
        let pkce = PKCE()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        openURL(authorizationURL(pkce: pkce, state: state, redirectURI: listener.redirectURI))
        let cb = try await listener.waitForCallback(timeout: timeout)
        guard cb.state == state else { throw ProviderError.unauthorized }
        let tokens = try await exchange(form: [
            "grant_type": "authorization_code", "code": cb.code, "redirect_uri": listener.redirectURI,
            "client_id": config.clientID, "code_verifier": pkce.verifier,
        ], previous: nil)
        try store(tokens)
        return tokens
    }

    public func refresh(_ old: OAuthTokens) async throws -> OAuthTokens {
        guard let rt = old.refreshToken else { throw ProviderError.unauthorized }
        let t = try await exchange(form: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": config.clientID], previous: old)
        try store(t)
        return t
    }

    /// TokenSource: returns a fresh access token, refreshing when near expiry.
    public func accessToken() async throws -> String? {
        guard let t = storedTokens() else { return nil }
        if !t.isExpired { return t.accessToken }
        return try await refresh(t).accessToken
    }

    private func exchange(form: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var req = URLRequest(url: config.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 400 || code == 401 { throw ProviderError.unauthorized }
            throw ProviderError.http(code, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try OAuthTokens(tokenResponse: data, previous: previous)
    }

    /// ChatGPT backend needs the account id from the JWT (`https://api.openai.com/auth`.chatgpt_account_id).
    public static func chatGPTAccountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}

/// The ChatGPT-subscription provider: OpenAICompatibleClient over the OAuth token source.
public struct ChatGPTSubscriptionProvider: TextGenerator {
    public let oauth: OAuthSession
    public let model: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(oauth: OAuthSession, model: String = "gpt-5", session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.oauth = oauth; self.model = model; self.session = session; self.timeout = timeout
    }

    public var id: ProviderID { "oauth.chatgpt" }
    public var displayName: String { "ChatGPT (your subscription) · \(model)" }
    public var capabilities: ProviderCapabilities { [.pipeline, .streaming] }   // never .asr
    public var costClass: CostClass { .subscription }
    public var privacyClass: PrivacyClass { .cloud }
    public func isAvailable() async -> Bool { oauth.isSignedIn }

    public func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        var client = OpenAICompatibleClient(endpoint: .chatGPT, model: model, tokenSource: oauth, session: session, timeout: timeout)
        if let t = oauth.storedTokens(), let acct = OAuthSession.chatGPTAccountID(fromJWT: t.accessToken) {
            client.extraHeaders["chatgpt-account-id"] = acct
        }
        return try await client.generate(prompt: prompt, system: system, stage: stage)
    }
}
