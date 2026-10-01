import Foundation
import Shared

// MARK: - V5 D3 · Output guard
//
// Every cleanup output passes this before it may replace the rules output. Any one rule rejects:
//
// | rule                     | rejects when                                                         |
// |--------------------------|----------------------------------------------------------------------|
// | `lengthRatio`            | output/input characters ∉ [0.5, 1.5] (an empty output is ratio 0)     |
// | `lowWordOverlap`         | < 60 % of the shorter side's words are shared (case/punctuation-blind) |
// | `assistantPreamble`      | "Sure, here's…", "Cleaned text:", "As an AI…", a trailing "Note:"     |
// | `dictionaryTermDropped`  | a Dictionary term (F2 `personal.dictionary`) in the input is missing |
// | `lowConfidenceChanged`   | a span with confidence < 0.5 (Bet 9) is not in the output verbatim   |
// | `entityCorrected`        | a likely entity was "corrected" to a near-identical word (P5)        |
//
// The overlap is measured against the shorter side so a legitimate retraction ("Thursday, no,
// Friday" → "Friday") passes while a rewrite into new words does not; deletions are bounded by the
// length ratio instead. An accepted output still goes through P5's `EntityGuard.restore`, which puts
// back any likely entity the model only lowercased.
//
// Rejected → the caller keeps the rules output and logs the reason (Q13's log buffer; reason codes
// only, never text).

public struct CleanupGuard: Sendable {
    public enum Rejection: String, Sendable, CaseIterable, Equatable {
        case lengthRatio
        case lowWordOverlap
        case assistantPreamble
        case dictionaryTermDropped
        case lowConfidenceChanged
        case entityCorrected
    }

    public enum Verdict: Sendable, Equatable {
        /// `text` is the output with P5's case restoration applied.
        case accepted(text: String)
        case rejected(Rejection)

        public var isAccepted: Bool { if case .accepted = self { return true } else { return false } }
        public var rejection: Rejection? { if case .rejected(let r) = self { return r } else { return nil } }
    }

    public var lengthBounds: ClosedRange<Double>
    public var minimumOverlap: Double
    /// P5's guard. `nil` skips the entity rule and the restoration (tests without the word lists).
    public var entityGuard: EntityGuard?

    public init(lengthBounds: ClosedRange<Double> = 0.5...1.5, minimumOverlap: Double = 0.6,
                entityGuard: EntityGuard? = EntityGuard()) {
        self.lengthBounds = lengthBounds
        self.minimumOverlap = minimumOverlap
        self.entityGuard = entityGuard
    }

    /// - Parameters:
    ///   - input: the rules output the model was given (plain text, no markers).
    ///   - output: what the model returned.
    ///   - dictionary: the user's Dictionary spellings (F2 `personal.dictionary`).
    ///   - lockedPhrases: texts of the low-confidence spans, in order.
    public func check(input: String, output rawOutput: String, dictionary: [String] = [],
                      lockedPhrases: [String] = []) -> Verdict {
        let output = Self.unmark(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.hasPreamble(input: source, output: output) { return .rejected(.assistantPreamble) }
        if !lengthRatioOK(input: source, output: output) { return .rejected(.lengthRatio) }
        if Self.overlap(source, output) < minimumOverlap { return .rejected(.lowWordOverlap) }
        if Self.dropsTerm(input: source, output: output, dictionary: dictionary) { return .rejected(.dictionaryTermDropped) }
        if !Self.keepsLocked(lockedPhrases, in: output) { return .rejected(.lowConfidenceChanged) }
        if let entityGuard {
            if !entityGuard.corrections(original: source, rewritten: output).isEmpty { return .rejected(.entityCorrected) }
            return .accepted(text: entityGuard.restore(original: source, rewritten: output))
        }
        return .accepted(text: output)
    }

    // MARK: Rules

    func lengthRatioOK(input: String, output: String) -> Bool {
        guard !input.isEmpty else { return output.isEmpty }
        return lengthBounds.contains(Double(output.count) / Double(input.count))
    }

    /// Multiset word overlap over the shorter side.
    static func overlap(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty || !wb.isEmpty else { return 1 }
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for w in wa { counts[w, default: 0] += 1 }
        var shared = 0
        for w in wb where (counts[w] ?? 0) > 0 { counts[w]! -= 1; shared += 1 }
        return Double(shared) / Double(min(wa.count, wb.count))
    }

    /// Case-folded words with edge punctuation stripped ("Friday." → "friday", "sam@x.com" stays).
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "@#$%")))
        }.filter { !$0.isEmpty }
    }

    static let preambles: [String] = [
        "sure", "certainly", "of course", "absolutely", "okay, here", "ok, here", "okay here", "here's", "here is",
        "here are", "the cleaned", "the corrected", "the cleaned-up", "cleaned text", "corrected text",
        "cleaned transcript", "corrected transcript", "cleaned:", "corrected:", "output:", "transcript:",
        "i've cleaned", "i have cleaned", "i cleaned", "i've corrected", "i have corrected", "as an ai",
        "i'm sorry", "i am sorry", "i cannot", "i can't", "i can not", "<transcript>", "<context>",
    ]
    static let trailers: [String] = ["\nnote:", "\n(note", "\nexplanation:", "\nchanges made", "\ni've ", "\ni have "]

    static func hasPreamble(input: String, output: String) -> Bool {
        let out = output.lowercased(), inp = input.lowercased()
        if preambles.contains(where: { out.hasPrefix($0) && !inp.hasPrefix($0) }) { return true }
        return trailers.contains { out.contains($0) && !inp.contains($0) }
    }

    static func dropsTerm(input: String, output: String, dictionary: [String]) -> Bool {
        let inp = input.lowercased(), out = output.lowercased()
        for term in dictionary {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty, containsWord(inp, t) else { continue }
            if !containsWord(out, t) { return true }
        }
        return false
    }

    /// `needle` in `hay` on word boundaries ("Ana" is not in "banana").
    static func containsWord(_ hay: String, _ needle: String) -> Bool {
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            let edge: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if edge(before), edge(after) { return true }
            from = hay.index(after: r.lowerBound)
        }
        return false
    }

    /// Every locked phrase appears verbatim, in order, as whole words ("in" is not kept by "Join").
    static func keepsLocked(_ phrases: [String], in output: String) -> Bool {
        var from = output.startIndex
        for p in phrases {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard let r = rangeOfWord(t, in: output, from: from) else { return false }
            from = r.upperBound
        }
        return true
    }

    /// First occurrence of `needle` in `hay` at or after `from` that does not start or end inside a
    /// word: a letter/number edge of the needle must not touch a letter/number in `hay`.
    static func rangeOfWord(_ needle: String, in hay: String, from: String.Index) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let wordy: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        let checkStart = needle.first.map(wordy) ?? false
        let checkEnd = needle.last.map(wordy) ?? false
        var start = from
        while start < hay.endIndex, let r = hay.range(of: needle, range: start..<hay.endIndex) {
            let beforeOK = !checkStart || r.lowerBound == hay.startIndex || !wordy(hay[hay.index(before: r.lowerBound)])
            let afterOK = !checkEnd || r.upperBound == hay.endIndex || !wordy(hay[r.upperBound])
            if beforeOK && afterOK { return r }
            start = hay.index(after: r.lowerBound)
        }
        return nil
    }

    /// The uncertainty markers the delimited prompt uses; never part of the text.
    static func unmark(_ s: String) -> String {
        s.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
    }
}
