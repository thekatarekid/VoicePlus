import Foundation
import Shared

/// Outcome of one repair command against the session.
public enum RepairResult: Equatable, Sendable {
    /// The word at `spanIndex` now reads `to`.
    case replaced(spanIndex: Int, from: String, to: String)
    /// Whole last phrase removed.
    case scratched(text: String)
    /// Previous replacement reverted.
    case undone(spanIndex: Int?, restored: String)
    /// Command understood but nothing to do (no alternates, empty undo stack, …).
    case noop(reason: String)
    /// Document changed under us / sink unavailable: nothing touched.
    case failed(RepairReplaceOutcome)
    /// Stage saw the utterance but did not treat it as a repair.
    case ignored(reason: String)
    /// No utterance landed in the last `window` seconds.
    case inactive

    public var consumedUtterance: Bool {
        switch self {
        case .ignored, .inactive: return false
        default: return true
        }
    }
}

/// T3/T5 — tracks the last landed utterance for `window` seconds (10 s) and applies
/// snap / cycle / drop / undo against it through a `ReplaceRangeSink`. Every successful
/// edit updates the span (text + provenance `.repair`), logs a `CorrectionRecord`, and
/// tells the zero-edit counter that this dictation was edited.
public final class RepairSession: @unchecked Sendable {
    public static let source = "voiceRepair"

    private struct UndoEntry {
        enum Kind { case span(index: Int, previous: TranscriptSpan); case scratch(text: String, spans: [TranscriptSpan]) }
        var kind: Kind
    }

    public let window: TimeInterval
    public var replaceSink: ReplaceRangeSink?
    public var correctionSink: CorrectionSink?
    public var zeroEditSink: ZeroEditSink?
    public let enricher: AlternateEnricher?
    public var now: @Sendable () -> Date

    private let lock = NSLock()
    private var utterance: Utterance?
    private var fieldOffset = 0
    private var landedAt: Date?
    private var lastActivity: Date?
    private var scratched = false
    private var undoStack: [UndoEntry] = []
    /// Span index the fan-out / cycle is currently focused on.
    private var focusIndex: Int?
    /// Per-span ring position for `.cycle` (0 = original text, 1… = alternates).
    private var cyclePosition: [Int: Int] = [:]
    public private(set) var lastResult: RepairResult = .inactive

    public init(window: TimeInterval = 10, replaceSink: ReplaceRangeSink? = nil, correctionSink: CorrectionSink? = nil,
                zeroEditSink: ZeroEditSink? = nil, enricher: AlternateEnricher? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.window = window
        self.replaceSink = replaceSink
        self.correctionSink = correctionSink
        self.zeroEditSink = zeroEditSink
        self.enricher = enricher
        self.now = now
    }

    // MARK: - Lifecycle

    /// Call right after `utterance` was injected; `fieldOffset` is the UTF-16 position in the
    /// focused element where the landed text starts. The text is the spans space-joined —
    /// `landedText` is what the sink is expected to find.
    public func land(_ utterance: Utterance, fieldOffset: Int, at time: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        var u = utterance
        if let enricher { u.spans = enricher.enrich(u.spans) }
        self.utterance = u
        self.fieldOffset = fieldOffset
        let t = time ?? now()
        landedAt = t
        lastActivity = t
        scratched = false
        undoStack.removeAll()
        cyclePosition.removeAll()
        focusIndex = nil
        lastResult = .ignored(reason: "landed")
    }

    public func isActive(at time: Date? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isActiveLocked(at: time ?? now())
    }

    private func isActiveLocked(at time: Date) -> Bool {
        guard utterance != nil, let last = lastActivity else { return false }
        return time.timeIntervalSince(last) <= window
    }

    /// The utterance as currently repaired (spans carry `.repair` provenance where edited).
    public var current: Utterance? { lock.withLock { utterance } }
    public var landedText: String { lock.withLock { scratched ? "" : (utterance?.spans.joinedText ?? "") } }
    public var focusedSpanIndex: Int? { lock.withLock { focusIndex } }

    public func end() {
        lock.withLock { utterance = nil; lastActivity = nil; lastResult = .inactive }
    }

    func note(_ result: RepairResult) { lock.withLock { lastResult = result } }

    // MARK: - Commands

    @discardableResult
    public func apply(_ command: RepairCommand, at time: Date? = nil) -> RepairResult {
        lock.lock(); defer { lock.unlock() }
        let t = time ?? now()
        guard isActiveLocked(at: t), utterance != nil else { lastResult = .inactive; return lastResult }
        let result: RepairResult
        switch command {
        case .snap(let word): result = snap(word)
        case .cycle: result = cycle()
        case .scratch: result = scratch()
        case .undo: result = undo()
        case .pick(let n): result = pick(n)
        }
        lastActivity = t
        lastResult = result
        return result
    }

    /// Fan-out click/voice pick of alternate `index` (0-based) on span `spanIndex`.
    @discardableResult
    public func choose(alternate index: Int, of spanIndex: Int, at time: Date? = nil) -> RepairResult {
        lock.lock(); defer { lock.unlock() }
        let t = time ?? now()
        guard isActiveLocked(at: t), let u = utterance, u.spans.indices.contains(spanIndex) else { lastResult = .inactive; return lastResult }
        let alts = u.spans[spanIndex].alternates
        guard alts.indices.contains(index) else { lastResult = .noop(reason: "no such alternate"); return lastResult }
        focusIndex = spanIndex
        cyclePosition[spanIndex] = index + 1
        lastActivity = t
        lastResult = replace(spanIndex: spanIndex, with: alts[index].text, source: .repair)
        return lastResult
    }

    // MARK: - Command implementations (lock held)

    private func snap(_ said: String) -> RepairResult {
        guard let u = utterance, !scratched, !u.spans.isEmpty else { return .noop(reason: "nothing landed") }
        let key = WordConfusionNetwork.normalize(said)
        guard !key.isEmpty else { return .noop(reason: "empty word") }
        let dm = DoubleMetaphone(maxLength: 6)
        let saidCodes = dm.encode(said)

        // Score each span: exact alternate hit > phonetic alternate hit > phonetic/orthographic
        // similarity with the span's own text. Low confidence breaks ties.
        var best: (index: Int, replacement: String, score: Float)?
        for (i, span) in u.spans.enumerated() {
            var score: Float = 0
            var replacement = said
            for alt in span.alternates {
                let altKey = WordConfusionNetwork.normalize(alt.text)
                let s: Float
                if altKey == key { s = 1.0 }
                else if dm.encode(alt.text).matches(saidCodes) { s = 0.8 }
                else { s = 0.4 * AlternateEnricher.similarity(altKey, key) }
                if s > score { score = s; replacement = altKey == key || s >= 0.8 ? alt.text : said }
            }
            let own = WordConfusionNetwork.normalize(span.text)
            let ownPhonetic = dm.encode(span.text).matches(saidCodes) ? 0.6 : 0
            let ownSim = 0.5 * AlternateEnricher.similarity(own, key)
            score = max(score, Float(ownPhonetic), ownSim)
            if own == key { score = 0 } // already says that
            score += (1 - span.confidence) * 0.05 + (span.isLowConfidence ? 0.1 : 0)
            if best == nil || score > best!.score { best = (i, replacement, score) }
        }
        guard let b = best else { return .noop(reason: "no target") }
        // Nothing resembles the said word: fall back to the lowest-confidence span, keep the spoken spelling.
        var target = b
        if b.score < 0.35, let lowest = u.spans.indices.min(by: { u.spans[$0].confidence < u.spans[$1].confidence }) {
            target = (lowest, said, b.score)
        }
        if WordConfusionNetwork.normalize(u.spans[target.index].text) == key { return .noop(reason: "already \(said)") }
        focusIndex = target.index
        cyclePosition[target.index] = (u.spans[target.index].alternates.firstIndex { WordConfusionNetwork.normalize($0.text) == WordConfusionNetwork.normalize(target.replacement) }.map { $0 + 1 }) ?? 0
        return replace(spanIndex: target.index, with: target.replacement, source: .repair)
    }

    private func cycle() -> RepairResult {
        guard let u = utterance, !scratched, !u.spans.isEmpty else { return .noop(reason: "nothing landed") }
        let idx = focusIndex ?? u.spans.indices
            .filter { !u.spans[$0].alternates.isEmpty }
            .min(by: { u.spans[$0].confidence < u.spans[$1].confidence })
        guard let i = idx else { return .noop(reason: "no alternates") }
        // Ring: original, alt1, alt2, … — original is whatever was landed first.
        let original = undoStack.compactMap { e -> TranscriptSpan? in
            if case .span(let j, let prev) = e.kind, j == i { return prev } else { return nil }
        }.first ?? u.spans[i]
        var ring = [original.text] + original.alternates.map(\.text)
        var seen = Set<String>()
        ring = ring.filter { seen.insert(WordConfusionNetwork.normalize($0)).inserted }
        guard ring.count > 1 else { return .noop(reason: "no alternates") }
        let pos = ((cyclePosition[i] ?? 0) + 1) % ring.count
        cyclePosition[i] = pos
        focusIndex = i
        return replace(spanIndex: i, with: ring[pos], source: .repair, keepAlternates: original.alternates)
    }

    private func scratch() -> RepairResult {
        guard let u = utterance, !scratched else { return .noop(reason: "nothing to scratch") }
        let text = u.spans.joinedText
        guard let sink = replaceSink else { return .failed(.unavailable(reason: "no sink")) }
        let outcome = sink.replace(RepairReplaceRequest(range: fieldOffset..<(fieldOffset + text.utf16.count), expected: text, replacement: "", utteranceID: u.id))
        guard outcome.succeeded else { return .failed(outcome) }
        undoStack.append(UndoEntry(kind: .scratch(text: text, spans: u.spans)))
        scratched = true
        log(original: text, corrected: "", range: u.spans.first!.audioRange.lowerBound...u.spans.last!.audioRange.upperBound, wordsEdited: u.spans.count)
        return .scratched(text: text)
    }

    private func undo() -> RepairResult {
        guard let u = utterance, let entry = undoStack.popLast() else { return .noop(reason: "nothing to undo") }
        guard let sink = replaceSink else { return .failed(.unavailable(reason: "no sink")) }
        switch entry.kind {
        case .scratch(let text, let spans):
            let outcome = sink.replace(RepairReplaceRequest(range: fieldOffset..<fieldOffset, expected: "", replacement: text, utteranceID: u.id))
            guard outcome.succeeded else { undoStack.append(entry); return .failed(outcome) }
            utterance?.spans = spans
            scratched = false
            log(original: "", corrected: text, range: spans.first!.audioRange.lowerBound...spans.last!.audioRange.upperBound, wordsEdited: 0)
            return .undone(spanIndex: nil, restored: text)
        case .span(let i, let previous):
            let range = rangeOfSpan(i)
            let outcome = sink.replace(RepairReplaceRequest(range: range, expected: u.spans[i].text, replacement: previous.text, utteranceID: u.id, spanIndex: i))
            guard outcome.succeeded else { undoStack.append(entry); return .failed(outcome) }
            var restored = previous
            restored.provenance = u.spans[i].provenance + [.repair]
            utterance?.spans[i] = restored
            cyclePosition[i] = 0
            log(original: u.spans[i].text, corrected: previous.text, range: previous.audioRange, wordsEdited: 0)
            return .undone(spanIndex: i, restored: previous.text)
        }
    }

    private func pick(_ n: Int) -> RepairResult {
        guard let u = utterance, !scratched else { return .noop(reason: "nothing landed") }
        let idx = focusIndex ?? u.spans.indices.filter { !u.spans[$0].alternates.isEmpty }.min(by: { u.spans[$0].confidence < u.spans[$1].confidence })
        guard let i = idx, u.spans[i].alternates.indices.contains(n - 1) else { return .noop(reason: "no alternate \(n)") }
        focusIndex = i
        cyclePosition[i] = n
        return replace(spanIndex: i, with: u.spans[i].alternates[n - 1].text, source: .repair)
    }

    // MARK: - Helpers (lock held)

    private func rangeOfSpan(_ index: Int) -> Range<Int> {
        guard let u = utterance else { return 0..<0 }
        var start = fieldOffset
        for j in 0..<index { start += u.spans[j].text.utf16.count + 1 }
        return start..<(start + u.spans[index].text.utf16.count)
    }

    private func replace(spanIndex i: Int, with newText: String, source: Alternate.Source, keepAlternates: [Alternate]? = nil) -> RepairResult {
        guard let u = utterance else { return .noop(reason: "nothing landed") }
        let old = u.spans[i]
        if old.text == newText { return .noop(reason: "unchanged") }
        guard let sink = replaceSink else { return .failed(.unavailable(reason: "no sink")) }
        let outcome = sink.replace(RepairReplaceRequest(range: rangeOfSpan(i), expected: old.text, replacement: newText, utteranceID: u.id, spanIndex: i))
        guard outcome.succeeded else { return .failed(outcome) }
        undoStack.append(UndoEntry(kind: .span(index: i, previous: old)))
        var span = old.rewritten(newText, by: .repair)
        span.needsRepair = false
        // Keep the full alternate set so the user can keep cycling; the displaced text
        // becomes an alternate of its own (tagged .repair) so it stays reachable.
        var alts = keepAlternates ?? old.alternates
        alts.removeAll { WordConfusionNetwork.normalize($0.text) == WordConfusionNetwork.normalize(newText) }
        if !alts.contains(where: { WordConfusionNetwork.normalize($0.text) == WordConfusionNetwork.normalize(old.text) }) {
            alts.append(Alternate(text: old.text, score: 0, source: .repair))
        }
        span.alternates = alts
        utterance?.spans[i] = span
        log(original: old.text, corrected: newText, range: old.audioRange, wordsEdited: 1)
        return .replaced(spanIndex: i, from: old.text, to: newText)
    }

    private func log(original: String, corrected: String, range: ClosedRange<TimeInterval>, wordsEdited: Int) {
        guard let u = utterance else { return }
        correctionSink?.record(CorrectionRecord(utteranceID: u.id.uuidString, createdAt: now(), original: original, corrected: corrected, audioRange: range, source: Self.source))
        if wordsEdited > 0 { zeroEditSink?.markEdited(utteranceID: u.id, wordsEdited: wordsEdited, source: Self.source) }
    }
}
