// VoicePlus original (task R5.4). Per-segment-class scoring, latency percentiles and peak-memory
// bookkeeping for the refinement benchmark, plus the Markdown the decisions log gets.
import Darwin
import Foundation

/// One scored utterance in one arm.
///
/// `classes` comes from `SegmentClassifier` (reference and duration only), so a row cannot be filed
/// under a class because of how its arm performed.
public struct RefinementBenchmarkRow: Sendable, Equatable, Codable {
    /// Stable identifier for the utterance — the corpus line number ("02") or `suite/file`.
    public var id: String
    /// Which arm produced the hypothesis (`RefinementLabConfigs.parakeetOnly` and friends).
    public var arm: String
    /// Seconds of audio, or nil when unknown.
    public var seconds: TimeInterval?
    public var reference: String
    public var hypothesis: String
    public var wer: Double
    /// Wall clock for this arm's recognition of this utterance, including a second pass when the arm
    /// runs one. What V3 §10.2 budgets.
    public var latencyMs: Double
    public var classes: Set<SegmentClass>
    /// Two-pass arms only: whether `RefinementGate` selected this segment.
    public var gated: Bool
    /// Two-pass arms only: whether the second pass missed the deadline and pass-1 text stood.
    public var timedOut: Bool

    public init(id: String, arm: String, seconds: TimeInterval? = nil, reference: String, hypothesis: String,
                wer: Double, latencyMs: Double, classes: Set<SegmentClass> = [], gated: Bool = false,
                timedOut: Bool = false) {
        self.id = id
        self.arm = arm
        self.seconds = seconds
        self.reference = reference
        self.hypothesis = hypothesis
        self.wer = wer
        self.latencyMs = latencyMs
        self.classes = classes
        self.gated = gated
        self.timedOut = timedOut
    }
}

/// What one arm cost in resources. Separate from the rows because it is measured per *process*, not
/// per utterance (see `peakFootprintBytes`).
public struct RefinementBenchmarkArm: Sendable, Equatable, Codable {
    public var name: String
    /// Peak resident footprint sampled while this arm ran, or nil when it was not measured.
    ///
    /// **Read this with its caveat.** It is `phys_footprint` for the whole test process, sampled
    /// around each utterance — so in a run that holds several arms it includes every model already
    /// loaded, and only the *first* arm's figure is that arm alone. An isolated number needs one
    /// process per arm; the benchmark supports that (see the `arm` selector in
    /// `RefinementBenchmarkCorpusTests`) and the table says which kind of number it is printing.
    public var peakFootprintBytes: UInt64?
    /// The V3 §10.2 budget this arm is judged against, as plain text, or nil when none applies.
    public var latencyBudget: String?
    /// Free-text notes that belong with the arm in the table (weights path, deadline, mode).
    public var notes: String?

    public init(name: String, peakFootprintBytes: UInt64? = nil, latencyBudget: String? = nil,
                notes: String? = nil) {
        self.name = name
        self.peakFootprintBytes = peakFootprintBytes
        self.latencyBudget = latencyBudget
        self.notes = notes
    }
}

/// Aggregates rows into the two tables R5.4 owes: WER by segment class, and latency/memory per arm.
public struct RefinementBenchmark: Sendable, Equatable, Codable {
    /// Arms in reporting order. The **first** is the baseline every "better / worse" count is
    /// measured against.
    public var arms: [RefinementBenchmarkArm]
    public var rows: [RefinementBenchmarkRow]
    /// What was scored, in one line, for the table header (corpus, date, models).
    public var label: String

    public init(arms: [RefinementBenchmarkArm], rows: [RefinementBenchmarkRow], label: String = "") {
        self.arms = arms
        self.rows = rows
        self.label = label
    }

    public var baselineArm: String? { arms.first?.name }
    public var armNames: [String] { arms.map(\.name) }

    public func rows(arm: String) -> [RefinementBenchmarkRow] { rows.filter { $0.arm == arm } }

    public func rows(arm: String, in segmentClass: SegmentClass?) -> [RefinementBenchmarkRow] {
        rows(arm: arm).filter { segmentClass == nil || $0.classes.contains(segmentClass!) }
    }

    /// Mean of the per-utterance WERs — the same statistic R5.3 reported, so the numbers compare.
    /// nil when the class is empty in this arm.
    public func meanWER(arm: String, in segmentClass: SegmentClass? = nil) -> Double? {
        let subset = rows(arm: arm, in: segmentClass)
        guard !subset.isEmpty else { return nil }
        return subset.reduce(0) { $0 + $1.wer } / Double(subset.count)
    }

    /// Corpus-style WER: total word errors over total reference words. Reported next to the mean
    /// because on short utterances the two can disagree, and a class table that shows only one of
    /// them invites the reader to pick the flattering statistic.
    public func pooledWER(arm: String, in segmentClass: SegmentClass? = nil) -> Double? {
        let subset = rows(arm: arm, in: segmentClass)
        guard !subset.isEmpty else { return nil }
        var errors = 0.0
        var words = 0
        for row in subset {
            let refWords = TextNormalizer.words(row.reference).count
            errors += row.wer * Double(refWords)
            words += refWords
        }
        return words == 0 ? nil : errors / Double(words)
    }

    /// How many utterances of this class the arm beat / lost to the baseline arm on.
    public func versusBaseline(arm: String, in segmentClass: SegmentClass? = nil) -> (better: Int, worse: Int, same: Int) {
        guard let baseline = baselineArm else { return (0, 0, 0) }
        let base = Dictionary(rows(arm: baseline).map { ($0.id, $0.wer) }, uniquingKeysWith: { a, _ in a })
        var better = 0, worse = 0, same = 0
        for row in rows(arm: arm, in: segmentClass) {
            guard let reference = base[row.id] else { continue }
            if row.wer < reference - 1e-9 { better += 1 } else if row.wer > reference + 1e-9 { worse += 1 } else { same += 1 }
        }
        return (better, worse, same)
    }

    public func latencyPercentile(arm: String, p: Double) -> Double {
        Percentile.value(rows(arm: arm).map(\.latencyMs), p: p)
    }

    /// Classes that actually hold at least one utterance, in reporting order — a table of empty rows
    /// is worse than a shorter table.
    public var populatedClasses: [SegmentClass] {
        let present = Set(rows.flatMap(\.classes))
        return SegmentClass.reportingOrder.filter { present.contains($0) }
    }

    /// Utterances per class, counted in the baseline arm (every arm sees the same corpus).
    public func count(in segmentClass: SegmentClass) -> Int {
        guard let baseline = baselineArm else { return 0 }
        return rows(arm: baseline, in: segmentClass).count
    }

    // MARK: Markdown

    public static func wer(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "—" }
    public static func ms(_ v: Double) -> String { String(format: "%.0f ms", v) }
    public static func mb(_ bytes: UInt64?) -> String {
        bytes.map { String(format: "%.0f MB", Double($0) / (1024 * 1024)) } ?? "not measured"
    }

    /// The R5.4 deliverable: WER per segment class, one column per arm, `n` on every row, plus how
    /// many utterances each non-baseline arm improved and damaged inside that class.
    public func classTable() -> String {
        var out = ""
        if !label.isEmpty { out += "\(label)\n\n" }
        out += "| Segment class | n | " + armNames.map { "\($0) WER" }.joined(separator: " | ")
        for arm in armNames.dropFirst() { out += " | \(arm) better/worse" }
        out += " |\n|---|---:|" + String(repeating: "---:|", count: armNames.count + max(armNames.count - 1, 0)) + "\n"

        func row(_ label: String, _ n: Int, _ segmentClass: SegmentClass?) {
            out += "| \(label) | \(n)"
            for arm in armNames { out += " | \(Self.wer(meanWER(arm: arm, in: segmentClass)))" }
            for arm in armNames.dropFirst() {
                let v = versusBaseline(arm: arm, in: segmentClass)
                out += " | \(v.better)/\(v.worse)"
            }
            out += " |\n"
        }

        row("**all**", baselineArm.map { rows(arm: $0).count } ?? 0, nil)
        for segmentClass in populatedClasses { row(segmentClass.label, count(in: segmentClass), segmentClass) }
        out += "\nWER is the mean of per-utterance WERs (R5.3's statistic). Pooled WER (errors ÷ reference words) "
        out += "for the whole corpus: " + armNames.map { "\($0) \(Self.wer(pooledWER(arm: $0)))" }.joined(separator: ", ") + ".\n"
        out += "Classes overlap: an utterance with a name, a digit and 8 seconds of audio is counted in three rows.\n"
        return out
    }

    /// Latency percentiles and peak footprint per arm, against the V3 §10.2 budgets.
    public func resourceTable() -> String {
        var out = "| Arm | n | latency p50 | latency p95 | V3 §10.2 budget | peak footprint |\n"
        out += "|---|---:|---:|---:|---|---:|\n"
        for arm in arms {
            let subset = rows(arm: arm.name)
            out += "| \(arm.name) | \(subset.count) | \(Self.ms(latencyPercentile(arm: arm.name, p: 50)))"
            out += " | \(Self.ms(latencyPercentile(arm: arm.name, p: 95)))"
            out += " | \(arm.latencyBudget ?? "—") | \(Self.mb(arm.peakFootprintBytes)) |\n"
        }
        return out
    }

    /// Per-utterance detail, so a reader can check any cell of the class table by hand.
    public func itemTable() -> String {
        var out = "| # | seconds | classes | " + armNames.map { "\($0) WER" }.joined(separator: " | ") + " |\n"
        out += "|---|---:|---|" + String(repeating: "---:|", count: armNames.count) + "\n"
        let ids = (baselineArm.map { rows(arm: $0).map(\.id) } ?? []).sorted()
        for id in ids {
            let row = rows.first { $0.id == id }
            let classes = (row?.classes ?? []).map(\.label).sorted().joined(separator: ", ")
            out += "| \(id) | " + (row?.seconds.map { String(format: "%.1f", $0) } ?? "—") + " | \(classes)"
            for arm in armNames {
                out += " | \(Self.wer(rows.first { $0.arm == arm && $0.id == id }?.wer))"
            }
            out += " |\n"
        }
        return out
    }
}

/// Peak resident footprint of this process, for the memory column of the benchmark.
///
/// `phys_footprint` is the number Activity Monitor calls "Memory" and the one a jetsam limit is
/// measured against, so it is the right field for "does the two-pass configuration fit". This SDK's
/// `task_vm_info` exposes no kernel-maintained peak, so the peak has to be *sampled*: call `sample()`
/// around every unit of work and read `peakBytes`. A peak between two samples is invisible, which is
/// why the benchmark samples after each utterance rather than once at the end.
public final class PeakFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0

    public init() {}

    /// Current `phys_footprint` in bytes, or nil when the kernel refuses the query.
    public static func currentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Take a sample. Returns the current value, nil when unavailable.
    @discardableResult
    public func sample() -> UInt64? {
        guard let now = Self.currentBytes() else { return nil }
        lock.lock()
        peak = max(peak, now)
        lock.unlock()
        return now
    }

    /// Highest sample seen so far, or nil when nothing was ever sampled successfully.
    public var peakBytes: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return peak == 0 ? nil : peak
    }

    /// Forget the history — call between arms so each arm's figure is its own high-water mark.
    public func reset() {
        lock.lock()
        peak = 0
        lock.unlock()
    }
}
