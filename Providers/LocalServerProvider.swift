import Foundation
import Shared

/// Ollama / LM Studio: localhost HTTP servers with no auth header (FluidVoice pattern,
/// reimplemented). Detection probes `/api/tags` (Ollama) and `/v1/models` (LM Studio).
public enum LocalServerKind: String, Codable, Sendable, CaseIterable {
    case ollama, lmStudio

    public var defaultBaseURL: URL {
        switch self {
        case .ollama: URL(string: "http://127.0.0.1:11434")!
        case .lmStudio: URL(string: "http://127.0.0.1:1234")!
        }
    }
    var probePath: String { self == .ollama ? "/api/tags" : "/v1/models" }
    public var displayName: String { self == .ollama ? "Ollama" : "LM Studio" }
}

public struct LocalServerInfo: Sendable, Equatable {
    public var kind: LocalServerKind
    public var baseURL: URL
    public var models: [String]
}

/// Probes both servers concurrently with a short timeout.
public struct LocalServerDetector: Sendable {
    public var session: URLSession
    public var baseURLs: [LocalServerKind: URL]
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, baseURLs: [LocalServerKind: URL] = [:], timeout: TimeInterval = 1.0) {
        self.session = session; self.baseURLs = baseURLs; self.timeout = timeout
    }

    public func detect() async -> [LocalServerInfo] {
        await withTaskGroup(of: LocalServerInfo?.self) { group in
            for kind in LocalServerKind.allCases { group.addTask { await probe(kind) } }
            var found: [LocalServerInfo] = []
            for await info in group { if let info { found.append(info) } }
            return found.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    public func probe(_ kind: LocalServerKind) async -> LocalServerInfo? {
        let base = baseURLs[kind] ?? kind.defaultBaseURL
        var req = URLRequest(url: base.appendingPathComponent(kind.probePath), timeoutInterval: timeout)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let models: [String]
        switch kind {
        case .ollama: models = (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        case .lmStudio: models = (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        return LocalServerInfo(kind: kind, baseURL: base, models: models)
    }
}

/// A detected local server exposed as a provider. Both speak the OpenAI chat API
/// (`/v1/chat/completions`), so this reuses the OpenAI-compatible client with no key.
public struct LocalServerProvider: TextGenerator {
    public let info: LocalServerInfo
    public let model: String
    public let client: OpenAICompatibleClient

    public init(info: LocalServerInfo, model: String? = nil, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.info = info
        self.model = model ?? info.models.first ?? "default"
        self.client = OpenAICompatibleClient(
            endpoint: .custom(baseURL: info.baseURL.appendingPathComponent("v1"), name: info.kind.rawValue),
            model: self.model, secrets: InMemorySecretStore(), session: session, timeout: timeout
        )
    }

    public var id: ProviderID { ProviderID(rawValue: "local.\(info.kind.rawValue)") }
    public var displayName: String { "\(info.kind.displayName) · \(model)" }
    public var capabilities: ProviderCapabilities { [.pipeline, .streaming] }
    public var costClass: CostClass { .free }
    public var privacyClass: PrivacyClass { .localNetwork }

    public func isAvailable() async -> Bool {
        await LocalServerDetector(session: client.session, baseURLs: [info.kind: info.baseURL]).probe(info.kind) != nil
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        try await client.generate(prompt: prompt, system: system, stage: stage)
    }
}
