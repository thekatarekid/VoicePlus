import Foundation
import Shared

/// Remote endpoints. All but Anthropic speak the OpenAI chat-completions wire format;
/// Anthropic uses the Messages API (different auth header, body and SSE events).
public enum APIEndpoint: Sendable, Equatable {
    case openRouter, openAI, anthropic, groq, cerebras
    /// ChatGPT subscription via OAuth (Responses API wire format, Codex backend).
    case chatGPT
    case custom(baseURL: URL, name: String)

    public var name: String {
        switch self {
        case .openRouter: "openrouter"; case .openAI: "openai"; case .anthropic: "anthropic"
        case .groq: "groq"; case .cerebras: "cerebras"; case .chatGPT: "chatgpt"; case .custom(_, let n): n
        }
    }
    public var baseURL: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .groq: URL(string: "https://api.groq.com/openai/v1")!
        case .cerebras: URL(string: "https://api.cerebras.ai/v1")!
        case .chatGPT: URL(string: "https://chatgpt.com/backend-api/codex")!
        case .custom(let u, _): u
        }
    }
    public var isAnthropic: Bool { self == .anthropic }
    public var isResponsesAPI: Bool { self == .chatGPT }
    public var requiresKey: Bool {
        if case .custom = self { return false }
        return true
    }
    public var providerID: ProviderID { ProviderID(rawValue: "api.\(name)") }
}

/// Supplies the bearer token. API keys come from `SecretStore`; OAuth supplies a
/// short-lived access token and refreshes it.
public protocol TokenSource: Sendable {
    func accessToken() async throws -> String?
}

struct KeychainTokenSource: TokenSource {
    let secrets: SecretStore; let key: String
    func accessToken() async throws -> String? { try secrets.get(key) }
}

/// T3. Streaming chat client with timeout. Streaming is consumed into one string here;
/// callers that want tokens as they arrive use `stream(...)`.
public struct OpenAICompatibleClient: TextGenerator {
    public let endpoint: APIEndpoint
    public let model: String
    public let session: URLSession
    public let timeout: TimeInterval
    public let tokenSource: TokenSource
    public var maxTokens = 1024
    public var extraHeaders: [String: String] = [:]

    public init(endpoint: APIEndpoint, model: String, secrets: SecretStore, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.init(endpoint: endpoint, model: model,
                  tokenSource: KeychainTokenSource(secrets: secrets, key: SecretKey.apiKey(endpoint.providerID)),
                  session: session, timeout: timeout)
    }

    public init(endpoint: APIEndpoint, model: String, tokenSource: TokenSource, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.endpoint = endpoint; self.model = model; self.tokenSource = tokenSource; self.session = session; self.timeout = timeout
    }

    public var id: ProviderID { endpoint.providerID }
    public var displayName: String { "\(endpoint.name) · \(model)" }
    public var capabilities: ProviderCapabilities { [.pipeline, .streaming] }
    public var costClass: CostClass { endpoint == .chatGPT ? .subscription : .metered }
    public var privacyClass: PrivacyClass { endpoint.baseURL.host.map { $0 == "127.0.0.1" || $0 == "localhost" } == true ? .localNetwork : .cloud }

    public func isAvailable() async -> Bool {
        guard endpoint.requiresKey else { return true }
        return ((try? await tokenSource.accessToken()) ?? nil)?.isEmpty == false
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        var text = ""
        var bytesIn = 0
        let (request, bytesOut) = try await makeRequest(prompt: prompt, system: system)
        for try await chunk in stream(request: request) {
            text += chunk.text; bytesIn += chunk.rawBytes
        }
        return (text, bytesOut, bytesIn, endpoint.baseURL.host ?? "?")
    }

    public struct Chunk: Sendable { public var text: String; public var rawBytes: Int }

    /// SSE stream → text deltas. Handles both OpenAI `choices[].delta.content` and
    /// Anthropic `content_block_delta.delta.text`. Enforces `timeout` as a deadline.
    public func stream(request: URLRequest) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let timedOut = OnceBox()
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse("no HTTP response") }
                    if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""; for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        throw ProviderError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = Self.extractDelta(payload) {
                            continuation.yield(Chunk(text: delta, rawBytes: line.utf8.count))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.timeout)
                } catch let e as URLError where e.code == .timedOut || (e.code == .cancelled && timedOut.didRun) {
                    continuation.finish(throwing: ProviderError.timeout)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled { timedOut.run {}; task.cancel() }
            }
            continuation.onTermination = { _ in task.cancel(); deadline.cancel() }
        }
    }

    static func extractDelta(_ payload: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any], let c = delta["content"] as? String { return c }
            if let msg = first["message"] as? [String: Any], let c = msg["content"] as? String { return c }
        }
        if obj["type"] as? String == "content_block_delta", let d = obj["delta"] as? [String: Any], let t = d["text"] as? String { return t }
        if obj["type"] as? String == "response.output_text.delta", let t = obj["delta"] as? String { return t }
        return nil
    }

    func makeRequest(prompt: String, system: String) async throws -> (URLRequest, Int) {
        let token = try await tokenSource.accessToken()
        if endpoint.requiresKey, token?.isEmpty != false { throw ProviderError.unauthorized }
        let path = endpoint.isAnthropic ? "messages" : endpoint.isResponsesAPI ? "responses" : "chat/completions"
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any]
        if endpoint.isAnthropic {
            if let token { req.setValue(token, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "stream": true, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
        } else if endpoint.isResponsesAPI {
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "stream": true, "store": false, "instructions": system,
                    "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]]]
        } else {
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if endpoint == .openRouter { req.setValue("VoicePlus", forHTTPHeaderField: "X-Title") }
            body = ["model": model, "max_tokens": maxTokens, "stream": true, "temperature": 0.2,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (req, req.httpBody?.count ?? 0)
    }
}
