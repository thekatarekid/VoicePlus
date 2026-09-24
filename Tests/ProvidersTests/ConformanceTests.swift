import Foundation
import Testing
import Shared
@testable import Providers

/// Every provider must: keep span count, never drop audioRange/confidence, append provenance,
/// never rewrite low-confidence spans (Bet 9).
func assertConformance(_ p: any Provider, stage: StageID = .style) async throws {
    let out = try await p.complete(stage: stage, spans: sampleSpans, context: StageContext(register: .chat))
    #expect(out.spans.count == sampleSpans.count)
    #expect(ConfidenceContract.verify(input: sampleSpans, output: out.spans) == [])
    #expect(out.spans[1].text == "kothari" && out.spans[1].needsRepair)
    for s in out.spans { #expect(s.provenance.last == stage) }
}

@Suite(.serialized) struct ConformanceTests {
    @Test func localRulesConforms() async throws {
        let p = LocalRulesProvider()
        #expect(await p.isAvailable())
        #expect(p.privacyClass == .onDevice && p.costClass == .free)
        try await assertConformance(p)
        let out = try await p.complete(stage: .style, spans: sampleSpans, context: StageContext(register: .chat))
        #expect(out.spans.map(\.text) == ["Hello", "kothari", "there."])
    }

    @Test func localRulesSpokenPunctuationAndCodeRegister() async throws {
        let spans = [TranscriptSpan(text: "let x", confidence: 0.9, audioRange: 0...1), TranscriptSpan(text: "period", confidence: 0.9, audioRange: 1...2)]
        let out = try await LocalRulesProvider().complete(stage: .formatterCode, spans: spans, context: StageContext(register: .code))
        #expect(out.spans.map(\.text) == ["Let x", "."])
    }

    @Test func openAICompatibleStreamsAndConforms() async throws {
        StubURLProtocol.register(host: "openrouter.ai") { _ in (200, sse(["Hello", " ⟦kothari⟧", " there"]), ["Content-Type": "text/event-stream"]) }
        let secrets = InMemorySecretStore([SecretKey.apiKey("api.openrouter"): "sk-test"])
        let c = OpenAICompatibleClient(endpoint: .openRouter, model: "m", secrets: secrets, session: StubURLProtocol.session())
        #expect(await c.isAvailable())
        #expect(c.privacyClass == .cloud && c.costClass == .metered)
        try await assertConformance(c)
        let out = try await c.complete(stage: .style, spans: sampleSpans, context: StageContext())
        #expect(out.spans.map(\.text) == ["Hello", "kothari", "there"])
        #expect(out.bytesOut > 0 && out.bytesIn > 0 && out.host == "openrouter.ai")
        let req = try #require(StubURLProtocol.lastRequest(host: "openrouter.ai"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.url?.path == "/api/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: req.bodyData!) as! [String: Any]
        #expect(body["stream"] as? Bool == true)
    }

    @Test func anthropicMessagesWireFormat() async throws {
        StubURLProtocol.register(host: "api.anthropic.com") { _ in (200, sse(["Hello", " kothari there"], anthropic: true), [:]) }
        let c = OpenAICompatibleClient(endpoint: .anthropic, model: "claude", secrets: InMemorySecretStore([SecretKey.apiKey("api.anthropic"): "ak"]), session: StubURLProtocol.session())
        try await assertConformance(c)
        let req = try #require(StubURLProtocol.lastRequest(host: "api.anthropic.com"))
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "ak")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") != nil)
        #expect(req.url?.path == "/v1/messages")
        let body = try JSONSerialization.jsonObject(with: req.bodyData!) as! [String: Any]
        #expect(body["system"] is String)
    }

    @Test func chatGPTResponsesWireFormat() async throws {
        StubURLProtocol.register(host: "chatgpt.com") { _ in (200, sse(["Hello kothari there"], responses: true), [:]) }
        struct Fixed: TokenSource { func accessToken() async throws -> String? { "tok" } }
        let c = OpenAICompatibleClient(endpoint: .chatGPT, model: "gpt-5", tokenSource: Fixed(), session: StubURLProtocol.session())
        #expect(c.costClass == .subscription)
        try await assertConformance(c)
        #expect(StubURLProtocol.lastRequest(host: "chatgpt.com")?.url?.path == "/backend-api/codex/responses")
    }

    @Test func missingKeyIsUnauthorizedAndUnavailable() async throws {
        let c = OpenAICompatibleClient(endpoint: .groq, model: "m", secrets: InMemorySecretStore(), session: StubURLProtocol.session())
        #expect(await c.isAvailable() == false)
        await #expect(throws: ProviderError.unauthorized) { _ = try await c.generate(prompt: "x", system: "s", stage: .style) }
    }

    @Test func http401And500AreTyped() async throws {
        StubURLProtocol.register(host: "api.groq.com") { _ in (401, Data(), [:]) }
        let s = InMemorySecretStore([SecretKey.apiKey("api.groq"): "k", SecretKey.apiKey("api.cerebras"): "k"])
        let c = OpenAICompatibleClient(endpoint: .groq, model: "m", secrets: s, session: StubURLProtocol.session())
        await #expect(throws: ProviderError.unauthorized) { _ = try await c.generate(prompt: "x", system: "s", stage: .style) }
        StubURLProtocol.register(host: "api.cerebras.ai") { _ in (500, Data("boom".utf8), [:]) }
        let c2 = OpenAICompatibleClient(endpoint: .cerebras, model: "m", secrets: s, session: StubURLProtocol.session())
        await #expect(throws: ProviderError.http(500, "boom")) { _ = try await c2.generate(prompt: "x", system: "s", stage: .style) }
    }

    @Test func timeoutFires() async throws {
        final class SlowProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                // never finishes
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [SlowProtocol.self]
        let c = OpenAICompatibleClient(endpoint: .custom(baseURL: URL(string: "http://slow.test/v1")!, name: "slow"), model: "m",
                                       secrets: InMemorySecretStore(), session: URLSession(configuration: cfg), timeout: 0.3)
        let t0 = Date()
        await #expect(throws: ProviderError.timeout) { _ = try await c.generate(prompt: "x", system: "s", stage: .style) }
        #expect(Date().timeIntervalSince(t0) < 3)
    }

    @Test func localServerDetectionParsesBothShapes() async throws {
        StubURLProtocol.register(host: "127.0.0.1") { req in
            if req.url?.port == 11434 { return (200, Data(#"{"models":[{"name":"llama3.2:3b"},{"name":"qwen2.5"}]}"#.utf8), [:]) }
            if req.url?.port == 1234 { return (200, Data(#"{"data":[{"id":"lmstudio-community/gemma"}]}"#.utf8), [:]) }
            return (404, Data(), [:])
        }
        let found = await LocalServerDetector(session: StubURLProtocol.session()).detect()
        #expect(found.count == 2)
        #expect(found.first { $0.kind == .ollama }?.models == ["llama3.2:3b", "qwen2.5"])
        #expect(found.first { $0.kind == .lmStudio }?.models == ["lmstudio-community/gemma"])
        let p = LocalServerProvider(info: found[0], session: StubURLProtocol.session())
        #expect(p.privacyClass == .localNetwork && p.costClass == .free && p.id.rawValue == "local.lmStudio")
        #expect(await p.isAvailable())
    }

    @Test func localServerAbsentIsNotDetected() async {
        StubURLProtocol.register(host: "127.0.0.1") { _ in (404, Data(), [:]) }
        let found = await LocalServerDetector(session: StubURLProtocol.session()).detect()
        #expect(found.isEmpty)
    }

    @Test func localServerCompletesViaOpenAIPathWithoutAuth() async throws {
        StubURLProtocol.register(host: "127.0.0.1") { req in
            if req.url?.path == "/v1/chat/completions" { return (200, sse(["Hello kothari there"]), [:]) }
            return (200, Data(#"{"models":[]}"#.utf8), [:])
        }
        let p = LocalServerProvider(info: LocalServerInfo(kind: .ollama, baseURL: LocalServerKind.ollama.defaultBaseURL, models: ["llama"]), session: StubURLProtocol.session())
        try await assertConformance(p)
        #expect(StubURLProtocol.lastRequest(host: "127.0.0.1")?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func cloudASRSlotIsGatedAndHonest() async throws {
        let p = CloudASRProvider(secrets: InMemorySecretStore())
        #expect(p.capabilities == [.asr] && !p.capabilities.contains(.pipeline))
        #expect(await p.isAvailable() == false)
        await #expect(throws: ProviderError.flagDisabled("cloudASR")) { _ = try await p.complete(stage: .asr, spans: [], context: StageContext()) }
        #expect(CloudASRCopy.warning.contains("disables repair & context features"))
        #expect(OAuthCopy.subscriptionsDoNotHelpASR.contains("does not improve speech recognition"))
        #expect(CLICopy.usesExistingSubscription == "Uses your existing subscription")
    }

    @Test func spanRewriterPlacesWholeTextOnFirstHighConfidenceSpanWhenCountsDiffer() {
        let out = SpanRewriter.apply(text: "Hello, there!", to: sampleSpans, by: .style)
        #expect(out.map(\.text) == ["Hello, there!", "kothari", ""])
        #expect(out[1].needsRepair)
        #expect(ConfidenceContract.verify(input: sampleSpans, output: out) == [])
    }

    // Keychain requests and error propagation are exercised by
    // ProvidersNoninteractiveKeychainTests using injected Security calls. No user Keychain access.

}
