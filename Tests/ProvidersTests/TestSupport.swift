import Foundation
import Shared
@testable import Providers

/// URLProtocol stub keyed by host+path prefix. Emits SSE bodies through the normal client path
/// so `URLSession.bytes(for:)` streaming works.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data, headers: [String: String])
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) static var requests: [(URLRequest, Data?)] = []
    static let lock = NSLock()

    static func register(host: String, _ h: @escaping Handler) { lock.lock(); handlers[host] = h; lock.unlock() }
    static func lastRequest(host: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        guard var r = requests.last(where: { $0.0.url?.host == host }) else { return nil }
        r.0.httpBody = r.1; return r.0
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        let body = request.bodyData
        Self.requests.append((request, body))
        let handler = Self.handlers[host] ?? Self.handlers["*"]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        var captured = request; captured.httpBody = body
        let r = handler(captured)
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLRequest {
    var bodyData: Data? {
        if let b = httpBody { return b }
        guard let s = httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        return d
    }
}

func sse(_ chunks: [String], anthropic: Bool = false, responses: Bool = false) -> Data {
    var s = ""
    for c in chunks {
        let json: String
        if anthropic { json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(c)"}}"# }
        else if responses { json = #"{"type":"response.output_text.delta","delta":"\#(c)"}"# }
        else { json = #"{"choices":[{"delta":{"content":"\#(c)"}}]}"# }
        s += "data: \(json)\n\n"
    }
    s += "data: [DONE]\n\n"
    return Data(s.utf8)
}

let sampleSpans: [TranscriptSpan] = [
    TranscriptSpan(text: "hello", confidence: 0.95, audioRange: 0...0.4, provenance: [.asr]),
    TranscriptSpan(text: "kothari", confidence: 0.3, audioRange: 0.4...1.0, provenance: [.asr]),
    TranscriptSpan(text: "there", confidence: 0.9, audioRange: 1.0...1.5, provenance: [.asr]),
]

/// Test double that can be made to fail mid-call.
struct FlakyProvider: Provider {
    var id: ProviderID = "mock.flaky"
    var displayName = "Flaky"
    var capabilities: ProviderCapabilities = [.pipeline]
    var costClass: CostClass = .metered
    var privacyClass: PrivacyClass = .cloud
    var available = true
    var error: ProviderError? = nil
    var text = "Hello there"
    func isAvailable() async -> Bool { available }
    func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion {
        if let error { throw error }
        return ProviderCompletion(spans: SpanRewriter.apply(text: text, to: spans, by: stage), bytesOut: 10, bytesIn: 20, host: "mock.example")
    }
}
