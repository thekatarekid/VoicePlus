import Foundation
import Shared

// Context Writer (VoicePlus_ContextWriter_Plan.md §2.5) — the recogniser's words for
// `ContextPacket.Heard`: what was heard, word by word, with the decoder's confidence and its
// alternates. Built from the raw spans (pre-boost, before formatting), so the packet carries the
// engine's own output; the pill's marks stay `UncertaintyMarkMapper`'s, through formatting.
public enum HeardWords {
    /// Alternates kept per word (plan §2.5 "top-K"; design §8.8 offers three).
    public static let topK = 3

    /// One `HeardWord` per whitespace-delimited word of each span, in order, punctuation as the
    /// recogniser wrote it ("two."). A word carries its span's confidence. Its alternates are the
    /// span's, best score first, deduplicated (case and outer punctuation set aside), never the word
    /// itself, at most `topK`: a single-word span keeps every alternate; an alternate of a multi-word
    /// span is attributed by position when it has the same number of words and dropped otherwise
    /// (a phrase's alternate cannot be pinned to one word). Streaming placeholders (`audioRange`
    /// 0…0, confidence 0.5) carry no decoder confidence and pass through unflagged.
    public static func make(from spans: [TranscriptSpan], topK: Int = topK) -> [ContextPacket.HeardWord] {
        var out: [ContextPacket.HeardWord] = []
        for span in spans {
            let words = span.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let ranked = span.alternates.sorted { $0.score > $1.score }
            for (position, word) in words.enumerated() {
                var seen: Set<String> = [key(word)]
                var alternates: [String] = []
                for alternate in ranked where alternates.count < topK {
                    guard let candidate = candidate(alternate.text, position: position, of: words.count),
                          !key(candidate).isEmpty, seen.insert(key(candidate)).inserted else { continue }
                    alternates.append(candidate)
                }
                out.append(ContextPacket.HeardWord(text: word, confidence: span.confidence, alternates: alternates))
            }
        }
        return out
    }

    /// The part of an alternate that stands for word `position` of a `count`-word span.
    static func candidate(_ text: String, position: Int, of count: Int) -> String? {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return nil }
        if count == 1 { return parts.count == 1 ? parts[0] : parts.joined(separator: " ") }
        return parts.count == count ? parts[position] : nil
    }

    /// The identity two alternates are compared by: lower-cased letters, digits and inner spaces,
    /// so "T." and "t" are one alternate, "." is none, and "six teen" stays apart from "sixteen".
    static func key(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
            .split(separator: " ").joined(separator: " ")
    }
}
