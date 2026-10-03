import Foundation

/// H18 — the token-level exact heard-alias rewrite: where the final pass wrote a listed term's
/// heard alias word for word ("hold to talk"), the term's written form ("hold-to-talk") replaces
/// the run. Untouched words keep their tokens bit-for-bit (confidence, audio range, ids); the
/// rewritten run spans the audio of the words it replaced and takes their lowest confidence
/// (`BoostAlignment`, tagged `.boosted`).
public enum HeardAliasRewrite {
    /// Nil when nothing matched.
    public static func apply(_ tokens: [DecodedToken], terms: [String]) -> BoostOutcome? {
        guard !tokens.isEmpty, terms.contains(where: { !HeardAliases.aliases(for: $0).isEmpty }) else { return nil }
        let text = BoostAlignment.words(tokens).map(\.text).joined(separator: " ")
        let (rewritten, reps) = HeardAliasText.rewrite(text, terms: terms)
        guard !reps.isEmpty else { return nil }
        let out = BoostAlignment.apply(rescoredText: rewritten, to: tokens)
        guard out != tokens else { return nil }
        return BoostOutcome(tokens: out, replacements: reps.map { .init(original: $0.original, replacement: $0.replacement) })
    }

    /// The alias pass followed by the CTC rescore (which ran on the alias pass's tokens).
    public static func merge(_ aliased: BoostOutcome?, _ rescored: BoostOutcome?) -> BoostOutcome? {
        guard let aliased else { return rescored }
        guard let rescored else { return aliased }
        return BoostOutcome(tokens: rescored.tokens, replacements: aliased.replacements + rescored.replacements,
                            detectedTerms: rescored.detectedTerms)
    }
}
