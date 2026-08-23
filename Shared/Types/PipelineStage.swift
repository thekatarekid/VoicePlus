import Foundation

/// Context handed to every stage. `extra` carries stage-specific, loosely-typed inputs
/// (e.g. screen vocabulary, persona text) so `Shared/` does not need to change per stage.
public struct StageContext: Sendable {
    public var register: Utterance.Register
    public var appBundleID: String?
    public var flags: [String: Bool]
    public var extra: [String: String]

    public init(
        register: Utterance.Register = .unknown,
        appBundleID: String? = nil,
        flags: [String: Bool] = [:],
        extra: [String: String] = [:]
    ) {
        self.register = register
        self.appBundleID = appBundleID
        self.flags = flags
        self.extra = extra
    }

    /// True when a flag is on in this context; falls back to the flag's default.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag.id] ?? flag.defaultOn
    }
}

/// Pipeline stages are `[TranscriptSpan] -> [TranscriptSpan]`. A stage must:
/// - append its `id` to the provenance of every span it returns,
/// - never drop confidence or audioRange,
/// - never rewrite a span with confidence < `TranscriptSpan.lowConfidenceThreshold`;
///   set `needsRepair` instead (Bet 9). `ConfidenceContract.verify` checks this.
public protocol PipelineStage: Sendable {
    var id: StageID { get }
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan]
}

/// Bet 9 enforcement helper. Used by the P1.7 T8 lint test and by stage unit tests.
public enum ConfidenceContract {
    public static let threshold: Float = TranscriptSpan.lowConfidenceThreshold

    /// Returns human-readable violations; empty means the stage honoured the contract.
    /// Spans are matched by audioRange (a stage may merge/split spans; a span whose
    /// audioRange no longer appears in the output at all is a violation).
    public static func verify(input: [TranscriptSpan], output: [TranscriptSpan]) -> [String] {
        var violations: [String] = []

        for span in input {
            let covered = output.contains { strictlyOverlaps($0.audioRange, span.audioRange) }
            if !covered {
                violations.append("audioRange \(span.audioRange) of \"\(span.text)\" was dropped")
            }
        }

        for (index, out) in output.enumerated() {
            if out.provenance.isEmpty {
                violations.append("output[\(index)] \"\(out.text)\" has empty provenance")
            } else if let matching = input.first(where: { $0.audioRange == out.audioRange }) {
                if out.provenance.count <= matching.provenance.count
                    || Array(out.provenance.prefix(matching.provenance.count)) != matching.provenance {
                    violations.append("output[\(index)] \"\(out.text)\" did not append provenance")
                }
                if matching.confidence < threshold, out.text != matching.text, !out.needsRepair {
                    violations.append(
                        "output[\(index)] rewrote low-confidence span \"\(matching.text)\" -> \"\(out.text)\" (confidence \(matching.confidence))"
                    )
                }
                if out.confidence != matching.confidence {
                    violations.append("output[\(index)] \"\(out.text)\" changed confidence \(matching.confidence) -> \(out.confidence)")
                }
            }
        }

        return violations
    }

    /// Overlap with positive duration; touching endpoints do not count. Zero-length spans
    /// count as covered when they fall inside the other range.
    static func strictlyOverlaps(_ a: ClosedRange<TimeInterval>, _ b: ClosedRange<TimeInterval>) -> Bool {
        if a.lowerBound == a.upperBound { return b.contains(a.lowerBound) }
        if b.lowerBound == b.upperBound { return a.contains(b.lowerBound) }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}
