import Foundation
import Shared

/// Thrown (in `.strict` mode) when a stage violates Bet 9's confidence contract.
public struct ConfidenceContractViolation: Error, CustomStringConvertible, Sendable {
    public let stage: StageID
    public let violations: [String]
    public var description: String { "stage \(stage) violated confidence contract: \(violations.joined(separator: "; "))" }
}

/// How `ContractEnforcingStage` reacts to a violation.
public enum ContractPolicy: Sendable {
    /// Throw `ConfidenceContractViolation`.
    case strict
    /// Log + report via metrics, and fall back to the stage's *input* (touched by the stage) so
    /// low-confidence text is never smoothed. Default in production.
    case fallbackToInput
    /// Log only; pass the output through. For the Lab's measurement mode.
    case flagOnly
}

/// Optional conformance: a stage that only applies to some registers. The runner skips it
/// (and records `skipped = true`) otherwise. Stages without this conformance use
/// `StageApplicability.defaultRegisters(for:)`.
public protocol RegisterScopedStage: PipelineStage {
    var applicableRegisters: Set<Utterance.Register> { get }
}

public enum StageApplicability {
    /// Built-in mapping for the Phase-1 formatter IDs; `nil` = applies to every register.
    public static func defaultRegisters(for id: StageID) -> Set<Utterance.Register>? {
        switch id {
        case .formatterEmail: return [.email]
        case .formatterChat: return [.chat]
        case .formatterCode: return [.code]
        case .formatterProse: return [.prose, .list, .unknown]
        case .formatterTerminal: return [.terminal]
        default: return nil
        }
    }

    public static func applies(_ stage: any PipelineStage, to register: Utterance.Register) -> Bool {
        if let scoped = stage as? any RegisterScopedStage { return scoped.applicableRegisters.contains(register) }
        guard let set = defaultRegisters(for: stage.id) else { return true }
        return set.contains(register)
    }
}

/// P1.7 T8 + T9 wrapper: runs `ConfidenceContract.verify` after every stage, measures
/// latency / skip / edit-distance, and reports `StageMetrics` to the sink.
public struct ContractEnforcingStage: PipelineStage {
    public let inner: any PipelineStage
    public let policy: ContractPolicy
    public let sink: any LabSink
    private let log = Log.pipeline

    public var id: StageID { inner.id }

    public init(_ inner: any PipelineStage, policy: ContractPolicy = .fallbackToInput, sink: any LabSink = LogBufferLabSink()) {
        self.inner = inner
        self.policy = policy
        self.sink = sink
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard StageApplicability.applies(inner, to: context.register) else {
            sink.record(StageMetrics(stage: id, latencyMs: 0, skipped: true, editDistance: 0,
                                     inputSpanCount: spans.count, outputSpanCount: spans.count))
            return spans
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let output: [TranscriptSpan]
        do {
            output = try await inner.process(spans, context: context)
        } catch {
            // A stage that throws is one optional step of post-processing that could not run —
            // a provider that is off, a store that would not open, a formatter that gave up. It
            // is never a reason to lose the user's words. Under the production policy the stage
            // degrades to pass-through (input, marked as touched, so provenance still records
            // that it ran) and the rest of the pipeline continues; before this, one throw
            // unwound the whole run and discarded every earlier stage's output.
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if case .strict = policy { throw error }
            log.warning("stage \(id) failed, passing its input through: \(error)")
            sink.record(StageMetrics(stage: id, latencyMs: latencyMs, skipped: true, editDistance: 0,
                                     inputSpanCount: spans.count, outputSpanCount: spans.count,
                                     contractViolations: ["stage threw: \(error)"]))
            return spans.map { $0.touched(by: id) }
        }
        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let violations = ConfidenceContract.verify(input: spans, output: output)
        let inText = spans.joinedText, outText = output.joinedText
        let distance = EditDistance.levenshtein(inText, outText)
        let noOp = distance == 0 && output.count == spans.count
            && zip(spans, output).allSatisfy { $0.needsRepair == $1.needsRepair }
        sink.record(StageMetrics(
            stage: id, latencyMs: latencyMs, skipped: noOp, editDistance: distance,
            inputSpanCount: spans.count, outputSpanCount: output.count, contractViolations: violations
        ))
        guard !violations.isEmpty else { return output }
        log.warning("contract violation in \(id): \(violations.joined(separator: "; "))")
        switch policy {
        case .strict: throw ConfidenceContractViolation(stage: id, violations: violations)
        case .fallbackToInput: return spans.map { $0.touched(by: id) }
        case .flagOnly: return output
        }
    }
}
