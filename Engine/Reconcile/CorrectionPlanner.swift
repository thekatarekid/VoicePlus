import Foundation
import Shared

/// Where the preview landed in the focused element: `fieldOffset` is the UTF-16 offset of the
/// first preview word; words are assumed space-joined exactly as `[TranscriptSpan].joinedText`.
public struct LandedLayout: Equatable, Sendable {
    public var fieldOffset: Int
    public var words: [String]
    public init(fieldOffset: Int, words: [String]) { self.fieldOffset = fieldOffset; self.words = words }
    public init(fieldOffset: Int, spans: [TranscriptSpan]) { self.init(fieldOffset: fieldOffset, words: spans.map(\.text)) }

    /// UTF-16 range covering preview words `r` (empty range = insertion point before `r.lowerBound`).
    public func range(for r: Range<Int>) -> Range<Int> {
        var start = fieldOffset
        for w in words.prefix(r.lowerBound) { start += w.utf16.count + 1 }
        if r.isEmpty {
            // Insertion: place at the word boundary; the replacement carries its own spacing.
            let at = r.lowerBound == 0 ? start : start - 1
            return at..<at
        }
        var end = start
        for (k, w) in words[r].enumerated() { end += w.utf16.count + (k == 0 ? 0 : 1) }
        return start..<end
    }
}

/// T2 — decides, per disagreement, whether to silently correct, suggest, or drop.
/// (a) semantic difference after case/punctuation normalisation,
/// (b) confidence delta (final − preview) ≥ `deltaThreshold` and final not low-confidence (Bet 9),
/// (c) SAFETY RULE: readback of the target range must equal exactly what we injected.
public struct CorrectionPlanner: Sendable {
    public var deltaThreshold: Float
    public var unknownPreviewConfidence: Float

    public init(deltaThreshold: Float = 0.2, unknownPreviewConfidence: Float = 0.5) {
        self.deltaThreshold = deltaThreshold
        self.unknownPreviewConfidence = unknownPreviewConfidence
    }

    public func plan(utteranceID: UUID, preview: [TranscriptSpan], final: [TranscriptSpan],
                     layout: LandedLayout, readback: DocumentReadback) -> CorrectionPlan {
        let document = readback.currentText()
        let items = WordAligner.disagreements(preview: preview, final: final, unknownPreviewConfidence: unknownPreviewConfidence)
            .map { decide($0, utteranceID: utteranceID, layout: layout, document: document) }
        return CorrectionPlan(utteranceID: utteranceID, items: items)
    }

    func decide(_ d: Disagreement, utteranceID: UUID, layout: LandedLayout, document: String?) -> CorrectionItem {
        let range = layout.range(for: d.previewRange)
        let expected = d.previewRange.isEmpty ? "" : layout.words[d.previewRange].joined(separator: " ")
        var replacement = d.finalText
        if d.previewRange.isEmpty, !replacement.isEmpty {
            // Insertion between words: keep exactly one space on each side.
            replacement = d.previewRange.lowerBound == 0 ? replacement + " " : " " + replacement
        }
        let delta = d.finalConfidence - d.previewConfidence
        var item = CorrectionItem(utteranceID: utteranceID, range: range, expected: expected, replacement: replacement,
                                  confidenceDelta: delta, audioRange: d.audioRange, decision: .correct)
        if WordAligner.normalize(d.previewText) == WordAligner.normalize(d.finalText) {
            item.decision = .drop(reason: .semanticallyEqual); return item
        }
        if d.finalText.isEmpty, d.previewRange.isEmpty { item.decision = .drop(reason: .emptyReplacement); return item }
        if delta < deltaThreshold { item.decision = .drop(reason: .confidenceDeltaBelowThreshold); return item }
        if d.finalConfidence < TranscriptSpan.lowConfidenceThreshold { item.decision = .suggest(reason: .lowFinalConfidence); return item }
        guard let document else { item.decision = .suggest(reason: .readbackUnavailable); return item }
        // Safety rule: the whole landed region must still read as injected, not just the target
        // word — a user edit one word over shifts every offset after it.
        let landedRange = layout.range(for: 0..<layout.words.count)
        guard Self.slice(document, landedRange) == layout.words.joined(separator: " "),
              Self.slice(document, range) == expected else {
            item.decision = .suggest(reason: .safetyMismatch); return item
        }
        return item
    }

    static func slice(_ s: String, _ r: Range<Int>) -> String? {
        let u = Array(s.utf16)
        guard r.lowerBound >= 0, r.upperBound <= u.count else { return nil }
        return String(decoding: u[r], as: UTF16.self)
    }
}

/// Applies a plan through the `ReplaceRangeSink` (Injection re-verifies `expected` at write time)
/// and reports every outcome to the UX sink. Items are applied back-to-front so earlier offsets
/// never shift; a refusal means the document changed under us and we stop touching it.
public struct CorrectionApplier: Sendable {
    public let replaceSink: ReplaceRangeSink
    public let eventSink: CorrectionEventSink?
    public let correctionLog: CorrectionSink?

    public init(replaceSink: ReplaceRangeSink, eventSink: CorrectionEventSink? = nil, correctionLog: CorrectionSink? = nil) {
        self.replaceSink = replaceSink; self.eventSink = eventSink; self.correctionLog = correctionLog
    }

    @discardableResult
    public func apply(_ plan: CorrectionPlan) -> [CorrectionEvent] {
        var events: [CorrectionEvent] = []
        var frozen = false
        for item in plan.items.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let base = CorrectionEvent(utteranceID: item.utteranceID, kind: .refused, range: item.range,
                                       was: item.expected, now: item.replacement, audioRange: item.audioRange)
            var event = base
            switch item.decision {
            case .drop: continue
            case .suggest(let reason): event.kind = .suggested(reason)
            case .correct where frozen: event.kind = .suggested(.safetyMismatch)
            case .correct:
                let outcome = replaceSink.replace(RepairReplaceRequest(range: item.range, expected: item.expected,
                                                                       replacement: item.replacement, utteranceID: item.utteranceID))
                if outcome.succeeded {
                    event.kind = .applied
                    event.range = item.range.lowerBound..<(item.range.lowerBound + item.replacement.utf16.count)
                    correctionLog?.record(CorrectionRecord(utteranceID: item.utteranceID.uuidString, original: item.expected,
                                                           corrected: item.replacement, audioRange: item.audioRange, source: "dualPath"))
                } else { frozen = true }
            }
            events.append(event)
            eventSink?.correction(event)
        }
        return events.reversed()
    }
}
