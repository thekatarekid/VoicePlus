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
        let coverage = CoverageIndex(output)

        for span in input where !coverage.covers(span.audioRange) {
            violations.append("audioRange \(span.audioRange) of \"\(span.text)\" was dropped")
        }

        // First input span per exact audioRange (same semantics as `input.first(where:)`, O(n)).
        var byRange: [ClosedRange<TimeInterval>: TranscriptSpan] = [:]
        for span in input where byRange[span.audioRange] == nil { byRange[span.audioRange] = span }

        for (index, out) in output.enumerated() {
            if out.provenance.isEmpty {
                violations.append("output[\(index)] \"\(out.text)\" has empty provenance")
            } else if let matching = byRange[out.audioRange] {
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

    /// O(log n) "is this input range covered by some output range" with exactly the
    /// `strictlyOverlaps` semantics (P1.12 hardening: 10k-span utterances must not go quadratic).
    struct CoverageIndex {
        private let lowers: [TimeInterval]        // non-zero-length outputs sorted by lowerBound
        private let prefixMaxUpper: [TimeInterval]
        private let pointLowers: [TimeInterval]   // zero-length outputs, sorted

        init(_ output: [TranscriptSpan]) {
            let ranges = output.map(\.audioRange)
            let spans = ranges.filter { $0.lowerBound != $0.upperBound }.sorted { $0.lowerBound < $1.lowerBound }
            lowers = spans.map(\.lowerBound)
            var running = -TimeInterval.infinity
            prefixMaxUpper = spans.map { running = max(running, $0.upperBound); return running }
            pointLowers = ranges.filter { $0.lowerBound == $0.upperBound }.map(\.lowerBound).sorted()
        }

        /// Number of elements of `xs` (sorted) that satisfy `pred` (pred is monotone: true then false).
        private static func count(_ xs: [TimeInterval], while pred: (TimeInterval) -> Bool) -> Int {
            var lo = 0, hi = xs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pred(xs[mid]) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func covers(_ a: ClosedRange<TimeInterval>) -> Bool {
            if a.lowerBound == a.upperBound {
                // zero-length input: some output must contain the point.
                let k = Self.count(lowers) { $0 <= a.lowerBound }
                if k > 0, prefixMaxUpper[k - 1] >= a.lowerBound { return true }
                return !pointLowers.isEmpty && Self.count(pointLowers) { $0 < a.lowerBound } < Self.count(pointLowers) { $0 <= a.lowerBound }
            }
            // non-zero input vs non-zero outputs: b.lower < a.upper && a.lower < b.upper
            let k = Self.count(lowers) { $0 < a.upperBound }
            if k > 0, prefixMaxUpper[k - 1] > a.lowerBound { return true }
            // non-zero input vs zero-length outputs: a contains b.lower
            let before = Self.count(pointLowers) { $0 < a.lowerBound }
            let upTo = Self.count(pointLowers) { $0 <= a.upperBound }
            return upTo > before
        }
    }

    /// Overlap with positive duration; touching endpoints do not count. Zero-length spans
    /// count as covered when they fall inside the other range.
    static func strictlyOverlaps(_ a: ClosedRange<TimeInterval>, _ b: ClosedRange<TimeInterval>) -> Bool {
        if a.lowerBound == a.upperBound { return b.contains(a.lowerBound) }
        if b.lowerBound == b.upperBound { return a.contains(b.lowerBound) }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}
