import Foundation

/// Light formatting for **preview** text only (V3 §5.2).
///
/// The preview is what the user watches while speaking; the final pass is what lands. The streaming
/// models emit bare lowercase words with no punctuation and numbers spelled out, so the preview looks
/// unlike the text that arrives a moment later and reads as if the recognizer were worse than it is.
/// This closes the cheap part of that gap: sentence-initial capitalization, `i` → `I`, and digits for
/// spoken numbers.
///
/// **It never claims punctuation it does not have.** No full stops, commas, question marks or
/// hyphens are ever added, and no word is capitalized because it might follow a sentence boundary —
/// without punctuation there is no way to know where one is. `addsNoPunctuation` is the invariant the
/// tests assert: the set of punctuation characters in the output is a subset of the input's.
///
/// Applied by wrapping any `PreviewRecognizer` in `FormattedPreviewRecognizer`, so the final path is
/// untouched: `Pipeline` still owns formatting for committed text.
public enum PreviewFormatter {

    /// Formats a cumulative preview string. Idempotent, and safe on the empty string.
    public static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return text }
        var out = digitize(words)
        for i in out.indices where isBareI(out[i]) {
            out[i] = "I" + out[i].dropFirst()
        }
        if let first = out.first, let head = first.first, head.isLowercase {
            out[0] = head.uppercased() + first.dropFirst()
        }
        return out.joined(separator: " ")
    }

    /// `i`, `i'm`, `i'll`, `i've`, `i'd` — the one case where capitalization needs no sentence.
    private static func isBareI(_ word: String) -> Bool {
        guard word.first == "i" else { return false }
        let rest = word.dropFirst()
        return rest.isEmpty || ["'m", "'ll", "'ve", "'d", "'m,", "'d,"].contains(String(rest))
    }

    // MARK: Spoken numbers → digits

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private enum Kind { case unit, teen, ten, hundred, scale }

    private static func kind(_ word: String) -> Kind? {
        if units[word] != nil { return .unit }
        if teens[word] != nil { return .teen }
        if tens[word] != nil { return .ten }
        if word == "hundred" { return .hundred }
        if scales[word] != nil { return .scale }
        return nil
    }

    /// Rewrites every maximal run of number words. A run that composes to a value ≥ 10 becomes
    /// digits; a run that is a single small word ("two of the large ones", "meet at four") is left
    /// alone, because that is how the final text writes it too and a bare `2` there would be a
    /// change, not an improvement.
    private static func digitize(_ words: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []          // number words, exactly as they arrived

        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(contentsOf: convert(run: run))
            run = []
        }

        for word in words {
            if kind(word.lowercased()) != nil, word == word.lowercased() {  // unpunctuated, lowercase
                run.append(word.lowercased())
            } else {
                flushRun()
                out.append(word)
            }
        }
        flushRun()
        return out
    }

    /// Splits a run into the numbers it actually spells and renders each one.
    private static func convert(run: [String]) -> [String] {
        var rendered: [String] = []
        var group: [String] = []

        func emit() {
            guard !group.isEmpty else { return }
            // A bare magnitude ("a hundred people") is a word, not a number: without something to
            // multiply it is the writer's choice, and the preview does not get to make it.
            let hasValue = group.contains { kind($0) == .unit || kind($0) == .teen || kind($0) == .ten }
            let value = value(of: group)
            if hasValue, value >= 10, let text = digits(value) {
                rendered.append(text)
            } else {
                rendered.append(contentsOf: group)   // "one", "four", "six" stay words
            }
            group = []
        }

        var previous: Kind?
        for word in run {
            let k = kind(word)!
            if let previous, !canExtend(previous: previous, with: k) { emit() }
            group.append(word)
            previous = k
        }
        emit()
        return rendered
    }

    /// Whether `next` continues the number `group` already holds, or starts a new one.
    /// "eleven forty five" is two numbers (11, 45); "twenty five" is one (25).
    private static func canExtend(previous: Kind, with next: Kind) -> Bool {
        switch (previous, next) {
        case (.unit, .hundred), (.unit, .scale),
             (.teen, .hundred), (.teen, .scale),
             (.ten, .unit), (.ten, .scale),
             (.hundred, .unit), (.hundred, .teen), (.hundred, .ten), (.hundred, .scale),
             (.scale, .unit), (.scale, .teen), (.scale, .ten), (.scale, .hundred):
            return true
        default:
            return false
        }
    }

    /// Standard composition: units/teens/tens accumulate, `hundred` multiplies, scales carry.
    private static func value(of group: [String]) -> Int {
        var total = 0, current = 0
        for word in group {
            if let v = units[word] { current += v }
            else if let v = teens[word] { current += v }
            else if let v = tens[word] { current += v }
            else if word == "hundred" { current = max(current, 1) * 100 }
            else if let scale = scales[word] { total += max(current, 1) * scale; current = 0 }
        }
        return total + current
    }

    /// Plain digits, no grouping separators: a preview that writes `2,340` is claiming a comma it did
    /// not hear. The final pass adds grouping if the model does.
    private static func digits(_ value: Int) -> String? {
        value >= 0 ? String(value) : nil
    }

    // MARK: Invariant used by the tests

    /// True when `output` introduces no punctuation character that `input` did not already have.
    public static func addsNoPunctuation(input: String, output: String) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let before = Set(input.unicodeScalars.filter { punctuation.contains($0) }.map(Character.init))
        let after = Set(output.unicodeScalars.filter { punctuation.contains($0) }.map(Character.init))
        return after.isSubset(of: before)
    }
}
