import Foundation
import Shared

/// H6 (Q4) — the explicit "replace the selection" verbs. With text selected, speech is an edit
/// command; only these phrasings replace the selection with the spoken words:
///
/// - "replace with …", "replace this (text) with …", "replace it / the selection / the text with …"
/// - "overwrite …", "overwrite (this) with …"
/// - "change this / it / the text / the selection to …"
/// - "replace" / "replace this (text)" / "overwrite (this)" alone → the notch asks for the new text
///   and the next hold (within the warm window) is the replacement.
///
/// "replace A with B" where A is not "this/it/the selection" is find-and-replace *inside* the
/// selection (a catalogue edit), not this command, so it returns nil here.
///
/// The words after the verb keep their spans (confidence, audio range, provenance): they are
/// dictation, formatted for the field and typed by the normal injector over the selection.
public enum SelectionReplaceCommand: Equatable, Sendable {
    /// Replace the selection with these spans (never empty).
    case replace(with: [TranscriptSpan])
    /// The verb alone: ask "Say the new text" and replace with the next utterance.
    case awaitingText

    /// The notch line while waiting for the new text.
    public static let promptLine = "Say the new text"

    static let objects: [[String]] = [
        ["the", "selected", "text"], ["this", "text"], ["the", "selection"], ["the", "text"], ["that", "text"],
        ["this"], ["it"], ["that"], ["selection"],
    ]
    static let lead: Set<String> = ["please", "ok", "okay", "um", "uh", "so", "now", "just"]

    public static func parse(_ spans: [TranscriptSpan]) -> SelectionReplaceCommand? {
        let tokens = Self.tokens(spans)
        let words = tokens.map(\.norm).filter { !$0.isEmpty }
        var i = 0
        while i < words.count, lead.contains(words[i]) { i += 1 }
        guard i < words.count else { return nil }
        let verb = words[i]
        guard ["replace", "overwrite", "change"].contains(verb) else { return nil }
        i += 1
        var hasObject = false
        for o in objects where Array(words.dropFirst(i).prefix(o.count)) == o {
            i += o.count; hasObject = true; break
        }
        let connector: String? = {
            guard i < words.count else { return nil }
            switch verb {
            case "replace", "overwrite": return words[i] == "with" ? "with" : nil
            default: return words[i] == "to" ? "to" : nil
            }
        }()
        if connector != nil { i += 1 }
        let restCount = words.count - i

        switch verb {
        case "replace":
            if connector == nil {
                // "replace" / "replace this (text)" alone asks for the text; "replace A with B" is
                // find-and-replace inside the selection (not this command).
                return restCount == 0 ? .awaitingText : nil
            }
        case "overwrite":
            if connector == nil, restCount == 0 { return .awaitingText }
        default: // change
            // "change this to …" only; "change this" alone is a free-form edit and "change A to B"
            // is find-and-replace inside the selection.
            guard connector != nil else { return nil }
        }
        _ = hasObject
        guard restCount > 0 else { return .awaitingText }
        let rest = drop(meaningful: i, from: spans, tokens: tokens)
        return rest.isEmpty ? .awaitingText : .replace(with: rest)
    }

    // MARK: Tokens

    struct Token { var span: Int; var text: String; var norm: String }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    static func tokens(_ spans: [TranscriptSpan]) -> [Token] {
        spans.enumerated().flatMap { idx, span in
            span.text.split(whereSeparator: { $0.isWhitespace }).map { Token(span: idx, text: String($0), norm: normalize(String($0))) }
        }
    }

    /// Spans with the first `count` meaningful tokens (and any punctuation-only tokens up to the next
    /// word) removed. A partly consumed span keeps its confidence and audio range; provenance notes
    /// the transform stage.
    static func drop(meaningful count: Int, from spans: [TranscriptSpan], tokens: [Token]) -> [TranscriptSpan] {
        var seen = 0
        var cut = 0
        while cut < tokens.count {
            if seen == count, !tokens[cut].norm.isEmpty { break }
            if !tokens[cut].norm.isEmpty { seen += 1 }
            cut += 1
        }
        var kept: [Int: [String]] = [:]
        var touched = Set<Int>()
        for (n, t) in tokens.enumerated() {
            if n < cut { touched.insert(t.span) } else { kept[t.span, default: []].append(t.text) }
        }
        var out: [TranscriptSpan] = []
        for (idx, span) in spans.enumerated() {
            guard let words = kept[idx], !words.isEmpty else { continue }
            if touched.contains(idx) {
                var copy = span.touched(by: .transform)
                copy.text = words.joined(separator: " ")
                out.append(copy)
            } else {
                out.append(span)
            }
        }
        return out
    }
}
