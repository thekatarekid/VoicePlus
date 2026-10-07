import Foundation
import Shared

/// Context Writer §2.5 — the recogniser's output as the packet's `Heard`: the raw pre-boost 1-best
/// with per-word confidence and alternates.
///
/// Interim splitter for the packet builder. The integrator replaces it with
/// `HeardWords.make(from:)` (`App/Services/HeardWords.swift`, another wave-1 item) once both land;
/// the two must agree on one rule: a span's confidence is every word's confidence, and a span's
/// alternates attach to its first word (a multi-word span's alternates describe the whole span).
enum PacketHeardWords {
    static let maxAlternates = 5

    static func heard(_ spans: [TranscriptSpan], boosted: String? = nil) -> ContextPacket.Heard {
        let raw = spans.renderedText
        var words: [ContextPacket.HeardWord] = []
        for span in spans {
            let pieces = span.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !pieces.isEmpty else { continue }
            let alternates = alternates(of: span, excluding: pieces.count == 1 ? pieces[0] : span.text)
            for (i, piece) in pieces.enumerated() {
                words.append(.init(text: piece, confidence: span.confidence, alternates: i == 0 ? alternates : []))
            }
        }
        let boostedText = boosted?.trimmingCharacters(in: .whitespacesAndNewlines)
        let differs = boostedText.map { !$0.isEmpty && $0 != raw.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
        return ContextPacket.Heard(raw: raw, words: words, boosted: differs ? boostedText : nil)
    }

    /// Best first, deduplicated, the heard text itself left out. Exact matches only: a
    /// capitalised alternate of a lowercase word ("Rahul" for "rahul") is evidence worth keeping.
    static func alternates(of span: TranscriptSpan, excluding text: String) -> [String] {
        var seen: Set<String> = [text]
        var out: [String] = []
        for alt in span.alternates.sorted(by: { $0.score > $1.score }) {
            let t = alt.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == maxAlternates { break }
        }
        return out
    }
}
