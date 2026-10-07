import Foundation
import Shared

/// The ways one model word (or a short run of them) can be explained by the heard words at a
/// cursor. Tried in order; the first that fits wins. Everything but the formatting rules needs
/// an **uncertain** heard word (Bet 9): confident words only ever change their shape.
struct WriterGuardEvidence {
    typealias PhoneticEncoder = WriterGuard.PhoneticEncoder

    struct Match: Equatable {
        var heardCount: Int
        var outputCount: Int
    }

    /// A written term with the word lists it may have been heard as (vocabulary spoken forms and
    /// the heard words the matcher saw; a screen term is its own spoken form).
    struct Term {
        var written: [String]     // keys of the written tokens
        var spoken: [[String]]    // keys per spoken form
        var fromVocabulary: Bool
    }

    let phonetic: PhoneticEncoder?
    let terms: [Term]

    /// Most heard words one explanation may consume.
    static let maxRun = 6

    init(phonetic: PhoneticEncoder?, vocabulary: [ContextPacket.VocabularyMatch], screenTerms: [String]) {
        self.phonetic = phonetic
        var terms: [Term] = []
        for v in vocabulary {
            let written = Self.keys(v.term)
            guard !written.isEmpty else { continue }
            let spoken = [v.spokenForm, v.heard, v.term].map(Self.keys).filter { !$0.isEmpty && $0.count <= Self.maxRun }
            terms.append(Term(written: written, spoken: Self.unique(spoken), fromVocabulary: true))
        }
        for s in screenTerms.prefix(40) {
            let written = Self.keys(s)
            guard !written.isEmpty, written.count <= Self.maxRun else { continue }
            terms.append(Term(written: written, spoken: [written], fromVocabulary: false))
        }
        self.terms = terms
    }

    /// Explains `output[j...]` with `heard[idx[s]...]`, or nil.
    func explain(heard: [WriterGuard.HeardToken], at idx: [Int], from s: Int, output: [String], at j: Int) -> Match? {
        let remainingHeard = idx.count - s
        let remainingOut = output.count - j
        guard remainingHeard >= 1, remainingOut >= 1 else { return nil }
        let heardKeys = (0..<min(Self.maxRun, remainingHeard)).map { heard[idx[s + $0]].key }
        let outKeys = (0..<min(Self.maxRun, remainingOut)).map { WriterGuard.key(output[j + $0]) }
        let first = heard[idx[s]]

        // 1. Same word, different shape (case, punctuation, hyphen, apostrophe).
        if heardKeys[0] == outKeys[0] { return Match(heardCount: 1, outputCount: 1) }

        // 2. Joins and splits: "web site" → "website", "Qwen4B" → "Qwen 4B".
        for k in 2...max(2, heardKeys.count) where k <= heardKeys.count
        && heardKeys[..<k].joined() == outKeys[0] { return Match(heardCount: k, outputCount: 1) }
        for m in 2...max(2, outKeys.count) where m <= outKeys.count
        && outKeys[..<m].joined() == heardKeys[0] { return Match(heardCount: 1, outputCount: m) }

        // 3. A number the heard words read as ("twenty five" → "25", "four B" → "4B", "fifty dollars" → "$50").
        if let (number, suffix) = WriterSpokenNumbers.writtenNumber(output[j]) {
            for k in stride(from: heardKeys.count, through: 1, by: -1) {
                let run = Array(heardKeys[..<k])
                guard run.allSatisfy({ WriterSpokenNumbers.isNumberWord($0) || WriterSpokenNumbers.unitSymbols[$0] != nil }) else { continue }
                let readings = WriterSpokenNumbers.readings(run)
                if readings.contains(number + suffix) { return Match(heardCount: k, outputCount: 1) }
                guard readings.contains(number) else { continue }
                if suffix.isEmpty { return Match(heardCount: k, outputCount: 1) }
                if k < heardKeys.count, heardKeys[k] == suffix { return Match(heardCount: k + 1, outputCount: 1) }
            }
        }

        // 4. A vocabulary or screen term whose spoken form matches the heard words.
        for term in terms where term.written.count <= outKeys.count && Array(outKeys[..<term.written.count]) == term.written {
            for spoken in term.spoken where spoken.count <= heardKeys.count {
                let run = Array(heardKeys[..<spoken.count])
                if run == spoken {
                    // The user's own spelling for exactly these words: formatting, any confidence.
                    if term.fromVocabulary || run != term.written { return Match(heardCount: spoken.count, outputCount: term.written.count) }
                    continue
                }
                let tokens = (0..<spoken.count).map { heard[idx[s + $0]] }
                guard tokens.contains(where: \.isUncertain) else { continue }
                let perWord = zip(run, spoken).allSatisfy { h, f in
                    h == f || soundsAlike(h, f, multiWord: spoken.count > 1) || tokens.contains { t in t.key == h && alternate(t, is: f) }
                }
                if perWord { return Match(heardCount: spoken.count, outputCount: term.written.count) }
            }
        }

        // 5. The recogniser's own alternates, or a sound-alike — uncertain words only.
        guard first.isUncertain else { return nil }
        if alternate(first, is: outKeys[0]) { return Match(heardCount: 1, outputCount: 1) }
        if soundsAlike(heardKeys[0], outKeys[0], multiWord: false) { return Match(heardCount: 1, outputCount: 1) }
        return nil
    }

    func alternate(_ token: WriterGuard.HeardToken, is key: String) -> Bool {
        token.alternates.contains { WriterGuard.key($0) == key }
    }

    /// Sound-alike gate: Double Metaphone agreement plus a spelling floor (the single-word floor
    /// is the false-swap guard of the repair stage, relaxed a little because the model chose the
    /// word with the packet in hand). Without an encoder only a near-identical spelling passes.
    func soundsAlike(_ heard: String, _ written: String, multiWord: Bool) -> Bool {
        guard !heard.isEmpty, !written.isEmpty else { return false }
        let spell = ContextRepairStage.spelling(heard, written)
        guard let phonetic else { return heard.count >= 4 && spell >= 0.75 }
        switch ContextRepairStage.phoneticMatch(heard, written, phonetic) {
        case .strong: return multiWord ? spell >= 0.34 : (spell >= 0.5 || written.count <= 3)
        case .near: return spell >= (multiWord ? 0.5 : 0.6)
        case .none: return heard.count >= 4 && spell >= 0.8
        }
    }

    static func keys(_ s: String) -> [String] {
        WordDiff.tokens(s).map(WriterGuard.key).filter { !$0.isEmpty }
    }

    static func unique(_ forms: [[String]]) -> [[String]] {
        var seen = Set<String>(), out: [[String]] = []
        for f in forms where seen.insert(f.joined(separator: " ")).inserted { out.append(f) }
        return out
    }
}
