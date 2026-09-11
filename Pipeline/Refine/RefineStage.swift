// VoicePlus original (task R5.2). The refinement stage: a second recognition pass that replaces
// span text in place, on a deadline, behind a bounded backlog, and never over committed text.
import Foundation
import Shared

/// What one run of `RefineStage` did. Everything except `.refined` / `.unchanged` means the span
/// text is still pass-1's.
public enum RefineOutcome: String, Sendable, Equatable, CaseIterable {
    /// The pass returned different words and they were laid over the pass-1 audio map.
    case refined
    /// The pass ran and agreed with pass 1.
    case unchanged
    /// Turned off for this run (`RefineStage.enabledKey`).
    case disabled
    /// At least one span was already delivered. Refinement is dropped, not applied.
    case alreadyCommitted
    /// The pass finished, but by then the text had been committed. Dropped (V3 §5.3).
    case lateResultDropped
    /// No audio to refine.
    case noAudio
    /// The backlog was full: commit pass-1 rather than queueing (V3 §10.2).
    case backlogFull
    /// The deadline expired (V3 §10.2). Pass-1 text stands.
    case timedOut
    /// The session threw. Pass-1 text stands.
    case failed
    /// The session returned nothing usable.
    case emptyResult

    /// True when the caller is looking at pass-1 text.
    public var keptPassOne: Bool { self != .refined }
}

/// One line of evidence per run — what happened, how long it took, how deep the backlog was.
/// `RefineStage` reports this instead of logging text (the prompt and the transcript never go to
/// the log).
public struct RefineReport: Sendable, Equatable {
    public var outcome: RefineOutcome
    public var latencyMs: Double
    public var deadlineMs: Double
    public var backlogDepth: Int
    /// Spans whose text the pass replaced.
    public var rewrittenSpans: Int

    public init(outcome: RefineOutcome, latencyMs: Double = 0, deadlineMs: Double = 0,
                backlogDepth: Int = 0, rewrittenSpans: Int = 0) {
        self.outcome = outcome
        self.latencyMs = latencyMs
        self.deadlineMs = deadlineMs
        self.backlogDepth = backlogDepth
        self.rewrittenSpans = rewrittenSpans
    }
}

/// R5.2 — the second recognition pass, as a pipeline stage.
///
/// What it does and does not do:
/// - **In place.** One output span per input span, same `audioRange`, same `alternates`, same
///   `stability`, provenance appended. Only `text` changes.
/// - **Timing.** The session gives text for the whole segment and no word timings, so the refined
///   words are laid back over the pass-1 audio map by duration (`RefinedWordAlignment`).
/// - **Deadline.** `deadline` is enforced here as well as inside the session; on timeout the
///   pass-1 spans are returned (V3 §10.2: final segment p95 ≤ 1500 ms).
/// - **Backlog.** With a `RefinementBacklog`, a segment beyond the bound is never queued; it
///   commits pass-1 immediately.
/// - **Committed text is never rewritten.** Not before the pass (a `.committed` span in the batch
///   drops the whole refinement) and not after it (`stabilityAtApply` re-reads the state the
///   result would land on). `TranscriptSpan.stabilized(_:)` is forward-only by design, so there is
///   no way to walk a commit back and this stage does not try.
/// - **Confidence.** The pass reports none. When the words change, pass-1's number no longer
///   describes them, so `.refineConfidenceUnavailable` is recorded in provenance; see
///   `refined(_:text:)` for why the numeric field is left alone rather than zeroed.
public struct RefineStage: PipelineStage {
    /// V3 §10.2 — final segment: refined text after endpoint, else pass-1, p95 ≤ 1500 ms.
    public static let finalSegmentDeadline: Duration = .milliseconds(1500)
    /// V3 §10.2 — earlier segments run off the critical path with a backlog of at most this many.
    public static let maxBacklogSegments = RefinementBacklog.defaultLimit

    /// `StageContext.extra` key carrying the text prompt for the pass (screen text, lexicon,
    /// recent transcript). Overrides the stage's own `contextText` when present.
    public static let contextKey = "refine.context"
    /// `StageContext.extra` key; `"false"` disables the pass for one run (R5.3's gate uses this).
    public static let enabledKey = "refine.enabled"

    /// Audio for the segment these spans came from: 16 kHz mono Float32 from the segment start.
    public typealias AudioProvider = @Sendable (StageContext) async -> [Float]
    /// Re-read of the stability the refined text would land on, called *after* the pass returns.
    /// This is what makes "a late result never overwrites committed text" a real check rather than
    /// a re-inspection of the snapshot the stage was handed. `nil` means "no newer information".
    public typealias StabilityProbe = @Sendable (StageContext) async -> Stability?
    public typealias Observer = @Sendable (RefineReport) -> Void

    public let id: StageID = .refine

    public let refiner: any SpanRefining
    public let deadline: Duration
    public let backlog: RefinementBacklog?
    public let contextText: String
    private let audio: AudioProvider
    private let stabilityAtApply: StabilityProbe?
    private let observer: Observer?
    private let log = Log.pipeline

    public init(
        refiner: any SpanRefining,
        audio: @escaping AudioProvider,
        deadline: Duration = RefineStage.finalSegmentDeadline,
        backlog: RefinementBacklog? = nil,
        contextText: String = "",
        stabilityAtApply: StabilityProbe? = nil,
        observer: Observer? = nil
    ) {
        self.refiner = refiner
        self.audio = audio
        self.deadline = deadline
        self.backlog = backlog
        self.contextText = contextText
        self.stabilityAtApply = stabilityAtApply
        self.observer = observer
    }

    /// Convenience for the common case: one stage per closed segment, audio already in hand.
    public init(
        refiner: any SpanRefining,
        samples: [Float],
        deadline: Duration = RefineStage.finalSegmentDeadline,
        backlog: RefinementBacklog? = nil,
        contextText: String = "",
        stabilityAtApply: StabilityProbe? = nil,
        observer: Observer? = nil
    ) {
        self.init(refiner: refiner, audio: { _ in samples }, deadline: deadline, backlog: backlog,
                  contextText: contextText, stabilityAtApply: stabilityAtApply, observer: observer)
    }

    // MARK: - Stage

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard !spans.isEmpty else { return spans }
        // Pass-1 text, with this stage recorded as having looked at it. Every fallback path below
        // returns exactly this: a stage that returns its input *unchanged* fails
        // `ConfidenceContract.verify` ("did not append provenance") and gets discarded by
        // `ContractEnforcingStage` — the bug commit 96d801d fixed in two other stages.
        let passOne = spans.map { $0.touched(by: id) }

        guard context.extra[Self.enabledKey] != "false" else {
            report(.disabled)
            return passOne
        }
        // Committed text has been sent to the destination once and is never retracted (V3 §2,
        // §5.3). `.provisional` and `.final` spans are refinable; `.committed` is not, and one
        // committed span drops the whole batch, because the pass returns text for the *segment*
        // and there is no honest way to split refined words around words already delivered.
        if spans.contains(where: { $0.stability == .committed }) {
            report(.alreadyCommitted)
            return passOne
        }

        let samples = await audio(context)
        guard !samples.isEmpty else {
            report(.noAudio)
            return passOne
        }

        if let backlog {
            guard await backlog.admit() else {
                report(.backlogFull, backlogDepth: await backlog.depth)
                return passOne
            }
        }

        let prompt = context.extra[Self.contextKey] ?? contextText
        let started = ContinuousClock.now
        let refinedText: String
        do {
            let session = refiner
            let budget = deadline
            let produced = try await RefinementClock.withDeadline(budget) {
                try await session.refine(samples: samples, context: prompt, deadline: budget)
            }
            await backlog?.release()
            refinedText = produced.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await backlog?.release()
            let elapsed = started.duration(to: .now)
            let timedOut = error is RefinementTimedOut || elapsed >= deadline
            // Either way the user keeps their words: pass-1 text, unedited.
            log.warning("refinement \(timedOut ? "timed out" : "failed"): \(error)")
            report(timedOut ? .timedOut : .failed, latency: elapsed, backlogDepth: await backlog?.depth ?? 0)
            return passOne
        }
        let elapsed = started.duration(to: .now)
        let depth = await backlog?.depth ?? 0

        guard !refinedText.isEmpty else {
            report(.emptyResult, latency: elapsed, backlogDepth: depth)
            return passOne
        }
        // The pass took time. If the text was committed while it ran, this result is late and is
        // dropped — a delivered segment is never rewritten (V3 §5.3, §14.3: injection is
        // append-only, so "overwriting" is not even expressible downstream).
        if let stabilityAtApply, await stabilityAtApply(context) == .committed {
            report(.lateResultDropped, latency: elapsed, backlogDepth: depth)
            return passOne
        }

        let texts = RefinedWordAlignment.distribute(refinedText, over: spans)
        var output: [TranscriptSpan] = []
        var rewritten = 0
        for (index, span) in spans.enumerated() {
            let refinedSpan = Self.refined(span, text: texts[index])
            if refinedSpan.text != span.text { rewritten += 1 }
            output.append(refinedSpan)
        }
        report(rewritten > 0 ? .refined : .unchanged, latency: elapsed,
               backlogDepth: depth, rewrittenSpans: rewritten)
        return output
    }

    // MARK: - One span, in place

    /// The whole in-place rewrite, in one place.
    ///
    /// `confidence` keeps pass-1's number and provenance records that it is unavailable. Two
    /// reasons not to write a number instead: the pass reports none to write (`Refinement`'s
    /// `confidenceNotReported` is a placeholder, not a measurement), and `ConfidenceContract`
    /// treats *any* change to the field as a dropped-confidence violation — writing 0 would both
    /// get the stage's output thrown away and read downstream as "the recognizer was unsure",
    /// which is a different and false claim. So the field is preserved and the *claim* about it is
    /// withdrawn, which is what V3 §5.3 asks for.
    static func refined(_ span: TranscriptSpan, text: String) -> TranscriptSpan {
        guard text != span.text else { return span.touched(by: .refine) }
        var copy = span
        copy.text = text
        copy.provenance.append(.refineConfidenceUnavailable)
        copy.provenance.append(.refine)
        // Bet 9 says a stage must not rewrite a low-confidence span. A second *recognition* pass
        // over the same audio is exactly what low pass-1 confidence should trigger (V3 §5.3 gates
        // on it), so the rewrite stands — but the span is flagged rather than presented as
        // settled, which is also what keeps `ConfidenceContract` satisfied.
        if span.isLowConfidence { copy.needsRepair = true }
        return copy
    }

    // MARK: - Reporting

    private func report(_ outcome: RefineOutcome, latency: Duration = .zero,
                        backlogDepth: Int = 0, rewrittenSpans: Int = 0) {
        guard let observer else { return }
        observer(RefineReport(
            outcome: outcome,
            latencyMs: RefinementClock.milliseconds(latency),
            deadlineMs: RefinementClock.milliseconds(deadline),
            backlogDepth: backlogDepth,
            rewrittenSpans: rewrittenSpans
        ))
    }
}
