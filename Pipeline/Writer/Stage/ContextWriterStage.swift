import Foundation
import Shared

// MARK: - Context Writer stage · transcribe mode (plan §1, §4)
//
// Position (wave 2 swaps the chain): where `CleanupStage` sits today — after ITN / dictionaries,
// before style. It renders the turn's `ContextPacket` (written at key-down by the app) through the
// destination profile into one prompt, calls the generator once, and lands the corrected text in
// one go. Every changed region passes `WriterGuard` (per-change: sounds alike, or formatting, or
// evidence); failing regions revert individually.
//
// It never runs when: no packet / wrong mode (instruct is the other stage), a secure destination,
// a verbatim surface (shell or code body in a terminal/code register), `writer.skip`, or no
// generator. Deadline 2.5 s (plan §4.5: failure only, not a deadline — on a stall the heard text
// lands and the app marks it "unpolished"). On timeout, error, rejection or an empty guard result
// the spans go through untouched with provenance appended; outcomes are reason codes only.
//
// Bet 9 on the way back: an uncertain span whose text changed is flagged `needsRepair` (so
// `ConfidenceContract` sees the rewrite as deliberate) and keeps what was heard as a `.repair`
// alternate, which is what "undo correction" restores. Confident spans only ever change shape.

public struct ContextWriterStage: PipelineStage {
    public static let stageID: StageID = "writer.context"
    public var id: StageID { Self.stageID }
    public static let defaultDeadline: TimeInterval = 2.5
    /// `StageContext.extra` key; "true" skips the model for this run (Verbatim app rule, "exact" preset).
    public static let skipKey = "writer.skip"
    /// `StageContext.extra` key; "true" keeps the heard text's first-letter case and terminal
    /// punctuation (a mid-sentence insertion). `CleanupStage.keepEdgesKey` is honoured too.
    public static let keepEdgesKey = "writer.keepEdges"
    /// Profiles whose text is verbatim in a terminal / code register (the profile says so).
    static let verbatimProfiles: Set<String> = ["shell", "code.body"]

    public var generator: (any WriterGenerating)?
    public var deadline: TimeInterval
    public var outputGuard: @Sendable () -> WriterGuard
    /// Reason codes only, never text (Q13).
    public var observer: (@Sendable (WriterOutcome) -> Void)?
    /// "Why did it write that?" — the outcome code lands as this stage's note.
    public var trace: TurnTraceRecorder?
    /// Profile lookup and prompt rendering; the defaults are the Destinations module.
    public var resolveProfile: @Sendable (String) -> DestinationProfile
    public var renderPrompt: @Sendable (ContextPacket, DestinationProfile) -> (system: String, user: String)

    public init(generator: (any WriterGenerating)?,
                deadline: TimeInterval = ContextWriterStage.defaultDeadline,
                outputGuard: @escaping @Sendable () -> WriterGuard = { WriterGuard() },
                observer: (@Sendable (WriterOutcome) -> Void)? = nil,
                trace: TurnTraceRecorder? = nil) {
        self.generator = generator
        self.deadline = deadline
        self.outputGuard = outputGuard
        self.observer = observer
        self.trace = trace
        self.resolveProfile = { DestinationProfiles.resolve(profileID: $0) }
        self.renderPrompt = { WriterPrompt.render(packet: $0, profile: $1) }
    }

    static let log = Log(category: "pipeline.writer")

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        let untouched = spans.map { $0.touched(by: id) }
        let packet = ContextPacket.read(from: context)
        if let skip = Self.skipReason(spans, packet: packet, context: context, hasGenerator: generator != nil) {
            report(.skipped(skip))
            return untouched
        }
        guard let generator, let packet else { return untouched }
        let profile = resolveProfile(packet.destination.profileID)
        if profile.isSecure {
            report(.skipped("secure"))
            return untouched
        }
        let prompt = renderPrompt(packet, profile)
        let heard = Self.heardTokens(spans)
        let input = heard.map(\.text).joined(separator: " ")

        let start = DispatchTime.now().uptimeNanoseconds
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        let result = await CleanupStage.race(deadline: deadline) {
            try await generator.write(system: prompt.system, user: prompt.user, context: context)
        }
        var output: String
        switch result {
        case nil:
            report(.timedOut(ms: elapsed())); return untouched
        case .failure(let error)?:
            report(.failed(CleanupStage.errorCode(error), ms: elapsed())); return untouched
        case .success(let text)?:
            output = CleanupGuard.unmark(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if output.caseInsensitiveCompare(WriterPrompt.unchangedToken) == .orderedSame || output == input {
            report(.unchanged(ms: elapsed())); return untouched
        }
        if context.extra[Self.keepEdgesKey] == "true" || context.extra[CleanupStage.keepEdgesKey] == "true" {
            output = CleanupStage.keepingEdges(of: input, in: output)
        }

        let verdict = outputGuard().check(heard: heard, output: output,
                                          vocabulary: packet.vocabulary, screenTerms: packet.screenTerms)
        guard case .accepted(let accepted) = verdict else {
            report(.rejected(verdict.rejection!, ms: elapsed())); return untouched
        }
        if accepted.text == input {
            report(.unchanged(ms: elapsed())); return untouched
        }
        let mapped = Self.map(accepted.perToken, heard: heard, onto: spans, by: id)
        if accepted.revertedCount > 0 {
            report(.partiallyReverted(accepted.revertedCount, ms: elapsed()))
        } else {
            report(.accepted(ms: elapsed()))
        }
        return mapped
    }

    private func report(_ outcome: WriterOutcome) {
        Self.log.info("writer: \(outcome.code)")
        trace?.note(stage: id, code: outcome.code)
        observer?(outcome)
    }

    /// Why the model must not run for this utterance, or nil.
    static func skipReason(_ spans: [TranscriptSpan], packet: ContextPacket?, context: StageContext,
                           hasGenerator: Bool) -> String? {
        if !hasGenerator { return "noModel" }
        guard let packet else { return "noPacket" }
        if packet.mode != .transcribe || ContextPacket.mode(of: context) != .transcribe { return "mode" }
        if packet.isSecure || packet.destination.profileID == DestinationProfiles.secureID { return "secure" }
        if FieldRole.classify(FieldContext(stageContext: context)) == .secure { return "fieldRole" }
        if spans.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty" }
        if context.extra[skipKey] == "true" { return "verbatim" }
        if (context.register == .code || context.register == .terminal),
           verbatimProfiles.contains(packet.destination.profileID) { return "verbatimProfile" }
        return nil
    }

    // MARK: Spans ⇄ heard tokens

    /// One token per whitespace-separated word of each span, carrying the span's evidence. Empty
    /// spans (a blanked filler from an earlier stage) contribute nothing.
    static func heardTokens(_ spans: [TranscriptSpan]) -> [WriterGuard.HeardToken] {
        var out: [WriterGuard.HeardToken] = []
        for (i, span) in spans.enumerated() {
            let alternates = span.alternates.sorted { $0.score > $1.score }.prefix(ContextRepairStage.topK).map(\.text)
            for word in WordDiff.tokens(span.text) where word != "\n" {
                out.append(WriterGuard.HeardToken(text: word, confidence: span.confidence, alternates: Array(alternates),
                                                  needsRepair: span.needsRepair, span: i))
            }
        }
        return out
    }

    /// Puts the guard's per-token text back on the spans: each span takes the texts of its own
    /// tokens. Audio, confidence, stability and the alternates stay; a changed span gets the heard
    /// text as a `.repair` alternate, and a changed **uncertain** span is flagged `needsRepair`.
    static func map(_ perToken: [String], heard: [WriterGuard.HeardToken], onto spans: [TranscriptSpan],
                    by stage: StageID) -> [TranscriptSpan] {
        var texts = [[String]](repeating: [], count: spans.count)
        for (token, text) in zip(heard, perToken) where !text.isEmpty { texts[token.span].append(text) }
        return spans.enumerated().map { i, span in
            let hadWords = heard.contains { $0.span == i }
            guard hadWords else { return span.touched(by: stage) }
            let text = texts[i].joined(separator: " ")
            guard text != span.text else { return span.touched(by: stage) }
            var out = span.rewritten(text, by: stage)
            if span.isLowConfidence || span.needsRepair { out.needsRepair = true }
            out.alternates.insert(Alternate(text: span.text, score: 0, source: .repair), at: 0)
            return out
        }
    }
}
