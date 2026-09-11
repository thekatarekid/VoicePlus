// VoicePlus original (task R5.2). The seam `RefineStage` sits on, plus the two stage IDs and the
// deadline primitive it needs.
import Foundation
import Shared

// MARK: - Stage identity

public extension StageID {
    /// The second (refinement) recognition pass — V3 §5.3.
    ///
    /// Same *identity* as `Engine`'s `StageID.refineQwen3` (both are `"refine.qwen3"`), declared
    /// here under a different member name on purpose: the `Pipeline` target does not depend on
    /// `Engine` (see `Package.swift`), and two modules declaring the same static member would be
    /// ambiguous wherever both are imported. Provenance written by either name compares equal.
    static let refine: StageID = "refine.qwen3"

    /// Marker appended next to `.refine` when the refined words are **not** the pass-1 words, so
    /// the span's `confidence` no longer describes its `text` (V3 §5.3: "never attach old
    /// confidence to different words … mark unavailable confidence explicitly").
    ///
    /// It is appended *before* `.refine` so `provenance.last` is still the stage id — the
    /// convention the rest of the repo reads (`SnippetStage.didExpand`, `AdaptationService`).
    static let refineConfidenceUnavailable: StageID = "refine.confidence-unavailable"
}

public extension TranscriptSpan {
    /// True when refinement replaced the words behind this span, so `confidence` measures text
    /// that is no longer here. Read this instead of trusting `confidence` on a refined span.
    var refinedConfidenceUnavailable: Bool { provenance.contains(.refineConfidenceUnavailable) }

    /// True when the refinement pass produced this span's text.
    var wasRefined: Bool { provenance.contains(.refine) }
}

// MARK: - The refiner seam

/// A second recognition pass over the audio of one segment.
///
/// Structurally identical to `RefinementSession` in `Engine/ASRRuntime/Qwen3ASR/` (R5.1) — same
/// method, same contract — but declared in `Pipeline` because `Pipeline` may not depend on
/// `Engine`. Wiring the real session in costs one expression and no adapter type:
///
/// ```swift
/// RefineStage(refiner: RefinerFunction(session.refine(samples:context:deadline:)), samples: pcm)
/// ```
///
/// Contract, unchanged from R5.1:
/// - `samples` are 16 kHz mono Float32, the same audio pass 1 saw, from the segment start.
/// - `context` is a plain-text prompt (screen text, lexicon, recent transcript). Never logged,
///   never persisted here.
/// - `deadline` is hard; on timeout throw. `RefineStage` enforces its own watchdog too and keeps
///   pass-1 text either way.
/// - Returned spans carry `audioRange` relative to the start of `samples`; they carry **no**
///   meaningful confidence.
public protocol SpanRefining: Sendable {
    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan]
}

/// A `SpanRefining` made from a function — how a `RefinementSession` from `Engine` is handed to
/// `RefineStage` without either module learning about the other.
public struct RefinerFunction: SpanRefining {
    private let body: @Sendable ([Float], String, Duration) async throws -> [TranscriptSpan]

    public init(_ body: @escaping @Sendable ([Float], String, Duration) async throws -> [TranscriptSpan]) {
        self.body = body
    }

    public func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        try await body(samples, context, deadline)
    }
}

// MARK: - Deadline

/// Thrown by `RefineStage`'s own watchdog when a pass overran its deadline. The stage catches
/// this itself and falls back to pass-1 text; it is public so callers can recognise it in logs.
public struct RefinementTimedOut: Error, CustomStringConvertible, Sendable {
    public let deadline: Duration
    public init(deadline: Duration) { self.deadline = deadline }
    public var description: String { "refinement pass exceeded its \(deadline) deadline" }
}

public enum RefinementClock {
    /// Milliseconds, for reports and comparisons.
    public static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    /// Run `body` with a hard deadline: on timeout the work is cancelled and
    /// `RefinementTimedOut` is thrown.
    ///
    /// `RefineStage` does not trust the injected session to police its own deadline — a pass that
    /// hangs inside CoreML would otherwise hold the commit path open past the V3 §10.2 budget.
    public static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard deadline > .zero else { throw RefinementTimedOut(deadline: deadline) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            while let finished = try await group.next() {
                group.cancelAll()
                guard let value = finished else { throw RefinementTimedOut(deadline: deadline) }
                return value
            }
            throw RefinementTimedOut(deadline: deadline)
        }
    }
}
