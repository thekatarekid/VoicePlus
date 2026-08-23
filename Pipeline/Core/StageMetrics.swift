import Foundation
import Shared

/// P1.7 T9 — one measurement per stage invocation. Published to `LogBuffer` and any `LabSink`.
public struct StageMetrics: Codable, Equatable, Sendable {
    public var stage: StageID
    public var latencyMs: Double
    /// True when the stage was not run (register mismatch, flag off, route == none).
    public var skipped: Bool
    /// Character-level Levenshtein distance between input and output joined text.
    public var editDistance: Int
    public var inputSpanCount: Int
    public var outputSpanCount: Int
    /// `ConfidenceContract.verify` output; empty when compliant.
    public var contractViolations: [String]
    public var timestamp: Date

    public init(
        stage: StageID, latencyMs: Double, skipped: Bool, editDistance: Int,
        inputSpanCount: Int, outputSpanCount: Int, contractViolations: [String] = [], timestamp: Date = Date()
    ) {
        self.stage = stage
        self.latencyMs = latencyMs
        self.skipped = skipped
        self.editDistance = editDistance
        self.inputSpanCount = inputSpanCount
        self.outputSpanCount = outputSpanCount
        self.contractViolations = contractViolations
        self.timestamp = timestamp
    }

    public var summary: String {
        "stage=\(stage) latency=\(String(format: "%.2f", latencyMs))ms skipped=\(skipped) edit=\(editDistance) spans=\(inputSpanCount)->\(outputSpanCount)"
            + (contractViolations.isEmpty ? "" : " violations=\(contractViolations.count)")
    }
}

/// Receives per-stage metrics. The Lab (P1.11) implements this to compute skip-rate,
/// latency percentiles and edit-distance contribution per stage.
public protocol LabSink: Sendable {
    func record(_ metrics: StageMetrics)
}

/// Default sink: writes a `pipeline.metrics` line into the shared `LogBuffer`.
public struct LogBufferLabSink: LabSink {
    public static let category = "pipeline.metrics"
    private let log: Log
    public init(buffer: LogBuffer = .shared) { log = Log(category: Self.category, buffer: buffer) }
    public func record(_ metrics: StageMetrics) {
        if metrics.contractViolations.isEmpty { log.debug(metrics.summary) }
        else { log.warning(metrics.summary + " " + metrics.contractViolations.joined(separator: "; ")) }
    }
}

/// In-memory sink for tests and the Lab's live view.
public final class CollectingLabSink: LabSink, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StageMetrics] = []
    public init() {}
    public func record(_ metrics: StageMetrics) { lock.lock(); items.append(metrics); lock.unlock() }
    public var all: [StageMetrics] { lock.lock(); defer { lock.unlock() }; return items }
    /// Fraction of invocations of `stage` that were skipped.
    public func skipRate(for stage: StageID) -> Double {
        let runs = all.filter { $0.stage == stage }
        guard !runs.isEmpty else { return 0 }
        return Double(runs.filter(\.skipped).count) / Double(runs.count)
    }
}

/// Fans out to several sinks.
public struct MultiLabSink: LabSink {
    public let sinks: [any LabSink]
    public init(_ sinks: [any LabSink]) { self.sinks = sinks }
    public func record(_ metrics: StageMetrics) { sinks.forEach { $0.record(metrics) } }
}

public enum EditDistance {
    /// Above this many DP cells (after common prefix/suffix trimming) the exact distance is
    /// replaced by the upper bound `max(lenA, lenB)` so a pathological hands-free utterance can
    /// never stall the pipeline on instrumentation (P1.12 hardening).
    public static let exactCellLimit = 4_000_000

    /// Character-level Levenshtein distance. Common prefix/suffix are stripped first (formatters
    /// usually touch a few characters), so the typical cost is tiny even for long utterances.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        var a = Array(a.unicodeScalars)[...], b = Array(b.unicodeScalars)[...]
        while let x = a.first, let y = b.first, x == y { a = a.dropFirst(); b = b.dropFirst() }
        while let x = a.last, let y = b.last, x == y { a = a.dropLast(); b = b.dropLast() }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if a.count * b.count > exactCellLimit { return max(a.count, b.count) }
        let aa = Array(a), bb = Array(b)
        var prev = Array(0...bb.count)
        var cur = [Int](repeating: 0, count: bb.count + 1)
        for i in 1...aa.count {
            cur[0] = i
            for j in 1...bb.count {
                let cost = aa[i - 1] == bb[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[bb.count]
    }
}
