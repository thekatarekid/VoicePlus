import Foundation
import Shared

// MARK: - Context Writer · transcribe mode (plan §1, §4.6)
//
// The model call behind `ContextWriterStage`. One rendered prompt (system + user, from
// `WriterPrompt.render(packet:profile:)`) goes in; the corrected text — or the reserved reply
// `UNCHANGED` — comes back. Streaming is not needed here: the stage lands the whole sentence at
// once (one landing, plan §4). The app's conformer routes through the Providers backends
// (cloud BYOK / local fine-tune); Lab and tests inject a scripted generator.

public protocol WriterGenerating: Sendable {
    func write(system: String, user: String, context: StageContext) async throws -> String
}

/// What one run did — reason codes only, never text (Q13). Mirrors `CleanupOutcome` so the
/// "Why did it write that?" sheet and the Lab suite can treat both stages alike.
public enum WriterOutcome: Sendable, Equatable {
    case skipped(String)
    case accepted(ms: Double)
    /// The model answered `UNCHANGED`, or returned the heard text verbatim.
    case unchanged(ms: Double)
    /// Some changed regions failed the per-change guard and were put back; the rest landed.
    case partiallyReverted(Int, ms: Double)
    case rejected(WriterGuard.Rejection, ms: Double)
    case timedOut(ms: Double)
    case failed(String, ms: Double)

    public var code: String {
        switch self {
        case .skipped(let why): return "skipped:\(why)"
        case .accepted: return "accepted"
        case .unchanged: return "unchanged"
        case .partiallyReverted(let n, _): return "partiallyReverted:\(n)"
        case .rejected(let r, _): return "rejected:\(r.rawValue)"
        case .timedOut: return "timeout"
        case .failed(let why, _): return "failed:\(why)"
        }
    }

    /// True when the model's text (all or part of it) reached the spans.
    public var landed: Bool {
        switch self {
        case .accepted, .partiallyReverted: return true
        default: return false
        }
    }
}
