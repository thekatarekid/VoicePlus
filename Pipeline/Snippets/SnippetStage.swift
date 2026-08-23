import Foundation
import Shared

public extension StageID {
    /// P2.6 — spoken snippet expansion.
    static let snippet: StageID = "snippet"
}

/// Gatekeeper pre-route hook: an utterance that exactly matches a trigger is routed to
/// `.dictate` (so the snippet stage expands it) with full confidence, before any other rule
/// can claim it as a repair/transform/question. Register is left to the context.
public struct SnippetPreRoute: GatekeeperPreRouting {
    public let store: any SnippetStoring
    public init(store: any SnippetStoring) { self.store = store }

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard store.match(text) != nil else { return nil }
        return GatekeeperDecision(route: .dictate, register: context.register, routeConfidence: 1,
                                  registerConfidence: context.register == .unknown ? 0 : 1,
                                  routeSource: .rules, registerSource: context.register == .unknown ? .fallback : .context)
    }
}

/// Expands an exact trigger match into its body. Runs first among dictation stages so the
/// formatters/style never see the trigger word. The whole body lands on the first span; the
/// remaining spans are emptied but keep confidence/audioRange/provenance (Bet 9 contract).
/// If any span is low-confidence the trigger is not trusted: spans are flagged, not expanded.
public struct SnippetStage: PipelineStage {
    public let id: StageID = .snippet
    public let store: any SnippetStoring
    /// `StageContext.extra` key; "false" disables expansion for one run.
    public static let enabledKey = "snippet.enabled"

    public init(store: any SnippetStoring = InMemorySnippetStore()) { self.store = store }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard context.extra[Self.enabledKey] != "false", !spans.isEmpty,
              let snippet = store.match(spans.joinedText) else {
            return spans.map { $0.touched(by: id) }
        }
        if spans.contains(where: \.isLowConfidence) {
            return spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.touched(by: id) }
        }
        return spans.enumerated().map { i, span in span.rewritten(i == 0 ? snippet.body : "", by: id) }
    }

    /// True when `output` is `input` expanded by this stage.
    public static func didExpand(input: [TranscriptSpan], output: [TranscriptSpan]) -> Bool {
        guard let first = output.first, first.provenance.last == .snippet else { return false }
        return output.joinedText != input.joinedText
    }
}
