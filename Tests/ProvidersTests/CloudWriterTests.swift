import Foundation
import Shared
import Testing
@testable import Providers

/// Context Writer §5 — the cloud backend over OpenRouter: request shape, streaming to a string,
/// the network log (bytes, never text), the deadline, and the key-down prewarm.
@Suite("Context Writer cloud backend", .serialized)
struct CloudWriterTests {
    static let host = "openrouter.ai"
    static let keyName = SecretKey.apiKey(APIEndpoint.openRouter.providerID)

    static func generator(_ config: CloudWriterConfig = CloudWriterConfig(), key: String? = "sk-or-test",
                          logger: InMemoryNetworkLogger = InMemoryNetworkLogger(),
                          session: URLSession = StubURLProtocol.session()) -> CloudWriterGenerator {
        let secrets = InMemorySecretStore(key.map { [keyName: $0] } ?? [:])
        return CloudWriterGenerator(config: config, secrets: secrets, session: session, logger: logger)
    }

    static func lastBody() throws -> [String: Any] {
        let req = try #require(StubURLProtocol.lastRequest(host: host))
        let data = try #require(req.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func keyNameIsTheExistingOpenRouterSecret() {
        #expect(Self.keyName == "apikey.api.openrouter")
    }

    @Test func requestBodyShape() async throws {
        StubURLProtocol.register(host: Self.host) { _ in (200, sse(["ok"]), ["Content-Type": "text/event-stream"]) }
        let g = Self.generator(CloudWriterConfig(providerOrder: ["together", "baseten"]))
        _ = try await g.write(system: "S", user: "U")

        let req = try #require(StubURLProtocol.lastRequest(host: Self.host))
        #expect(req.url?.path == "/api/v1/chat/completions")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(req.value(forHTTPHeaderField: "X-Title") == "VoicePlus")

        let body = try Self.lastBody()
        #expect(body["model"] as? String == "deepseek/deepseek-v4.1-flash")
        #expect(body["models"] as? [String] == ["deepseek/deepseek-v4.1-flash", "google/gemma-4-26b-a4b-it", "openai/gpt-6-luna"])
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["sort"] as? String == "latency")
        #expect(provider["allow_fallbacks"] as? Bool == true)
        #expect(provider["order"] as? [String] == ["together", "baseten"])
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0)
        #expect(body["max_tokens"] as? Int == 400)
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "S"], ["role": "user", "content": "U"]])
    }

    @Test func noPinsMeansNoOrderAndNoDuplicateFallback() async throws {
        StubURLProtocol.register(host: Self.host) { _ in (200, sse(["x"]), [:]) }
        let g = Self.generator(CloudWriterConfig(model: "m/a", fallbackModels: ["m/a", "m/b"]))
        _ = try await g.write(system: "S", user: "U")
        let body = try Self.lastBody()
        #expect((body["provider"] as? [String: Any])?["order"] == nil)
        #expect(body["models"] as? [String] == ["m/a", "m/b"])
    }

    @Test func streamsToOneStringAndLogsBytesOnly() async throws {
        StubURLProtocol.register(host: Self.host) { _ in (200, sse(["Hello ", "Kothari", "."]), [:]) }
        let logger = InMemoryNetworkLogger()
        let g = Self.generator(logger: logger)
        let out = try await g.write(system: "S", user: "hello kothari")
        #expect(out == "Hello Kothari.")
        let record = try #require(logger.records.last)
        #expect(record.stage == "writer")
        #expect(record.purpose == "writer")
        #expect(record.provider == "api.openrouter")
        #expect(record.host == Self.host)
        #expect(record.bytesOut > 0 && record.bytesIn > 0)
        let dump = "\(record)"
        #expect(!dump.contains("kothari") && !dump.contains("Kothari"))
    }

    @Test func timeoutPath() async throws {
        final class SlowProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                    cacheStoragePolicy: .notAllowed)
                // never finishes
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SlowProtocol.self]
        let logger = InMemoryNetworkLogger()
        let g = Self.generator(CloudWriterConfig(timeout: 0.3), logger: logger, session: URLSession(configuration: cfg))
        let t0 = Date()
        await #expect(throws: ProviderError.timeout) { _ = try await g.write(system: "S", user: "U") }
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(logger.records.last?.purpose == "writer (failed: timeout)")
    }

    @Test func noKeyIsUnauthorizedAndNeverSends() async throws {
        let g = Self.generator(key: nil)
        #expect(await g.isAvailable() == false)
        await #expect(throws: ProviderError.unauthorized) { _ = try await g.write(system: "S", user: "U") }
    }

    @Test func egressKillSwitchBlocks() async throws {
        var g = Self.generator()
        g.egressAllowed = { _ in false }
        #expect(await g.isAvailable() == false)
        await #expect(throws: ProviderError.unavailable("blocked by egress kill switch")) {
            _ = try await g.write(system: "S", user: "U")
        }
    }

    @Test func prewarmOpensOnceAndIsRateLimited() async throws {
        let marker = "prewarm-\(UUID().uuidString)"
        StubURLProtocol.register(host: Self.host) { req in
            req.url?.path.hasSuffix("auth/key") == true ? (200, Data("{\"data\":{\"label\":\"\(marker)\"}}".utf8), [:]) : (404, Data(), [:])
        }
        let logger = InMemoryNetworkLogger()
        let g = Self.generator(CloudWriterConfig(prewarmInterval: 60), logger: logger)
        await g.prewarm()
        await g.prewarm()
        let records = logger.records.filter { $0.purpose == "writer.prewarm" }
        #expect(records.count == 1)
        #expect(records.first?.bytesOut == 0 && (records.first?.bytesIn ?? 0) > 0)
        let req = try #require(StubURLProtocol.lastRequest(host: Self.host))
        #expect(req.url?.path == "/api/v1/auth/key")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
    }

    @Test func prewarmWithoutKeySendsNothing() async {
        let logger = InMemoryNetworkLogger()
        let g = Self.generator(key: nil, logger: logger)
        await g.prewarm()
        #expect(logger.records.isEmpty)
    }

    @Test func discoveryDefaultsAreCurrent() {
        #expect(CloudWriterConfig.defaultModel == "deepseek/deepseek-v4.1-flash")
        #expect(CloudWriterConfig.defaultFallbacks == ["google/gemma-4-26b-a4b-it", "openai/gpt-6-luna"])
        #expect(CloudWriterConfig.defaultTimeout == 2.5)
    }
}
