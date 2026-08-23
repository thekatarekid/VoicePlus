import Foundation
import Shared

/// What a transcriber returns for one fixture file.
public struct TranscriptionResult: Equatable, Sendable {
    public var spans: [TranscriptSpan]
    /// Wall-clock (or simulated) ASR latency for the file.
    public var latencyMs: Double

    public init(spans: [TranscriptSpan], latencyMs: Double) {
        self.spans = spans
        self.latencyMs = latencyMs
    }
}

/// The harness only needs "audio file in, spans out". Anything can conform: the real engine
/// (via `EngineFixtureTranscriber`), a cloud provider, or a scripted mock.
public protocol FixtureTranscriber: Sendable {
    var name: String { get }
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

/// Adapts any `EngineProtocol` to the harness. `EngineProtocol` has no file input, so the
/// engine-specific way of pushing a WAV (P1.3 exposes one) is injected as `feed`; it runs
/// between `start` and `stop`.
public final class EngineFixtureTranscriber: FixtureTranscriber, @unchecked Sendable {
    public let name: String
    public let engine: any EngineProtocol
    public let feed: @Sendable (URL) async throws -> Void
    private let clock: @Sendable () -> TimeInterval

    public init(name: String, engine: any EngineProtocol,
                clock: @escaping @Sendable () -> TimeInterval = LabClock.now,
                feed: @escaping @Sendable (URL) async throws -> Void) {
        self.name = name
        self.engine = engine
        self.clock = clock
        self.feed = feed
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        try await engine.prewarm()
        let t0 = clock()
        try await engine.start(prewarm: false)
        try await feed(audioURL)
        let spans = try await engine.stop()
        return TranscriptionResult(spans: spans, latencyMs: (clock() - t0) * 1000)
    }
}

/// Deterministic mock: hypotheses come from a `[file: text]` table or from a pure transform of
/// the reference transcript (looked up in `references`). Latency is a stable function of the file
/// name so runs are reproducible and percentiles are testable.
public struct ScriptedTranscriber: FixtureTranscriber {
    public var name: String
    public var hypotheses: [String: String]
    public var references: [String: String]
    public var transform: @Sendable (String, String) -> String
    public var confidence: Float
    public var baseLatencyMs: Double

    public init(name: String = "scripted", hypotheses: [String: String] = [:], references: [String: String] = [:],
                confidence: Float = 0.9, baseLatencyMs: Double = 120,
                transform: @escaping @Sendable (_ file: String, _ reference: String) -> String = { _, ref in ref }) {
        self.name = name
        self.hypotheses = hypotheses
        self.references = references
        self.confidence = confidence
        self.baseLatencyMs = baseLatencyMs
        self.transform = transform
    }

    /// A mock that returns the manifests' own transcripts (perfect ASR) unless overridden.
    public static func perfect(suites: [FixtureSuite], name: String = "perfect") -> ScriptedTranscriber {
        var refs: [String: String] = [:]
        for suite in suites { for item in suite.items { refs[item.file] = item.transcript } }
        return ScriptedTranscriber(name: name, references: refs)
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let file = audioURL.lastPathComponent
        let text: String
        if let hyp = hypotheses[file] {
            text = hyp
        } else if let ref = references[file] {
            text = transform(file, ref)
        } else {
            throw LabError.transcriberUnavailable("no scripted hypothesis for \(file)")
        }
        let words = text.split(separator: " ").map(String.init)
        let step = 0.4
        let spans = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: confidence, audioRange: (Double(i) * step)...(Double(i + 1) * step), provenance: [.asr])
        }
        let jitter = Double(StableHash.fnv1a(file) % 200)
        return TranscriptionResult(spans: spans, latencyMs: baseLatencyMs + jitter)
    }
}

public enum LabClock {
    /// Monotonic seconds.
    public static let now: @Sendable () -> TimeInterval = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Swift's `Hasher` is seeded per process; the Lab needs run-to-run stable hashes.
public enum StableHash {
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
