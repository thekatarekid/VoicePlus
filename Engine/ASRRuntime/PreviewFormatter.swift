import Foundation

/// Light formatting for **preview** text only (V3 §5.2).
///
/// The preview is what the user watches while speaking; the final pass is what lands. The streaming
/// models emit bare lowercase words with no punctuation and numbers spelled out, so the preview looks
/// unlike the text that arrives a moment later and reads as if the recognizer were worse than it is.
/// This closes the cheap part of that gap: sentence-initial capitalization, `i` → `I`, and digits for
/// spoken numbers — V5 K7: written by the final pass's own ITN (`Pipeline.ITNStage`, installed by
/// `App` through `install(normalizer:)`), so preview and final agree by construction.
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
        format(text, normalizer: currentNormalizer())
    }

    /// `format` with an explicit normaliser instead of the installed one (tests; `nil` = none).
    public static func format(_ text: String, normalizer: (@Sendable (String) -> String)?) -> String {
        guard !text.isEmpty else { return text }
        let words = (normalizer?(text) ?? text).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return text }
        var out = words
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

    // MARK: Spoken numbers → digits (V5 K7: the final pass's ITN, not a copy of it)

    private final class Hook: @unchecked Sendable {
        let lock = NSLock()
        var normalize: (@Sendable (String) -> String)?
    }
    private static let hook = Hook()

    /// V5 K7 — the inverse text normaliser the preview runs. `App` installs `Pipeline.ITNStage`
    /// here at launch (`ITNWiring`), so the pill shows the digits that will land: one implementation,
    /// not a second digitiser kept in step by hand. `Engine` cannot import `Pipeline`, hence the hook.
    /// Unset (Engine-only tests, tools), numbers stay words.
    public static func install(normalizer: (@Sendable (String) -> String)?) {
        hook.lock.lock(); hook.normalize = normalizer; hook.lock.unlock()
    }

    private static func currentNormalizer() -> (@Sendable (String) -> String)? {
        hook.lock.lock(); defer { hook.lock.unlock() }
        return hook.normalize
    }

    // MARK: Invariant used by the tests

    /// True when `output` introduces no punctuation character that `input` did not already have.
    /// V5 K7: a number's written form (`3:30`, `$5`, `12,00,000`, `50%`) is the number, not a
    /// punctuation claim, so words containing a digit are not counted.
    public static func addsNoPunctuation(input: String, output: String) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        func marks(_ text: String) -> Set<Character> {
            let words = text.split(separator: " ").filter { !$0.contains(where: \.isNumber) }
            return Set(words.joined(separator: " ").unicodeScalars.filter { punctuation.contains($0) }.map(Character.init))
        }
        let before = marks(input)
        let after = marks(output)
        return after.isSubset(of: before)
    }
}
