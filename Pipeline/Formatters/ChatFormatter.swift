import Foundation
import Shared

/// P1.7 T3 — casual-register formatter (Slack, iMessage, Discord…). Deterministic.
///
/// Passes, in order: spoken punctuation → filler removal → self-correction resolution
/// → emoji words → slash commands → optional lowercase-first. (H22: the final full stop is kept;
/// light terminal punctuation runs only when `lightenTerminalKey` is set.)
///
/// Confidence contract (Bet 9): spans with `confidence < 0.5` are never rewritten or merged;
/// they are flagged `needsRepair` and act as hard boundaries for every pass. Removed words
/// are never dropped — their audioRange is merged into a neighbouring high-confidence span.
public struct ChatFormatter: PipelineStage {
    public let id: StageID = .formatterChat

    /// `StageContext.extra` key; "true" lowercases the first letter of the utterance.
    public static let lowercaseFirstKey = "chat.lowercaseFirst"
    /// `StageContext.extra` key; "true" re-enables `lightenTerminalPunctuation` for one run (Lab only).
    /// H22 — off by default: chat composers keep the dictated full stop in both hold-to-talk and
    /// hands-free (owner decision, round 3).
    public static let lightenTerminalKey = "chat.lightenTerminal"
    /// Single-sentence utterances at or below this many words lose their terminal period (opt-in only).
    public static let shortSentenceWordLimit = 20

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        var cells = spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.touched(by: id) }
        cells = Self.resolveSpokenPunctuation(cells)
        cells = Self.removeFillers(cells)
        cells = Self.resolveSelfCorrections(cells)
        cells = Self.resolveEmojiWords(cells)
        cells = Self.resolveSlashCommands(cells)
        if context.extra[Self.lightenTerminalKey] == "true" {
            cells = Self.lightenTerminalPunctuation(cells)
        }
        if context.extra[Self.lowercaseFirstKey] == "true" {
            cells = Self.lowercaseFirst(cells)
        }
        return cells
    }

    /// Joins span texts for display: single spaces, no space around newlines, no doubled spaces.
    public static func render(_ spans: [TranscriptSpan]) -> String {
        var out = ""
        for text in spans.map(\.text) where !text.isEmpty {
            if !out.isEmpty, !out.hasSuffix("\n"), !text.hasPrefix("\n") { out += " " }
            out += text
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Vocabulary

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "hmm", "hm", "er", "erm", "ah", "mhm"]
    static let fillerBigrams: [[String]] = [["you", "know"]]
    /// Correctors that replace the preceding phrase with the following one.
    static let correctorPhrases: [[String]] = [["i", "mean"], ["scratch", "that"], ["no"], ["sorry"], ["rather"], ["actually"]]
    /// Words that make a bare "no" read as an answer rather than a correction.
    static let answerContinuations: Set<String> = [
        "i", "i'm", "i'll", "i've", "we", "you", "it", "it's", "that", "that's", "this", "he", "she", "they",
        "thanks", "thank", "way", "worries", "problem", "idea", "not", "don't", "never", "but", "and", "the",
    ]
    static let spokenPunctuation: [String: String] = [
        "comma": ",", "period": ".", "full stop": ".", "question mark": "?",
        "exclamation mark": "!", "exclamation point": "!", "new line": "\n", "newline": "\n", "new paragraph": "\n\n",
    ]
    static let emoji: [String: String] = [
        "thumbs up": "👍", "thumbsup": "👍", "thumbs down": "👎",
        "smiley face": "🙂", "smiley": "🙂", "smile": "🙂", "wink": "😉", "winking": "😉",
        "heart": "❤️", "red heart": "❤️", "fire": "🔥", "flame": "🔥",
        "laughing": "😂", "crying laughing": "😂", "laugh crying": "😂", "joy": "😂",
        "eyes": "👀", "rocket": "🚀", "party": "🎉", "tada": "🎉", "party popper": "🎉",
        "check mark": "✅", "checkmark": "✅", "check": "✅", "cross mark": "❌",
        "thinking": "🤔", "thinking face": "🤔", "skull": "💀", "wave": "👋", "waving": "👋",
        "clap": "👏", "clapping": "👏", "pray": "🙏", "praying hands": "🙏", "folded hands": "🙏",
        "hundred": "💯", "one hundred": "💯", "sad face": "😢", "sad": "😢", "crying": "😭",
        "sweat smile": "😅", "shrug": "🤷", "facepalm": "🤦", "sparkles": "✨", "star": "⭐",
        "coffee": "☕", "pizza": "🍕", "beer": "🍺", "bug": "🐛", "ship": "🚢", "warning": "⚠️",
    ]

    // MARK: - Helpers

    static func core(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
    }

    static func trailingPunctuation(_ text: String) -> String {
        var tail = ""
        for ch in text.reversed() {
            if ch.isPunctuation || ch.isNewline { tail.insert(ch, at: tail.startIndex) } else { break }
        }
        return tail
    }

    static func stripTrailingPunctuation(_ text: String) -> String {
        String(text.dropLast(trailingPunctuation(text).count))
    }

    /// Merges `spans[range]` into one span carrying `text`. Never called across a low-confidence span.
    static func merge(_ spans: [TranscriptSpan], _ range: ClosedRange<Int>, text: String) -> TranscriptSpan {
        let slice = spans[range]
        var out = slice.first!
        out.text = text
        out.confidence = slice.map(\.confidence).min() ?? out.confidence
        out.audioRange = slice.map(\.audioRange.lowerBound).min()!...slice.map(\.audioRange.upperBound).max()!
        out.alternates = slice.flatMap(\.alternates)
        out.needsRepair = slice.contains { $0.needsRepair }
        return out
    }

    static func allEditable(_ spans: [TranscriptSpan], _ range: ClosedRange<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound < spans.count && !spans[range].contains { $0.isLowConfidence }
    }

    /// Longest phrase from `table` whose words end at index `end` (inclusive), up to `maxWords`.
    static func phrase(endingAt end: Int, in spans: [TranscriptSpan], maxWords: Int, matches: (String) -> Bool) -> Int? {
        var best: Int?
        for length in 1...maxWords {
            let start = end - length + 1
            guard start >= 0 else { break }
            let words = spans[start...end].map { core($0.text) }.joined(separator: " ")
            if matches(words) { best = start }
        }
        return best
    }

    /// Folds `spans[range]` (which carry no surviving text) into a neighbouring editable span.
    /// Returns nil when no editable neighbour exists (the words are then left untouched).
    static func absorb(_ spans: [TranscriptSpan], _ range: ClosedRange<Int>) -> [TranscriptSpan]? {
        var out = spans
        let prev = range.lowerBound - 1, next = range.upperBound + 1
        if prev >= 0, !spans[prev].isLowConfidence {
            var keep = stripTrailingPunctuation(spans[prev].text)
            let removedTail = trailingPunctuation(spans[range.upperBound].text)
            let prevTail = trailingPunctuation(spans[prev].text)
            // Commas bracketing a filler ("so, um, I") vanish with it; any other mark survives.
            if removedTail.isEmpty { keep += prevTail == "," ? "" : prevTail }
            else if !(removedTail == "," && prevTail == ",") { keep += removedTail }
            out.replaceSubrange(prev...range.upperBound, with: [merge(spans, prev...range.upperBound, text: keep)])
            return out
        }
        if next < spans.count, !spans[next].isLowConfidence {
            out.replaceSubrange(range.lowerBound...next, with: [merge(spans, range.lowerBound...next, text: spans[next].text)])
            return out
        }
        return nil
    }

    // MARK: - Passes

    static func resolveSpokenPunctuation(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        var out = spans
        var i = 0
        while i < out.count {
            if let start = phrase(endingAt: i, in: out, maxWords: 2, matches: { spokenPunctuation[$0] != nil }),
               allEditable(out, start...i), start > 0, !out[start - 1].isLowConfidence {
                let words = out[start...i].map { core($0.text) }.joined(separator: " ")
                let mark = spokenPunctuation[words]!
                let base = mark.hasPrefix("\n") ? out[start - 1].text : stripTrailingPunctuation(out[start - 1].text)
                out.replaceSubrange((start - 1)...i, with: [merge(out, (start - 1)...i, text: base + mark)])
                i = start
            } else {
                i += 1
            }
        }
        return out
    }

    static func removeFillers(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        var out = spans
        var i = 0
        while i < out.count {
            let isBigram = i > 0 && fillerBigrams.contains([core(out[i - 1].text), core(out[i].text)])
            let start = isBigram ? i - 1 : i
            if (isBigram || fillers.contains(core(out[i].text))), allEditable(out, start...i),
               let folded = absorb(out, start...i) {
                out = folded
                i = max(start, 0)
            } else {
                i += 1
            }
        }
        return out
    }

    static func resolveSelfCorrections(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        var out = spans
        var i = 0
        while i < out.count {
            guard let cStart = phrase(endingAt: i, in: out, maxWords: 2, matches: { w in correctorPhrases.contains(w.split(separator: " ").map(String.init)) }),
                  cStart > 0, i + 1 < out.count, allEditable(out, (cStart - 1)...(i + 1)) else { i += 1; continue }
            let corrector = out[cStart...i].map { core($0.text) }.joined(separator: " ")
            let words = out[cStart...i].map(\.text)
            let nextCore = core(out[i + 1].text)
            if corrector == "no" {
                let punctuated = trailingPunctuation(words.last!).contains(",") || trailingPunctuation(out[cStart - 1].text).contains(where: { ",-—".contains($0) })
                if !punctuated, answerContinuations.contains(nextCore) { i += 1; continue }
            }
            if corrector == "scratch that" {
                // Delete the whole preceding clause (back to the previous sentence boundary); next text continues.
                var clauseStart = cStart - 1
                while clauseStart > 0, !out[clauseStart - 1].isLowConfidence, !trailingPunctuation(out[clauseStart - 1].text).contains(where: { ".?!\n".contains($0) }) {
                    clauseStart -= 1
                }
                let keepText = i + 1 < out.count ? out[i + 1].text : ""
                out.replaceSubrange(clauseStart...(i + 1), with: [merge(out, clauseStart...(i + 1), text: keepText)])
                i = clauseStart + 1
                continue
            }
            // Choose replacement width k: largest k ≤ 3 whose shared leading words match ("on Friday no on Thursday").
            var k = 1
            for candidate in 2...3 {
                let xStart = cStart - candidate, yEnd = i + candidate
                guard xStart >= 0, yEnd < out.count, allEditable(out, xStart...yEnd) else { break }
                let xLead = out[xStart..<(xStart + candidate - 1)].map { core($0.text) }
                let yLead = out[(i + 1)..<(i + candidate)].map { core($0.text) }
                if xLead == yLead { k = candidate }
            }
            let xStart = cStart - k, yEnd = i + k
            let yText = out[(i + 1)...yEnd].map(\.text).joined(separator: " ")
            let xTail = trailingPunctuation(out[cStart - 1].text).filter { !",-—".contains($0) }
            let text = trailingPunctuation(yText).isEmpty ? yText + xTail : yText
            out.replaceSubrange(xStart...yEnd, with: [merge(out, xStart...yEnd, text: text)])
            i = xStart + 1
        }
        return out
    }

    static func resolveEmojiWords(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        var out = spans
        var i = 0
        while i < out.count {
            guard core(out[i].text) == "emoji" || core(out[i].text) == "emojis", i > 0 else { i += 1; continue }
            if let start = phrase(endingAt: i - 1, in: out, maxWords: 3, matches: { emoji[$0] != nil }), allEditable(out, start...i) {
                let key = out[start...(i - 1)].map { core($0.text) }.joined(separator: " ")
                let text = emoji[key]! + trailingPunctuation(out[i].text)
                out.replaceSubrange(start...i, with: [merge(out, start...i, text: text)])
                i = start + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func resolveSlashCommands(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        var out = spans
        var i = 0
        while i < out.count {
            guard core(out[i].text) == "slash", i + 1 < out.count else { i += 1; continue }
            let atStart = i == 0 || out[i - 1].text.hasSuffix("\n")
            if atStart, allEditable(out, i...(i + 1)) {
                let text = "/" + stripTrailingPunctuation(out[i + 1].text).lowercased() + trailingPunctuation(out[i + 1].text)
                out.replaceSubrange(i...(i + 1), with: [merge(out, i...(i + 1), text: text)])
                i += 1
            } else if !atStart, allEditable(out, (i - 1)...(i + 1)), trailingPunctuation(out[i - 1].text).isEmpty, trailingPunctuation(out[i].text).isEmpty {
                let text = out[i - 1].text + "/" + out[i + 1].text
                out.replaceSubrange((i - 1)...(i + 1), with: [merge(out, (i - 1)...(i + 1), text: text)])
                i = max(i - 1, 0) + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func lightenTerminalPunctuation(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        guard let last = spans.indices.last, !spans[last].isLowConfidence else { return spans }
        var out = spans
        let text = out[last].text
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return out }
        let sentenceBreaks = out.dropLast().flatMap { $0.text.filter { ".?!".contains($0) } }.count
            + text.dropLast().filter { ".?!".contains($0) }.count
        let wordCount = out.map { $0.text.split(whereSeparator: { $0 == " " || $0.isNewline }).count }.reduce(0, +)
        if sentenceBreaks == 0, wordCount <= shortSentenceWordLimit {
            out[last].text = String(text.dropLast())
        }
        return out
    }

    static func lowercaseFirst(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        guard let first = spans.firstIndex(where: { !$0.text.isEmpty }), !spans[first].isLowConfidence else { return spans }
        var out = spans
        let text = out[first].text
        let word = core(text)
        let isAcronym = text.count > 1 && text.filter(\.isLetter).allSatisfy(\.isUppercase)
        guard let head = text.first, head.isUppercase, word != "i", !word.hasPrefix("i'"), !isAcronym else { return out }
        out[first].text = head.lowercased() + text.dropFirst()
        return out
    }
}
