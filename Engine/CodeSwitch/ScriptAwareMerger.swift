import Foundation
import Shared

public extension StageID {
    static let codeSwitchMerge: StageID = "codeswitch.merge"
}

/// Combines Latin + Devanagari word spans into one utterance string with correct spacing and
/// punctuation, and emits `ScriptSegments` for injection. Never drops confidence/audioRange/provenance.
public struct ScriptAwareMerger: Sendable {
    public init() {}

    static let closingPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", "।", "॥", ")", "]", "}", "”", "’"]
    static let openingPunctuation: Set<Character> = ["(", "[", "{", "“", "‘"]
    /// Straight quotes: opening when an even number have been emitted so far, closing otherwise.
    static let straightQuotes: Set<Character> = ["\"", "'"]

    public func merge(_ spans: [TranscriptSpan]) -> ScriptSegments {
        var out: [TranscriptSpan] = []
        var segments: [ScriptSegment] = []
        var text = ""
        var detector = LanguageDetector()

        for (i, raw) in spans.enumerated() {
            let span = raw.touched(by: .codeSwitchMerge)
            out.append(span)
            let word = span.text.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            let script = Script.dominant(in: word)
            let tags = LanguageDetector.tag(word)
            let language = tags.first?.language ?? .unknown
            detector.feed(word)

            // Spacing: none before closing punctuation, none after an opening bracket/quote.
            if !text.isEmpty, Self.needsSpace(before: word, after: text) { text += " " }
            text += word

            // Punctuation-only tokens attach to the previous segment; same script extends it.
            if script == .neutral, var last = segments.popLast() {
                if Self.needsSpace(before: word, after: last.text) { last.text += " " }
                last.text += word
                last.audioRange = last.audioRange.lowerBound...max(last.audioRange.upperBound, span.audioRange.upperBound)
                last.spanIndices.append(i)
                segments.append(last)
            } else if var last = segments.last, last.script == script {
                segments.removeLast()
                last.text += " " + word
                last.audioRange = last.audioRange.lowerBound...max(last.audioRange.upperBound, span.audioRange.upperBound)
                last.spanIndices.append(i)
                last.language = last.language == language ? language : .mixed
                segments.append(last)
            } else {
                segments.append(ScriptSegment(text: word, script: script, language: language,
                                              audioRange: span.audioRange, spanIndices: [i]))
            }
        }
        return ScriptSegments(text: text, segments: segments, spans: out, language: detector.current.language)
    }

    static func needsSpace(before word: String, after text: String) -> Bool {
        guard let first = word.first, let last = text.last else { return false }
        if straightQuotes.contains(first), word.count == 1 {
            return text.filter { $0 == first }.count.isMultiple(of: 2)   // opening quote gets a space before
        }
        if straightQuotes.contains(last), !text.filter({ $0 == last }).count.isMultiple(of: 2) { return false }
        if closingPunctuation.contains(first) && word.allSatisfy({ closingPunctuation.contains($0) }) { return false }
        if openingPunctuation.contains(last) { return false }
        return true
    }
}
