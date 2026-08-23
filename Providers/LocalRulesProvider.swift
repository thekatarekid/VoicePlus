import Foundation
import Shared

/// Deterministic, zero-model fallback. Always available, always on-device. When every
/// other provider fails, this completes the stage so the pipeline never stalls.
/// It only does safe, register-agnostic cleanup: whitespace, sentence capitalisation,
/// terminal period, and basic spoken-punctuation tokens.
public struct LocalRulesProvider: Provider {
    public let id: ProviderID = "local.rules"
    public let displayName = "Built-in rules (offline)"
    public let capabilities: ProviderCapabilities = [.pipeline]
    public let costClass: CostClass = .free
    public let privacyClass: PrivacyClass = .onDevice
    public init() {}

    public func isAvailable() async -> Bool { true }

    public func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion {
        var out: [TranscriptSpan] = []
        var atSentenceStart = true
        for span in spans {
            if span.isLowConfidence {
                out.append(span.flaggedForRepair(by: stage)); atSentenceStart = false; continue
            }
            var t = span.text.trimmingCharacters(in: .whitespaces)
            t = Self.punctuationTokens[t.lowercased()] ?? t
            if atSentenceStart, let f = t.first, f.isLetter { t = f.uppercased() + t.dropFirst() }
            atSentenceStart = t.last.map { ".!?".contains($0) } ?? atSentenceStart
            out.append(span.rewritten(t, by: stage))
        }
        if stage != .gatekeeper, let lastIdx = out.indices.last(where: { !out[$0].needsRepair && !out[$0].text.isEmpty }),
           let last = out[lastIdx].text.last, !".!?,;:".contains(last), context.register != .code, context.register != .terminal {
            out[lastIdx].text += "."
        }
        return ProviderCompletion(spans: out)
    }

    static let punctuationTokens: [String: String] = [
        "period": ".", "full stop": ".", "comma": ",", "question mark": "?", "exclamation mark": "!", "exclamation point": "!",
    ]
}
