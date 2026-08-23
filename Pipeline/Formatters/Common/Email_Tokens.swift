import Foundation
import Shared

/// A word-level token that remembers which input span it came from, so the formatter can
/// rebuild `[TranscriptSpan]` without losing confidence/audioRange (Bet 9).
struct EmailToken {
    var core: String
    /// Punctuation glued to the end of the word (`. , ! ? : ;`).
    var trailing: String
    let spanIndex: Int
    /// Tokens from low-confidence spans are never altered or removed.
    let locked: Bool
    /// 0 = none, 1 = newline, 2 = paragraph break, before this token.
    var breakBefore = 0
    /// "- " or "1. " for list items.
    var listPrefix = ""
    /// Suppress automatic end-of-sentence period (greeting, sign-off, list item).
    var noAutoPeriod = false
    /// Standalone dash / separator ("—", "-", "--").
    var isDash: Bool { core == "—" || core == "-" || core == "--" || core == "–" }

    var lower: String { core.lowercased() }
    var endsSentence: Bool { trailing.contains(where: { ".!?".contains($0) }) }

    static let punctuation: Set<Character> = [".", ",", "!", "?", ":", ";"]

    static func tokenize(_ spans: [TranscriptSpan]) -> [EmailToken] {
        var out: [EmailToken] = []
        for (i, span) in spans.enumerated() {
            let locked = span.isLowConfidence
            var pendingBreak = 0
            var word = ""
            func flush() {
                guard !word.isEmpty else { return }
                var core = word
                var trailing = ""
                while let last = core.last, punctuation.contains(last), core.count > 1 {
                    trailing.insert(last, at: trailing.startIndex)
                    core.removeLast()
                }
                var token = EmailToken(core: core, trailing: trailing, spanIndex: i, locked: locked)
                token.breakBefore = min(pendingBreak, 2)
                pendingBreak = 0
                word = ""
                out.append(token)
            }
            for ch in span.text {
                if ch == "\n" { flush(); pendingBreak += 1 }
                else if ch == " " || ch == "\t" || ch == "\r" { flush() }
                else { word.append(ch) }
            }
            flush()
        }
        return out
    }

    /// Renders the tokens belonging to `spanIndex` into that span's text.
    static func render(_ tokens: [EmailToken], spanIndex: Int) -> String {
        var s = ""
        for t in tokens where t.spanIndex == spanIndex {
            if t.breakBefore > 0 {
                s += String(repeating: "\n", count: t.breakBefore)
            } else if !s.isEmpty {
                s += " "
            }
            s += t.listPrefix + t.core + t.trailing
        }
        return s
    }
}

/// Joins formatted spans into display text. `Array.joinedText` space-joins; this also
/// collapses the spaces that would otherwise sit next to embedded line breaks.
public enum FormattedText {
    public static func join(_ spans: [TranscriptSpan]) -> String {
        let raw = spans.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            .drop(while: { $0 == "\n" || $0 == " " })
        var out = ""
        var pendingSpace = false
        for ch in raw {
            if ch == " " { pendingSpace = true; continue }
            if ch == "\n" { pendingSpace = false }
            else if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(ch)
        }
        return out
    }
}
