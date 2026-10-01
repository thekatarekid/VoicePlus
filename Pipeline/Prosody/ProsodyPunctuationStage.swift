import Foundation
import Shared

// V5 K8 — prosody punctuation. The recogniser punctuates from words; pauses and pitch say more.
//
// Phase 1 (span timings only): a pause ≥ 600 ms after a word is a sentence boundary (period, next word
// capitalised); 250–600 ms is a comma — in both cases only where the model put no punctuation, the
// word is confident, and the user did not dictate the punctuation.
// Phase 2 (pitch): a sentence end whose F0 rises (`ProsodyCues`, from the utterance audio) *and* that
// carries a lexical question cue (wh-word / inverted auxiliary first, or a tag like "right") ends
// with "?" — replacing a model period, never a spoken one.
//
// Prose only (code and terminal keep their text). Off by default behind `prosodyPunctuation` until
// the V1 LibriSpeech-PC gate (punctuation F1 up, WER unchanged) passes.

public struct ProsodyPunctuationStage: PipelineStage {
    public static let stageID: StageID = "format.prosodyPunctuation"
    public let id: StageID = ProsodyPunctuationStage.stageID

    public static let flag = FeatureFlag(
        id: "prosodyPunctuation", defaultOn: false,
        description: "K8 — pause/pitch punctuation (≥600 ms → sentence, 250–600 ms → comma, rising end + cue → ?). "
            + "Gate: V1 LibriSpeech-PC punctuation F1 up with WER unchanged.")

    public static let sentencePause: TimeInterval = 0.6
    public static let commaPause: TimeInterval = 0.25
    /// Words since the last boundary before a pause may become a comma (no "Yes, ok, so," chains).
    public static let minClauseWords = 2

    static let wh: Set<String> = ["what", "who", "whom", "whose", "where", "when", "why", "how", "which"]
    static let aux: Set<String> = [
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "shall",
        "may", "might", "must", "have", "has", "had", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't",
        "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't", "haven't", "hasn't",
    ]
    static let tags: Set<String> = ["right", "okay", "ok", "correct", "yeah", "huh", "no"]

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        var out = spans.map { s -> TranscriptSpan in var c = s; c.provenance.append(id); return c }
        guard context.isEnabled(Self.flag), Self.applies(to: context.register), out.count > 1 || ProsodyCues(encoded: context.extra[ProsodyCues.extraKey]) != nil else {
            return out
        }
        let cues = ProsodyCues(encoded: context.extra[ProsodyCues.extraKey])
        Self.punctuate(&out, cues: cues)
        return out
    }

    static func applies(to register: Utterance.Register) -> Bool {
        switch register {
        case .code, .terminal: return false
        default: return true
        }
    }

    /// The rules, on spans in order. Mutates text / `punctuationOrigin` only.
    static func punctuate(_ spans: inout [TranscriptSpan], cues: ProsodyCues?) {
        var sentenceStart = 0
        var clauseWords = 0
        for i in spans.indices {
            clauseWords += 1
            let last = i == spans.count - 1
            let gap = last ? .infinity : spans[i + 1].audioRange.lowerBound - spans[i].audioRange.upperBound
            let editable = spans[i].confidence >= TranscriptSpan.lowConfidenceThreshold && spans[i].punctuationOrigin != .spoken
            let trailing = trailingPunctuation(spans[i].text)
            let endsSentence = last || gap >= sentencePause || [".", "?", "!"].contains(trailing)

            if endsSentence {
                // Phase 2: rising end + lexical cue → "?".
                if editable, let cues, cues.rises(at: spans[i].audioRange.upperBound), trailing != "?", trailing != "!",
                   isQuestion(spans[sentenceStart...i].map(\.text)) {
                    spans[i].text = stripTrailing(spans[i].text) + "?"
                    spans[i].punctuationOrigin = .stage
                } else if !last, trailing == nil, editable, gap >= sentencePause {
                    spans[i].text += "."
                    spans[i].punctuationOrigin = .stage
                }
                if !last, [".", "?", "!"].contains(trailingPunctuation(spans[i].text)) {
                    capitalizeFirst(&spans[i + 1])
                }
                sentenceStart = i + 1
                clauseWords = 0
                continue
            }
            if trailing != nil { clauseWords = 0; continue }
            if editable, gap >= commaPause, clauseWords >= minClauseWords, i + 1 < spans.count - 1 {
                spans[i].text += ","
                spans[i].punctuationOrigin = .stage
                clauseWords = 0
            }
        }
    }

    static func trailingPunctuation(_ text: String) -> Character? {
        guard let c = text.last, ".,?!;:…—".contains(c) else { return nil }
        return c
    }

    static func stripTrailing(_ text: String) -> String {
        var t = text
        while let c = t.last, ".,;:…".contains(c) { t.removeLast() }
        return t
    }

    static func capitalizeFirst(_ span: inout TranscriptSpan) {
        guard span.confidence >= TranscriptSpan.lowConfidenceThreshold, let f = span.text.first, f.isLowercase else { return }
        span.text = f.uppercased() + span.text.dropFirst()
    }

    static func normalized(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// A lexical question cue: wh-word or inverted auxiliary first, or a question tag last.
    public static func isQuestion(_ words: [String]) -> Bool {
        let ws = words.map(normalized).filter { !$0.isEmpty }
        guard let first = ws.first, let lastWord = ws.last else { return false }
        if wh.contains(first) || aux.contains(first) { return true }
        return ws.count >= 3 && tags.contains(lastWord)
    }
}
