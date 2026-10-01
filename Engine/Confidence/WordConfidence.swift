import Foundation
import Shared

/// A word assembled from sub-word tokens, with the min-prob confidence rule (Bet 9 source of truth).
public struct ScoredWord: Equatable, Sendable {
    public var text: String
    /// min over member-token probabilities, 0…1.
    public var confidence: Float
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var tokens: [DecodedToken]

    public init(text: String, confidence: Float, startTime: TimeInterval, endTime: TimeInterval, tokens: [DecodedToken]) {
        self.text = text
        self.confidence = confidence
        self.startTime = startTime
        self.endTime = endTime
        self.tokens = tokens
    }
}

public enum WordConfidence {
    /// Group sub-word tokens into words at `isWordStart` boundaries. Word confidence is the
    /// **minimum** token probability (a word is only as trustworthy as its shakiest piece).
    /// Empty-text tokens (pure word markers) extend the timing of the word they open but
    /// do not contribute text; their probability still counts.
    public static func aggregate(_ tokens: [DecodedToken]) -> [ScoredWord] {
        var words: [ScoredWord] = []
        var current: [DecodedToken] = []

        func flush() {
            guard !current.isEmpty else { return }
            let text = current.map(\.strippedText).joined()
            if !text.isEmpty {
                words.append(ScoredWord(
                    text: text,
                    confidence: current.map(\.probability).min() ?? 0,
                    startTime: current.first!.startTime,
                    endTime: current.map(\.endTime).max() ?? current.first!.startTime,
                    tokens: current
                ))
            }
            current.removeAll()
        }

        for token in tokens {
            if token.isWordStart { flush() }
            current.append(token)
        }
        flush()
        return words
    }

    /// Map tokens → `TranscriptSpan`s, one span per word, provenance `[.asr]`, alternates from the
    /// tokens' joint candidates (V5 B3).
    /// `timeOffset` shifts all timestamps (e.g. chunk start within an utterance).
    public static func spans(from tokens: [DecodedToken], timeOffset: TimeInterval = 0) -> [TranscriptSpan] {
        aggregate(tokens).map { w in
            let start = max(0, w.startTime + timeOffset)
            let end = max(start, w.endTime + timeOffset)
            // V5 B3 — real N-best: word alternates from the tokens' joint top-K (empty when none).
            return TranscriptSpan(text: w.text, confidence: w.confidence, audioRange: start...end,
                                  alternates: WordAlternates.alternates(for: w.tokens), provenance: [.asr])
        }
    }

    /// Mean confidence over spans (utterance-level sanity number for the Lab). 0 if empty.
    public static func utteranceConfidence(_ spans: [TranscriptSpan]) -> Float {
        guard !spans.isEmpty else { return 0 }
        return spans.map(\.confidence).reduce(0, +) / Float(spans.count)
    }
}
