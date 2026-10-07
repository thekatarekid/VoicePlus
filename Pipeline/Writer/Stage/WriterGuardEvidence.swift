import Foundation
import Shared

/// The ways one model word (or a short run of them) can be explained by the heard words at a
/// cursor. Tried in order; the first that fits wins.
///
/// Acoustics are the constraint, not spelling (plan §1.4): an **uncertain** heard word may become
/// any word that sounds like it (Double Metaphone agreement, a sane length), one of its recogniser
/// alternates, or a vocabulary / screen term. A **confident** heard word changes its shape freely
/// (case, punctuation, joins, numbers) but its sound only when the new word sounds the same *and*
/// is backed by context — a vocabulary or on-screen term ("Finnish dictation" → "Finish
/// dictation" with that label on screen) or a named entity that is not an ordinary word ("Queen"
/// → "Qwen"). The recogniser is often confidently wrong on real words; a spelling floor would
/// refuse "face" → "phase" (spelling 0.4) although both read FS.
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
    /// Ordinary English words (lowercase keys): a confident word may become a named entity only
    /// when the entity is not one of these. nil = no lexicon, so no confident entity change.
    let common: WordVocabulary?

    /// Read once per process (SCOWL when downloaded, else the system word list).
    static let installedCommon: WordVocabulary? = {
        let v = WordVocabulary.installed()
        return v.isEmpty ? nil : v
    }()

    /// Most heard words one explanation may consume.
    static let maxRun = 6

    init(phonetic: PhoneticEncoder?, vocabulary: [ContextPacket.VocabularyMatch], screenTerms: [String],
         common: WordVocabulary? = WriterGuardEvidence.installedCommon) {
        self.phonetic = phonetic
        self.common = common
        var terms: [Term] = []
        for v in vocabulary {
            let written = Self.keys(v.term)
            guard !written.isEmpty else { continue }
            let spoken = [v.spokenForm, v.heard, v.term].map(Self.keys).filter { !$0.isEmpty && $0.count <= Self.maxRun }
            terms.append(Term(written: written, spoken: Self.unique(spoken), fromVocabulary: true))
        }
        var seenWords = Set<String>()
        for s in screenTerms.prefix(40) {
            let written = Self.keys(s)
            guard !written.isEmpty, written.count <= Self.maxRun else { continue }
            terms.append(Term(written: written, spoken: [written], fromVocabulary: false))
            // A changed region holds only the changed words ("Finnish" → "Finish" of the label
            // "Finish dictation"), so each word of a multi-word term is evidence too (sound-gated).
            guard written.count > 1 else { continue }
            for w in written where w.count >= 3 && seenWords.insert(w).inserted {
                terms.append(Term(written: [w], spoken: [[w]], fromVocabulary: false))
            }
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
                // Uncertain words: any sound-alike; confident words: the same sound only (the term
                // itself is the context that backs the change).
                let uncertain = tokens.contains(where: \.isUncertain)
                let perWord = zip(run, spoken).allSatisfy { h, f in
                    h == f || Self.sameNumber(h, f)
                        || (uncertain ? soundsAlike(h, f, multiWord: spoken.count > 1) : soundsSame(h, f))
                        || tokens.contains { t in t.key == h && alternate(t, is: f) }
                }
                if perWord { return Match(heardCount: spoken.count, outputCount: term.written.count) }
            }
        }

        // 4b. A letters-and-digits token read part by part: "A sixtien z" → "a16z", "k eight s" → "k8s".
        if let m = alphanumeric(heard: heard, at: idx, from: s, heardKeys: heardKeys, written: output[j]) { return m }

        // 5. The recogniser's own alternates, or a sound-alike — uncertain words.
        if first.isUncertain {
            if alternate(first, is: outKeys[0]) { return Match(heardCount: 1, outputCount: 1) }
            if soundsAlike(heardKeys[0], outKeys[0], multiWord: false) { return Match(heardCount: 1, outputCount: 1) }
            return nil
        }
        // 6. A confident word that sounds the same as a named entity the model wrote ("Queen" → "Qwen").
        if confidentEntity(heardKeys[0], written: output[j], writtenKey: outKeys[0]) { return Match(heardCount: 1, outputCount: 1) }
        return nil
    }

    /// A confident word may become a named entity: written capitalised or with inner capitals /
    /// digits, not an ordinary English word, and sounding the same (Double Metaphone agreement).
    func confidentEntity(_ heardKey: String, written: String, writtenKey: String) -> Bool {
        guard let common, heardKey != writtenKey, !writtenKey.isEmpty else { return false }
        let core = written.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard let first = core.first else { return false }
        let entityShape = first.isUppercase || core.dropFirst().contains { $0.isUppercase || $0.isNumber }
        guard entityShape, !common.contains(writtenKey) else { return false }
        return soundsSame(heardKey, writtenKey)
    }

    /// "a16z", "k8s", "GPT4": letter runs match heard letters (whole run or one per word), digit
    /// runs match number words (or, on an uncertain word, a sound-alike of the number's word:
    /// "sixtien" → 16). At least one heard word in the run must be uncertain unless every part
    /// matched exactly.
    func alphanumeric(heard: [WriterGuard.HeardToken], at idx: [Int], from s: Int, heardKeys: [String], written: String) -> Match? {
        let key = WriterGuard.key(written)
        guard key.contains(where: \.isNumber), key.contains(where: \.isLetter), key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        var parts: [String] = []
        for c in key {
            if let last = parts.last, let l = last.last, l.isNumber == c.isNumber { parts[parts.count - 1].append(c) } else { parts.append(String(c)) }
        }
        var k = 0, exact = true
        for part in parts {
            guard k < heardKeys.count else { return nil }
            if part.first!.isLetter {
                if heardKeys[k] == part { k += 1; continue }
                let letters = part.map(String.init)
                if letters.count > 1, k + letters.count <= heardKeys.count, Array(heardKeys[k..<(k + letters.count)]) == letters {
                    k += letters.count; continue
                }
                return nil
            }
            var matched = false
            for n in stride(from: min(4, heardKeys.count - k), through: 1, by: -1) {
                let run = Array(heardKeys[k..<(k + n)])
                guard run.allSatisfy(WriterSpokenNumbers.isNumberWord) else { continue }
                if WriterSpokenNumbers.readings(run).contains(part) { k += n; matched = true; break }
            }
            if matched { continue }
            if heard[idx[s + k]].isUncertain, let word = Self.numberWord(part), soundsAlike(heardKeys[k], word, multiWord: false) {
                k += 1; exact = false; continue
            }
            return nil
        }
        guard k > 0 else { return nil }
        if !exact || (0..<k).contains(where: { heard[idx[s + $0]].isUncertain }) || k > 1 { return Match(heardCount: k, outputCount: 1) }
        return nil
    }

    /// The word for 0…99 ("16" → "sixteen", "42" → "forty two" as one key "fortytwo" is not used:
    /// only single-word numbers are offered).
    static func numberWord(_ digits: String) -> String? {
        guard let n = Int(digits) else { return nil }
        if let w = WriterSpokenNumbers.units.first(where: { $0.value == n && $0.key != "oh" })?.key { return w }
        return WriterSpokenNumbers.tens.first(where: { $0.value == n })?.key
    }

    /// "two" ⇄ "2".
    static func sameNumber(_ heard: String, _ written: String) -> Bool {
        written.allSatisfy(\.isNumber) && WriterSpokenNumbers.readings([heard]).contains(written)
    }

    /// The same sound (Double Metaphone codes agree), no spelling floor — for confident words,
    /// only ever used together with a context condition.
    func soundsSame(_ heard: String, _ written: String) -> Bool {
        guard let phonetic, !heard.isEmpty, !written.isEmpty else { return false }
        return ContextRepairStage.phoneticMatch(heard, written, phonetic) == .strong
    }

    func alternate(_ token: WriterGuard.HeardToken, is key: String) -> Bool {
        token.alternates.contains { WriterGuard.key($0) == key }
    }

    /// Sound-alike gate for an uncertain word: Double Metaphone agreement with a sane length (the
    /// model chose the word with the packet in hand; acoustics, not spelling, are the constraint:
    /// "face" → "phase" reads FS = FS at spelling 0.4). A near code needs a spelling floor. Without
    /// an encoder only a near-identical spelling passes.
    func soundsAlike(_ heard: String, _ written: String, multiWord: Bool) -> Bool {
        guard !heard.isEmpty, !written.isEmpty else { return false }
        let spell = ContextRepairStage.spelling(heard, written)
        guard let phonetic else { return heard.count >= 4 && spell >= 0.75 }
        switch ContextRepairStage.phoneticMatch(heard, written, phonetic) {
        case .strong: return max(heard.count, written.count) <= 2 * min(heard.count, written.count) + 2
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
