import Foundation
import Shared

// MARK: - V5 D2 · Cleanup stage (behind the D3 guard)
//
// Position: after the formatters/ITN and the dictionary stages, before style (the last pass, Bet 8).
// It runs the model only when:
// - the mode is Always, or Automatic and the rules see a cue (`CleanupCueDetector`);
// - the destination is prose (never a terminal, code editor or secure field; never under a
//   Verbatim app rule, which switches the style pass off);
// - a generator is wired (the app's `RoutingTable` adapter; Lab/tests inject a mock).
//
// Deadline 500 ms (p95 target on M2 Pro). On timeout, a thrown error, a guard rejection or an
// output that cannot be mapped back onto the spans, the rules output goes through unchanged — the
// stage only ever appends provenance in that case. Low-confidence spans are never rewritten
// (Bet 9): they are anchors the output must contain verbatim (D3), and they keep their text.

/// The model call. The app's conformer routes through `RoutingTable` stage `cleanup` (§10) to the
/// llama.cpp provider, which loads through `ModelResidency` (HW1).
public protocol CleanupGenerating: Sendable {
    /// Which prompt rendering the routed model expects.
    var promptStyle: CleanupPromptStyle { get }
    func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String
}

/// What one run did — reason codes only, never text (Q13).
public enum CleanupOutcome: Sendable, Equatable {
    case skipped(String)
    case accepted(cues: CleanupCues, ms: Double)
    case unchanged(ms: Double)
    case rejected(CleanupGuard.Rejection, ms: Double)
    case timedOut(ms: Double)
    case failed(String, ms: Double)
    case unmappable(ms: Double)

    public var code: String {
        switch self {
        case .skipped(let why): return "skipped:\(why)"
        case .accepted: return "accepted"
        case .unchanged: return "unchanged"
        case .rejected(let r, _): return "rejected:\(r.rawValue)"
        case .timedOut: return "timeout"
        case .failed(let why, _): return "failed:\(why)"
        case .unmappable: return "unmappable"
        }
    }
}

public struct CleanupStage: PipelineStage {
    public let id: StageID = .cleanup
    public static let defaultDeadline: TimeInterval = 0.5

    public var generator: (any CleanupGenerating)?
    public var mode: @Sendable () -> CleanupMode
    public var deadline: TimeInterval
    public var outputGuard: @Sendable () -> CleanupGuard
    public var observer: (@Sendable (CleanupOutcome) -> Void)?

    public init(generator: (any CleanupGenerating)?,
                mode: @escaping @Sendable () -> CleanupMode = { .default },
                deadline: TimeInterval = CleanupStage.defaultDeadline,
                outputGuard: @escaping @Sendable () -> CleanupGuard = { CleanupGuard() },
                observer: (@Sendable (CleanupOutcome) -> Void)? = nil) {
        self.generator = generator
        self.mode = mode
        self.deadline = deadline
        self.outputGuard = outputGuard
        self.observer = observer
    }

    static let log = Log(category: "pipeline.cleanup")

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        let untouched = spans.map { $0.touched(by: id) }
        let mode = context.extra[CleanupMode.contextKey].flatMap(CleanupMode.init(rawValue:)) ?? self.mode()
        if let skip = Self.skipReason(spans, context: context, mode: mode, hasGenerator: generator != nil) {
            report(.skipped(skip))
            return untouched
        }
        guard let generator else { return untouched }
        let request = CleanupRequest(spans: spans, context: context)
        let cues = CleanupCueDetector.cues(in: request.transcript)
        if mode == .automatic, cues.isEmpty {
            report(.skipped("noCue"))
            return untouched
        }

        let prompt = CleanupPrompt.render(request, style: generator.promptStyle)
        let start = DispatchTime.now().uptimeNanoseconds
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        let result = await Self.race(deadline: deadline) { try await generator.cleanup(prompt, context: context) }

        let output: String
        switch result {
        case nil:
            report(.timedOut(ms: elapsed())); return untouched
        case .failure(let error)?:
            report(.failed(Self.errorCode(error), ms: elapsed())); return untouched
        case .success(let text)?:
            output = text
        }

        let verdict = outputGuard().check(input: request.transcript, output: output,
                                          dictionary: request.personalisation.dictionary,
                                          lockedPhrases: request.lockedPhrases)
        guard case .accepted(let accepted) = verdict else {
            report(.rejected(verdict.rejection!, ms: elapsed())); return untouched
        }
        if accepted == request.transcript {
            report(.unchanged(ms: elapsed())); return untouched
        }
        guard let mapped = Self.map(accepted, onto: spans, by: id) else {
            report(.unmappable(ms: elapsed())); return untouched
        }
        report(.accepted(cues: cues, ms: elapsed()))
        return mapped
    }

    private func report(_ outcome: CleanupOutcome) {
        Self.log.info("cleanup: \(outcome.code)")
        observer?(outcome)
    }

    /// Why the model must not run for this utterance, or nil.
    static func skipReason(_ spans: [TranscriptSpan], context: StageContext, mode: CleanupMode,
                           hasGenerator: Bool) -> String? {
        if mode == .off { return "off" }
        if !hasGenerator { return "noModel" }
        if spans.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty" }
        if context.extra[StyleStage.enabledKey] == "false" { return "verbatim" }
        if context.register == .code || context.register == .terminal { return "register" }
        switch FieldRole.classify(FieldContext(stageContext: context)) {
        case .terminal, .codeEditor, .secure: return "fieldRole"
        default: return nil
        }
    }

    static func errorCode(_ error: Error) -> String {
        let s = String(describing: error)
        return String(s.prefix(while: { $0 != "(" }).prefix(40))
    }

    // MARK: Deadline

    /// Runs `op`, returning nil if it has not finished within `deadline` seconds. Unlike a task
    /// group, this does not wait for a slow `op` (a cold model load) to finish before returning: the
    /// work is cancelled and left to wind down on its own.
    static func race<T: Sendable>(deadline: TimeInterval,
                                  _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
            let work = Task {
                let r: Result<T, Error>
                do { r = .success(try await op()) } catch { r = .failure(error) }
                if once.claim() { cont.resume(returning: r) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Mapping back onto spans

    /// Puts the accepted text back on the spans. Low-confidence spans are anchors: they keep their
    /// text; the output between two anchors goes on the first high-confidence span of that run and
    /// the run's other spans become empty (`renderedText` skips them). Returns nil when an anchor is
    /// missing or text appears where there is no span to carry it.
    static func map(_ text: String, onto spans: [TranscriptSpan], by stage: StageID) -> [TranscriptSpan]? {
        var runs: [[Int]] = [[]]
        var anchors: [Int] = []
        for (i, span) in spans.enumerated() {
            if span.isLowConfidence, !span.text.trimmingCharacters(in: .whitespaces).isEmpty {
                anchors.append(i); runs.append([])
            } else {
                runs[runs.count - 1].append(i)
            }
        }
        var segments: [String] = []
        var from = text.startIndex
        for a in anchors {
            let needle = spans[a].text.trimmingCharacters(in: .whitespaces)
            guard let r = CleanupGuard.rangeOfWord(needle, in: text, from: from) else { return nil }
            segments.append(String(text[from..<r.lowerBound]))
            from = r.upperBound
        }
        segments.append(String(text[from...]))

        var out = spans.map { $0.touched(by: stage) }
        for (run, segment) in zip(runs, segments) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if run.isEmpty {
                if trimmed.isEmpty { continue }
                return nil
            }
            for (k, i) in run.enumerated() {
                out[i] = spans[i].rewritten(k == 0 ? trimmed : "", by: stage)
            }
        }
        return out
    }
}

/// Resume-once flag for `race`.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
