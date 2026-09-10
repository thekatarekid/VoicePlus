// VoicePlus original (task R5.1). Not ported code — this is the seam between the Qwen3-ASR
// port in this directory and the pipeline. `Qwen3RefinementSession` implements it with the port;
// `MockRefinementSession` implements it with no weights at all.
import Foundation
import Shared

// MARK: - Stage identity

extension StageID {
    /// The second (refinement) recognition pass. `StageID` is string-backed precisely so a new
    /// stage can be named without touching `Shared/` (see `Shared/Types/StageID.swift`).
    public static let refineQwen3: StageID = "refine.qwen3"
}

// MARK: - Errors

public enum RefinementError: Error, LocalizedError, Equatable {
    /// The refinement backend cannot run on this machine at all: macOS 14 (the CoreML stateful
    /// decoder the port needs is macOS 15+), or a non-arm64 Mac (Float16 embedding lookup).
    case unavailableOnThisSystem(String)
    /// No usable weights directory. `searched` are the paths that were looked at, in order.
    case weightsMissing(searched: [String])
    /// The weights directory exists but is not a complete model.
    case weightsIncomplete(path: String, problems: [String])
    /// The pass did not finish inside `deadline`. Callers fall back to pass-1 text (V3 §5.3).
    case deadlineExceeded(Duration)
    case emptyAudio
    /// Anything the backend itself threw, already described.
    case backendFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOnThisSystem(let why):
            return "Refinement isn\u{2019}t available on this Mac: \(why)"
        case .weightsMissing:
            return "The refinement model isn\u{2019}t installed yet."
        case .weightsIncomplete(_, let problems):
            let detail = problems.count == 1 ? "1 file" : "\(problems.count) files"
            return "The refinement model didn\u{2019}t finish downloading \u{2014} \(detail) are missing or incomplete."
        case .deadlineExceeded:
            return "Refinement ran out of time; the first-pass text was used."
        case .emptyAudio:
            return "There was no audio to refine."
        case .backendFailure(let detail):
            return "Refinement failed: \(detail)"
        }
    }
}

// MARK: - Protocol

/// A second recognition pass over the audio of one segment.
///
/// Contract, in the order the wave-2 `RefineStage` (R5.2) needs it:
/// - `samples` are 16 kHz mono Float32, the same audio pass 1 saw, starting at the segment start.
/// - `context` is plain text put in front of the model as a prompt (screen text, learned lexicon,
///   recent transcript). Never persisted here; never logged.
/// - `deadline` is hard. On timeout the implementation throws `RefinementError.deadlineExceeded`
///   and the caller keeps pass-1 text. Cancelling the calling task cancels the pass.
/// - Returned spans carry `audioRange` **relative to the start of `samples`** and have
///   `StageID.refineQwen3` appended to `provenance`. They do **not** carry a real confidence:
///   see `Refinement.confidenceNotReported`.
public protocol RefinementSession: Sendable {
    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan]
}

extension RefinementSession {
    /// Refine the audio behind an existing span, in place.
    ///
    /// This is the shape `RefineStage` wants: `span.audioRange`, `alternates`, `stability` and
    /// `confidence` are the pass-1 span's and survive untouched; only `text` changes, and
    /// `StageID.refineQwen3` is appended to `provenance`. Refinement reports no confidence of its
    /// own, so pass-1's is kept rather than replaced with a made-up number (V3 §5.3).
    public func refine(
        span: TranscriptSpan,
        samples: [Float],
        context: String,
        deadline: Duration
    ) async throws -> TranscriptSpan {
        let refined = try await refine(samples: samples, context: context, deadline: deadline)
        let text = refined.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return span.touched(by: .refineQwen3) }
        return span.rewritten(text, by: .refineQwen3)
    }
}

// MARK: - Shared helpers

public enum Refinement {
    public static let sampleRate = 16_000

    /// What a refined span's `confidence` means: **nothing**. Qwen3-ASR emits no per-span
    /// confidence, and V3 §5.3 says unavailable confidence must be marked, not invented. Stages
    /// that need a confidence must use the pass-1 span's — `refine(span:…)` above does that.
    public static let confidenceNotReported: Float = 0

    public static func seconds(sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / Double(sampleRate)
    }

    /// `0…duration` of the audio handed in. Never an empty or reversed range.
    public static func audioRange(sampleCount: Int) -> ClosedRange<TimeInterval> {
        0...max(seconds(sampleCount: sampleCount), 0)
    }

    /// One span for a whole segment: the model gives text, not word timings, so the span covers
    /// the segment's whole audio range. Re-aligning word timing is R5.2's job.
    public static func span(text: String, sampleCount: Int) -> TranscriptSpan {
        TranscriptSpan(
            text: text,
            confidence: confidenceNotReported,
            audioRange: audioRange(sampleCount: sampleCount),
            provenance: [.refineQwen3]
        )
    }

    /// Run `body` with a hard deadline. On timeout: cancel `body`, throw `.deadlineExceeded`.
    ///
    /// Cancellation is cooperative — the CoreML decode loop in `Qwen3AsrManager` checks it once
    /// per generated token, so the work stops within roughly one token of the deadline rather
    /// than at it. A cancelled *caller* propagates `CancellationError`, not a deadline error.
    public static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard deadline > .zero else { throw RefinementError.deadlineExceeded(deadline) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            while let finished = try await group.next() {
                group.cancelAll()
                guard let value = finished else { throw RefinementError.deadlineExceeded(deadline) }
                return value
            }
            throw RefinementError.deadlineExceeded(deadline)
        }
    }
}

// MARK: - Mock

/// A `RefinementSession` with no model behind it: deterministic text, a configurable amount of
/// simulated model time, and the same deadline/cancellation behaviour as the real one. This is
/// what `PipelineTests` should build `RefineStage` against — it needs no 1.2 GB of weights.
public struct MockRefinementSession: RefinementSession {
    /// Fixed output text. `nil` means "synthesize deterministically from the input".
    public let text: String?
    /// Simulated model time. Slept in a cancellable way, so `work > deadline` times out.
    public let work: Duration
    /// Thrown instead of doing any work, for error-path tests.
    public let failure: RefinementError?

    public init(text: String? = nil, work: Duration = .zero, failure: RefinementError? = nil) {
        self.text = text
        self.work = work
        self.failure = failure
    }

    /// Deterministic stand-in transcript: same input, same string, every run and every machine.
    public static func syntheticText(sampleCount: Int, context: String) -> String {
        let seconds = Refinement.seconds(sampleCount: sampleCount)
        var out = String(format: "mock refinement of %.2fs", seconds)
        let words = context.split(whereSeparator: { $0.isWhitespace }).count
        if words > 0 { out += " with \(words) context word\(words == 1 ? "" : "s")" }
        return out
    }

    public func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        if let failure { throw failure }
        guard !samples.isEmpty else { throw RefinementError.emptyAudio }
        let count = samples.count
        let body = text
        let sleepFor = work
        return try await Refinement.withDeadline(deadline) {
            if sleepFor > .zero { try await Task.sleep(for: sleepFor) }
            try Task.checkCancellation()
            return [Refinement.span(text: body ?? Self.syntheticText(sampleCount: count, context: context),
                                    sampleCount: count)]
        }
    }
}
