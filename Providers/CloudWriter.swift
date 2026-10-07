import Foundation
import Shared

// Context Writer (VoicePlus_ContextWriter_Plan.md §5–§6) — the cloud backend.
//
// One OpenRouter chat-completions call per dictation: the bake-off's default model, a fallback list
// (OpenRouter's `models` field), provider routing sorted by latency with optional pinned providers,
// reasoning off, temperature 0, a hard 2.5 s deadline, and a pre-warmed keep-alive session so the
// TLS handshake happens at key-down rather than at release. Providers does not import Pipeline, so
// this is a plain struct with `write(system:user:)`; the App wraps it into `WriterGenerating`.
//
// What leaves the Mac is the rendered prompt; what is logged is bytes and purpose, never the text.

/// The cloud writer's knobs, all stored in Settings (`correction.*`).
public struct CloudWriterConfig: Sendable, Equatable {
    public static let defaultModel = "deepseek/deepseek-v4.1-flash"
    public static let defaultFallbacks = ["google/gemma-4-26b-a4b-it", "openai/gpt-6-luna"]
    public static let defaultTimeout: TimeInterval = 2.5

    /// Primary model id (OpenRouter form).
    public var model: String
    /// Tried in order when the primary is down or rate-limited (OpenRouter `models`).
    public var fallbackModels: [String]
    /// Pinned provider slugs, first choice first (OpenRouter `provider.order`); empty = any.
    public var providerOrder: [String]
    /// Hard deadline for the whole call, connection included.
    public var timeout: TimeInterval
    public var maxTokens: Int
    /// Minimum gap between two prewarm requests; the pool keeps the connection in between.
    public var prewarmInterval: TimeInterval

    public init(model: String = CloudWriterConfig.defaultModel,
                fallbackModels: [String] = CloudWriterConfig.defaultFallbacks,
                providerOrder: [String] = [],
                timeout: TimeInterval = CloudWriterConfig.defaultTimeout,
                maxTokens: Int = 400,
                prewarmInterval: TimeInterval = 45) {
        self.model = model
        self.fallbackModels = fallbackModels
        self.providerOrder = providerOrder
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.prewarmInterval = prewarmInterval
    }
}

/// Remembers when the connection was last opened, so key-down prewarms are rate-limited.
final class PrewarmClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?
    func shouldRun(interval: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}

public struct CloudWriterGenerator: Sendable {
    public static let stage = "writer"
    public static let purpose = "writer"

    public let endpoint: APIEndpoint = .openRouter
    public let config: CloudWriterConfig
    public let session: URLSession
    let tokenSource: TokenSource
    let logger: NetworkLogger?
    private let clock = PrewarmClock()
    /// The egress kill switch, by host (wired by the App from `EgressGate`). Default: allow.
    public var egressAllowed: @Sendable (String) -> Bool = { _ in true }

    /// Key from `SecretStore` under the existing OpenRouter key name (`apikey.api.openrouter`).
    public init(config: CloudWriterConfig = CloudWriterConfig(), secrets: SecretStore,
                session: URLSession? = nil, logger: NetworkLogger? = nil) {
        self.init(config: config,
                  tokenSource: KeychainTokenSource(secrets: secrets, key: SecretKey.apiKey(APIEndpoint.openRouter.providerID)),
                  session: session, logger: logger)
    }

    init(config: CloudWriterConfig, tokenSource: TokenSource, session: URLSession?, logger: NetworkLogger?) {
        self.config = config
        self.tokenSource = tokenSource
        self.session = session ?? Self.makeSession(timeout: config.timeout)
        self.logger = logger
    }

    /// A session that keeps its connection to OpenRouter open between dictations.
    public static func makeSession(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    public var host: String { endpoint.baseURL.host ?? "openrouter.ai" }

    /// A key is stored and egress to the host is allowed.
    public func isAvailable() async -> Bool {
        guard egressAllowed(host) else { return false }
        return ((try? await tokenSource.accessToken()) ?? nil)?.isEmpty == false
    }

    // MARK: Prewarm (key-down)

    /// Opens (or refreshes) the connection so the real call skips DNS + TCP + TLS. Rate-limited by
    /// `config.prewarmInterval`; a tiny authenticated GET, logged like any other request.
    public func prewarm() async {
        guard await isAvailable(), clock.shouldRun(interval: config.prewarmInterval) else { return }
        guard let token = try? await tokenSource.accessToken(), !token.isEmpty else { return }
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("auth/key"), timeoutInterval: config.timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("VoicePlus", forHTTPHeaderField: "X-Title")
        do {
            let (data, _) = try await session.data(for: req)
            log(bytesOut: 0, bytesIn: data.count, purpose: "\(Self.purpose).prewarm")
        } catch {
            Log.providers.notice("writer prewarm failed: \(error)")
        }
    }

    // MARK: Write

    /// One corrected text for one prompt. Throws `ProviderError.timeout` at the deadline,
    /// `.unauthorized` without a key, `.unavailable` when egress is blocked.
    public func write(system: String, user: String) async throws -> String {
        guard egressAllowed(host) else { throw ProviderError.unavailable("blocked by egress kill switch") }
        let (request, bytesOut) = try await makeRequest(system: system, user: user)
        let client = OpenAICompatibleClient(endpoint: endpoint, model: config.model, tokenSource: tokenSource,
                                            session: session, timeout: config.timeout)
        var text = ""
        var bytesIn = 0
        do {
            for try await chunk in client.stream(request: request) {
                text += chunk.text
                bytesIn += chunk.rawBytes
            }
        } catch {
            let pe = (error as? ProviderError) ?? .unavailable("\(error)")
            log(bytesOut: bytesOut, bytesIn: bytesIn, purpose: "\(Self.purpose) (failed: \(pe))")
            throw pe
        }
        log(bytesOut: bytesOut, bytesIn: bytesIn, purpose: Self.purpose)
        return text
    }

    func makeRequest(system: String, user: String) async throws -> (URLRequest, Int) {
        guard let token = try await tokenSource.accessToken(), !token.isEmpty else { throw ProviderError.unauthorized }
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: config.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("VoicePlus", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(config: config, system: system, user: user))
        return (req, req.httpBody?.count ?? 0)
    }

    /// The request body (plan §5): model + fallbacks, latency-sorted providers with optional pins,
    /// reasoning off, deterministic, short.
    static func body(config: CloudWriterConfig, system: String, user: String) -> [String: Any] {
        var provider: [String: Any] = ["sort": "latency", "allow_fallbacks": true]
        if !config.providerOrder.isEmpty { provider["order"] = config.providerOrder }
        var body: [String: Any] = [
            "model": config.model,
            "provider": provider,
            "reasoning": ["effort": "none"],
            "temperature": 0,
            "max_tokens": config.maxTokens,
            "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if !config.fallbackModels.isEmpty { body["models"] = [config.model] + config.fallbackModels.filter { $0 != config.model } }
        return body
    }

    private func log(bytesOut: Int, bytesIn: Int, purpose: String) {
        logger?.log(NetworkLogRecord(stage: Self.stage, provider: endpoint.providerID.rawValue, host: host,
                                     bytesOut: bytesOut, bytesIn: bytesIn, purpose: purpose))
    }
}
