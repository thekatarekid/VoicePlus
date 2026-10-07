import Foundation
import Shared

// A6 — the offset contract of `TurnRecord.uncertainSpans` (investigation 2026-10-06, "Uncertainty
// offsets are misaligned").
//
// Every range is a UTF-16 range of `TurnRecord.finalText` exactly as stored: the payload the pill
// previewed and the injector typed, continuation whitespace included. " Place two" landed after a
// word, so its mark is 1..<6 ("Place"), never 0..<5. The ranges index no other string: not
// `rawText` (what the engine heard, "Place two."), not a trimmed excerpt, not a Today row's text.
// Reading them against any of those is what produced `P⟦lace ⟧two.`; `rebased` moves them onto a
// slice when a surface must show one.
public enum UncertainSpans {
    /// Every span lies inside `text`, is non-empty, and starts and ends on a non-whitespace unit: a
    /// mark covers a word core (`MarkWord.core`), so one that touches a space has drifted.
    public static func index(_ spans: [Range<Int>], in text: String) -> Bool {
        let units = Array(text.utf16)
        func isSpace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
        }
        return spans.allSatisfy { span in
            span.lowerBound >= 0 && span.upperBound <= units.count && !span.isEmpty
                && !isSpace(units[span.lowerBound]) && !isSpace(units[span.upperBound - 1])
        }
    }

    /// `spans` of `stored` moved onto `shown`, when `shown` is a slice of `stored` (an excerpt, the
    /// payload with its continuation whitespace trimmed). A span that falls outside the slice is
    /// dropped; nil when `shown` is not inside `stored` (the spans then say nothing about it).
    public static func rebased(_ spans: [Range<Int>], from stored: String, to shown: String) -> [Range<Int>]? {
        guard let offset = offset(of: shown, in: stored) else { return nil }
        let length = shown.utf16.count
        return spans.compactMap { span in
            let moved = (span.lowerBound - offset)..<(span.upperBound - offset)
            return moved.lowerBound >= 0 && moved.upperBound <= length ? moved : nil
        }
    }

    /// Where `shown` starts inside `stored`, in UTF-16 units. The trimmed payload is matched at its
    /// own position (never an earlier repeat of the same words); any other slice at its first occurrence.
    static func offset(of shown: String, in stored: String) -> Int? {
        if shown == stored { return 0 }
        let leading = stored.prefix { $0.isWhitespace }.utf16.count
        let trailing = stored.reversed().prefix { $0.isWhitespace }.reduce(0) { $0 + $1.utf16.count }
        if stored.utf16.count - leading - trailing == shown.utf16.count,
           MarkWords.slice(stored, leading..<(leading + shown.utf16.count)) == shown {
            return leading
        }
        let found = (stored as NSString).range(of: shown)
        return found.location == NSNotFound || shown.isEmpty ? nil : found.location
    }

    /// `text` with each span wrapped in ⟦ ⟧ — the investigation's notation, and the writer packet's
    /// (`ContextPacket.Heard.marked`). Spans outside `text` are ignored.
    public static func marked(_ text: String, spans: [Range<Int>]) -> String {
        let length = text.utf16.count
        var out = ""
        var cursor = 0
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound })
        where span.lowerBound >= cursor && span.upperBound <= length && !span.isEmpty {
            out += MarkWords.slice(text, cursor..<span.lowerBound) ?? ""
            out += "⟦" + (MarkWords.slice(text, span) ?? "") + "⟧"
            cursor = span.upperBound
        }
        out += MarkWords.slice(text, cursor..<length) ?? ""
        return out
    }
}
