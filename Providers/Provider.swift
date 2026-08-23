import Foundation
import Shared

/// What a provider can do. ASR (audio in) and pipeline (text in) are distinct —
/// subscriptions and CLIs are pipeline-only (PRODUCT-SPEC Part 4.6).
public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let asr = ProviderCapabilities(rawValue: 1 << 0)
    public static let pipeline = ProviderCapabilities(rawValue: 1 << 1)
    public static let streaming = ProviderCapabilities(rawValue: 1 << 2)
}

public enum CostClass: String, Codable, Sendable { case free, subscription, metered }

/// Where the text goes. `onDevice` never leaves the machine; `localNetwork` stays on
/// localhost (Ollama / LM Studio); `cloud` is logged to the Data Panel on every call.
public enum PrivacyClass: String, Codable, Sendable, Comparable {
    case onDevice, localNetwork, cloud
    private var rank: Int { switch self { case .onDevice: 0; case .localNetwork: 1; case .cloud: 2 } }
    public static func < (a: PrivacyClass, b: PrivacyClass) -> Bool { a.rank < b.rank }
}

public enum ProviderError: Error, Equatable, Sendable {
    case unavailable(String)
    case unauthorized
    case timeout
    case http(Int, String)
    case malformedResponse(String)
    case cancelled
    case capabilityMissing(String)
    case flagDisabled(String)
}

/// Stable identity shown in the Data Panel and routing table.
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral v: String) { rawValue = v }
    public var description: String { rawValue }
}

/// Result of a pipeline completion. `bytesOut`/`bytesIn` feed the network log.
public struct ProviderCompletion: Sendable, Equatable {
    public var spans: [TranscriptSpan]
    public var bytesOut: Int
    public var bytesIn: Int
    public var host: String
    public init(spans: [TranscriptSpan], bytesOut: Int = 0, bytesIn: Int = 0, host: String = "localhost") {
        self.spans = spans; self.bytesOut = bytesOut; self.bytesIn = bytesIn; self.host = host
    }
}

/// T1. Every model-access path conforms to this. `complete` honours the Bet 9 contract:
/// low-confidence spans are flagged, never rewritten (`SpanRewriter` does this for all providers).
public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var costClass: CostClass { get }
    var privacyClass: PrivacyClass { get }
    /// Cheap liveness check (binary exists, server answers, key present). Never throws.
    func isAvailable() async -> Bool
    func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion
}

public extension Provider {
    var isRemote: Bool { privacyClass == .cloud }
}

/// Text-in/text-out core shared by every LLM-backed provider. Conformers implement
/// `generate`; `complete` is derived and enforces the confidence contract.
public protocol TextGenerator: Provider {
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String)
}

public extension TextGenerator {
    func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion {
        guard capabilities.contains(.pipeline) else { throw ProviderError.capabilityMissing("pipeline") }
        let prompt = PromptBuilder.prompt(stage: stage, spans: spans, context: context)
        let system = PromptBuilder.system(stage: stage, context: context)
        let out = try await generate(prompt: prompt, system: system, stage: stage)
        let spans = SpanRewriter.apply(text: out.text, to: spans, by: stage)
        return ProviderCompletion(spans: spans, bytesOut: out.bytesOut, bytesIn: out.bytesIn, host: out.host)
    }
}

/// Builds the stage prompt. Low-confidence spans are sent verbatim and marked so the
/// model does not "fix" them — the rewriter refuses to touch them anyway.
public enum PromptBuilder {
    public static func system(stage: StageID, context: StageContext) -> String {
        var s = "You are a dictation post-processor for stage '\(stage.rawValue)'. Register: \(context.register.rawValue). "
        s += "Return ONLY the corrected text, no commentary. Preserve meaning. Text inside ⟦⟧ is uncertain: copy it exactly."
        if let persona = context.extra["persona"] { s += " Style: \(persona)" }
        return s
    }
    public static func prompt(stage: StageID, spans: [TranscriptSpan], context: StageContext) -> String {
        spans.map { $0.isLowConfidence ? "⟦\($0.text)⟧" : $0.text }.joined(separator: " ")
    }
}

/// Maps a single rewritten string back onto spans without dropping confidence/audioRange.
/// Strategy: if the token count matches, rewrite 1:1; otherwise the whole text is placed
/// on the first high-confidence span and the rest keep their text but gain provenance.
/// Low-confidence spans are never rewritten (Bet 9).
public enum SpanRewriter {
    public static func apply(text: String, to spans: [TranscriptSpan], by stage: StageID) -> [TranscriptSpan] {
        let cleaned = text.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spans.isEmpty, !cleaned.isEmpty else { return spans.map { $0.touched(by: stage) } }
        let words = cleaned.split(separator: " ").map(String.init)
        if words.count == spans.count {
            return zip(spans, words).map { span, w in
                span.isLowConfidence ? span.flaggedForRepair(by: stage) : span.rewritten(w, by: stage)
            }
        }
        var out: [TranscriptSpan] = []
        var placed = false
        for span in spans {
            if span.isLowConfidence { out.append(span.flaggedForRepair(by: stage)); continue }
            if !placed { out.append(span.rewritten(cleaned, by: stage)); placed = true }
            else { out.append(span.rewritten("", by: stage)) }
        }
        return out
    }
}
