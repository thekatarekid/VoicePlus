import Foundation
import Shared
import Testing
@testable import Engine

private func heard(_ text: String, uncertain: Set<String>) -> ContextPacket.Heard {
    let words = text.split(separator: " ").map { w -> ContextPacket.HeardWord in
        let key = VocabularyMatcher.clean(String(w))
        return ContextPacket.HeardWord(text: String(w), confidence: uncertain.contains(key) ? 0.2 : 0.95)
    }
    return ContextPacket.Heard(raw: text, words: words)
}

private func entry(_ term: String, _ forms: [String] = [], origin: DictionaryEntryOrigin = .personal,
                   weight: Double = 1) -> DictionaryEntry {
    DictionaryEntry(term: term, weight: weight, origin: origin, spokenForms: forms)
}

/// Context Writer §2.4 — phonetic matching of the user's vocabulary against uncertain heard words.
@Suite("Context Writer — VocabularyMatcher")
struct VocabularyMatcherTests {
    static let entries = [
        entry("a16z"), entry("Kothari"), entry("Qwen", ["queen"]), entry("k8s"), entry("TeamViewer"),
        entry("Cab"), entry("Code", origin: .contacts), entry("Cab", origin: .contacts),
        entry("Akash Kothari", origin: .contacts), entry("Bucket", origin: .contacts),
    ]
    static let matcher = VocabularyMatcher(terms: VocabularyTerm.dictionary(entries))

    @Test func misheardAlphanumericMatchesThroughItsVerbalizedForm() {
        let m = Self.matcher.matches(heard: heard("we raised from a sixtien z last year", uncertain: ["sixtien", "z"]), limit: 10)
        let hit = m.first { $0.term == "a16z" }
        #expect(hit != nil)
        #expect(hit?.spokenForm == "a sixteen z")
        #expect(hit?.heard == "a sixtien z")
        #expect(hit?.source == "dictionary")
        #expect((hit?.score ?? 0) > 0.7)
    }

    @Test func correctlyHeardSpokenFormStillMatchesWhenUncertain() {
        let m = Self.matcher.matches(heard: heard("backed by a sixteen z", uncertain: ["sixteen", "z"]), limit: 10)
        #expect(m.first?.term == "a16z")
        #expect((m.first?.score ?? 0) > 0.99, "metaphone equality and exact spelling")
        let k = Self.matcher.matches(heard: heard("deploy it on k eight s", uncertain: ["eight"]), limit: 10)
        #expect(k.first?.term == "k8s")
    }

    @Test func typedSpokenFormBeatsTheCommonWordRule() {
        // "queen" is an ordinary English word: it matches Qwen only because the user typed it.
        let m = Self.matcher.matches(heard: heard("run queen four B on it", uncertain: ["queen"]), limit: 10)
        #expect(m.map(\.term) == ["Qwen"])
        #expect(m.first?.spokenForm == "queen")
        // Nothing uncertain → nothing matched, however many terms sound alike.
        #expect(Self.matcher.matches(heard: heard("run queen four B on it", uncertain: []), limit: 10).isEmpty)
    }

    @Test func singleWordContactsNeverEnterTheIndex() {
        let terms = VocabularyTerm.dictionary(Self.entries)
        #expect(!terms.contains { $0.source == .contact && $0.term == "Code" })
        #expect(!terms.contains { $0.source == .contact && $0.term == "Bucket" })
        #expect(terms.contains { $0.source == .contact && $0.term == "Akash Kothari" })
        #expect(Self.matcher.matches(heard: heard("the code is wrong", uncertain: ["code"]), limit: 10).isEmpty)
        #expect(Self.matcher.matches(heard: heard("my bucket list", uncertain: ["bucket"]), limit: 10).isEmpty)
    }

    @Test func fullNameContactMatchesAsAWindow() {
        let m = Self.matcher.matches(heard: heard("ping akash kotari about it", uncertain: ["kotari"]), limit: 10)
        let hit = m.first { $0.term == "Akash Kothari" }
        #expect(hit?.source == "contact")
        #expect(hit?.heard == "akash kotari")
        // The plain Dictionary name matches the single uncertain word too.
        #expect(m.contains { $0.term == "Kothari" && $0.heard == "kotari" })
    }

    @Test func commonWordCollisionIsRejectedWithoutATypedForm() {
        // "Cab" is both a personal Dictionary row and a Contact: neither may claim the ordinary word.
        #expect(Self.matcher.matches(heard: heard("take a cab there", uncertain: ["cab"]), limit: 10).isEmpty)
        // Once the user types the spoken form, the Dictionary row (never the Contact) matches.
        let typed = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("Cab", ["cab"]), entry("Cab", origin: .contacts)]))
        let m = typed.matches(heard: heard("take a cab there", uncertain: ["cab"]), limit: 10)
        #expect(m.map(\.source) == ["dictionary"])
    }

    @Test func dedupesByTermAndHonoursTheLimit() {
        let m = Self.matcher.matches(heard: heard("kotari kothari cotari", uncertain: ["kotari", "kothari", "cotari"]), limit: 10)
        #expect(m.filter { $0.term == "Kothari" }.count == 1)
        #expect(m.first { $0.term == "Kothari" }?.heard == "kothari", "the exact spelling scores highest")
        let one = Self.matcher.matches(heard: heard("a sixtien z and k eight s", uncertain: ["sixtien", "z", "eight"]), limit: 1)
        #expect(one.count == 1)
        #expect(m.map(\.score) == m.map(\.score).sorted(by: >))
    }

    @Test func recencyWeightAndSourceOrderTheScore() {
        let now = Date()
        let old = VocabularyTerm(term: "Kothari", source: .dictionary, lastUsed: now.addingTimeInterval(-400 * 24 * 3600))
        let fresh = VocabularyTerm(term: "Kothary", source: .dictionary, lastUsed: now)
        let light = VocabularyTerm(term: "Kotharie", source: .dictionary, weight: 0.2)
        let learned = VocabularyTerm(term: "Kothari", source: .learned)
        let h = heard("ask kotari", uncertain: ["kotari"])
        let a = VocabularyMatcher(terms: [old, fresh]).matches(heard: h, limit: 5, now: now)
        #expect(a.map(\.term) == ["Kothary", "Kothari"], "recent use outranks an old one at equal closeness")
        let b = VocabularyMatcher(terms: [VocabularyTerm(term: "Kothari", source: .dictionary), light]).matches(heard: h, limit: 5, now: now)
        #expect(b.first?.term == "Kothari")
        let c = VocabularyMatcher(terms: [learned]).matches(heard: h, limit: 5, now: now)
        #expect(c.first?.source == "learned")
        #expect((c.first?.score ?? 0) < (b.first?.score ?? 0), "learned source weight < dictionary")
    }

    @Test func correctionAndLearnedSourcesAreIndexed() {
        let corrections = VocabularyTerm.corrections([(term: "send it to Sundar tomorrow", at: Date())])
        #expect(corrections.map(\.term) == ["Sundar"])
        var lexicon = PersonalLexicon()
        lexicon.terms["spool"] = PersonalLexicon.Term(text: "Spool", weight: 0.8, corrections: 3, lastSeen: Date())
        let learned = VocabularyTerm.learned(lexicon)
        #expect(learned.map(\.term) == ["Spool"] && learned.first?.source == .learned)
        let m = VocabularyMatcher(terms: corrections + learned)
            .matches(heard: heard("tell sundhar the spull is ready", uncertain: ["sundhar", "spull"]), limit: 10)
        #expect(Set(m.map(\.term)) == ["Sundar", "Spool"])
    }

    @Test func farOffSoundsAndTooLongWindowsDoNotMatch() {
        let m = Self.matcher.matches(heard: heard("the weather is lovely", uncertain: ["weather", "lovely"]), limit: 10)
        #expect(m.isEmpty)
        #expect(VocabularyMatcher(terms: []).matches(heard: heard("x", uncertain: ["x"]), limit: 10).isEmpty, "empty index")
        let p: any VocabularyMatching = Self.matcher
        #expect(p.matches(heard: heard("hello", uncertain: ["hello"]), limit: 0).isEmpty)
    }

    // MARK: learned lexicon (C1): aliases are trusted forms, negative aliases block the pair

    @Test func learnedAliasesAreTrustedSpokenForms() {
        var lexicon = PersonalLexicon()
        lexicon.terms["subagents"] = PersonalLexicon.Term(text: "subagents", weight: 0.6, corrections: 1, lastSeen: Date())
        lexicon.variants["sub variance"] = PersonalLexicon.Variant(heard: "sub variance", corrected: "subagents", count: 1)
        lexicon.variants["queen"] = PersonalLexicon.Variant(heard: "queen", corrected: "Qwen", count: 2)   // no term row
        let terms = VocabularyTerm.learned(lexicon)
        #expect(terms.first { $0.term == "subagents" }?.spokenForms == ["sub variance"])
        #expect(terms.first { $0.term == "Qwen" }?.spokenForms == ["queen"], "a variant without a term row still counts")
        let matcher = VocabularyMatcher(terms: terms)
        let m = matcher.matches(heard: heard("fan out sub variance now", uncertain: ["variance"]), limit: 5)
        #expect(m.first?.term == "subagents" && m.first?.spokenForm == "sub variance" && m.first?.heard == "sub variance")
        #expect(m.first?.source == "learned")
        // "queen" is an ordinary word; the learned alias is trusted like a typed form.
        #expect(matcher.matches(heard: heard("run queen locally", uncertain: ["queen"]), limit: 5).map(\.term) == ["Qwen"])
    }

    @Test func negativeAliasSuppressesExactlyThatPair() {
        var lexicon = PersonalLexicon()
        lexicon.terms["kothari"] = PersonalLexicon.Term(text: "Kothari", weight: 1, corrections: 3, lastSeen: Date())
        lexicon.variants["kotary"] = PersonalLexicon.Variant(heard: "kotary", corrected: "Kothari", count: 1)
        lexicon.negatives["kotari"] = ["kothari"]
        lexicon.negatives["kotary"] = ["kothari"]
        // The blocked variant is not a spoken form…
        #expect(VocabularyTerm.learned(lexicon).first?.spokenForms == [])
        // …and the pair is refused whatever source offers the term (here the Dictionary too).
        let matcher = VocabularyMatcher.build(entries: [entry("Kothari")], learned: lexicon)
        #expect(matcher.matches(heard: heard("ask kotari now", uncertain: ["kotari"]), limit: 5).isEmpty)
        #expect(matcher.matches(heard: heard("ask Kotari, now", uncertain: ["kotari"]), limit: 5).isEmpty, "case and punctuation")
        #expect(matcher.matches(heard: heard("ask kotary now", uncertain: ["kotary"]), limit: 5).isEmpty)
        // Another heard form of the same term is still offered.
        let other = matcher.matches(heard: heard("ask kothary now", uncertain: ["kothary"]), limit: 5)
        #expect(other.first?.term == "Kothari" && other.first?.heard == "kothary")
        #expect(BlockedVocabularyPairs(lexicon).contains(heard: " Kotari ", written: "KOTHARI"))
    }

    // MARK: heard shapes

    @Test func heardDigitsAreReadAsWords() {
        let matcher = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("GPT-4o"), entry("a16z")]))
        let gpt = matcher.matches(heard: heard("switch to gpt 4o today", uncertain: ["gpt", "4o"]), limit: 5)
        #expect(gpt.first?.term == "GPT-4o" && gpt.first?.heard == "gpt 4o" && gpt.first?.spokenForm == "gpt four o")
        #expect((gpt.first?.score ?? 0) > 0.99)
        let right = matcher.matches(heard: heard("backed by a16z.", uncertain: ["a16z"]), limit: 5)
        #expect(right.first?.term == "a16z" && right.first?.heard == "a16z", "a correct but uncertain token is confirmed")
    }

    @Test func splitHeardWordsMatchASingleWordTerm() {
        let matcher = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("Paperclip"), entry("Kubernetes")]))
        let m = matcher.matches(heard: heard("the paper clip repo", uncertain: ["clip"]), limit: 5)
        #expect(m.first?.term == "Paperclip" && m.first?.heard == "paper clip")
        let k = matcher.matches(heard: heard("deploy to kuber netes", uncertain: ["kuber", "netes"]), limit: 5)
        #expect(k.first?.term == "Kubernetes" && k.first?.heard == "kuber netes")
    }

    /// Every heard word in a window must be explained by the form: dropping an edge word that the
    /// form does not account for must not leave an equal or better match.
    @Test func windowsAreTight() {
        let matcher = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("Kothari")]))
        let m = matcher.matches(heard: heard("send to kotari", uncertain: ["to", "kotari"]), limit: 5)
        #expect(m.map(\.heard) == ["kotari"])
        // "a" is the uncertain word, "cab" is certain: Cab explains "cab", not "a" — nothing to offer.
        let typed = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("Cab", ["cab"])]))
        #expect(typed.matches(heard: heard("take a cab there", uncertain: ["a"]), limit: 5).isEmpty)
    }

    /// Short ordinary words share codes with everything: a window of them must also spell the term.
    @Test func ordinaryWordWindowsMustSpellTheTerm() {
        let matcher = VocabularyMatcher(terms: VocabularyTerm.dictionary([entry("ANE"), entry("Supabase"), entry("Paperclip")]))
        #expect(matcher.matches(heard: heard("check the logs on a box", uncertain: ["on", "a"]), limit: 5).isEmpty,
                "\"on a\" sounds like \"a n e\" but spells nothing like it")
        #expect(matcher.matches(heard: heard("the core runs on the a n e", uncertain: ["n", "e"]), limit: 5).first?.term == "ANE")
        #expect(matcher.matches(heard: heard("use super base for auth", uncertain: ["super", "base"]), limit: 5).first?.term == "Supabase")
        #expect(matcher.matches(heard: heard("the paper clip repo", uncertain: ["paper", "clip"]), limit: 5).first?.term == "Paperclip")
    }

    @Test func factoryCombinesEverySourceAndIsDeterministic() {
        var lexicon = PersonalLexicon()
        lexicon.terms["spool"] = PersonalLexicon.Term(text: "Spool", weight: 0.8, corrections: 3, lastSeen: Date())
        let matcher = VocabularyMatcher.build(
            entries: Self.entries, corrections: [(term: "send it to Sundar tomorrow", at: Date())], learned: lexicon)
        let h = heard("tell sundhar the spull for akash kotari is in a sixtien z", uncertain: ["sundhar", "spull", "kotari", "sixtien"])
        let now = Date()
        let m = matcher.matches(heard: h, limit: 10, now: now)
        let sources = Dictionary(m.map { ($0.term, $0.source) }, uniquingKeysWith: { a, _ in a })
        #expect(sources["Sundar"] == "correction" && sources["Spool"] == "learned")
        #expect(sources["Akash Kothari"] == "contact" && sources["a16z"] == "dictionary")
        #expect(sources["Code"] == nil && sources["Bucket"] == nil)
        #expect(matcher.matches(heard: h, limit: 10, now: now) == m, "same input, same output")
        #expect(matcher.matches(heard: h, limit: 2, now: now) == Array(m.prefix(2)), "the limit cuts the same ranking")
        #expect(m.map(\.score) == m.map(\.score).sorted(by: >))
    }

    // MARK: performance (runs at key-up on the dictation path)

    static func syntheticVocabulary() -> [DictionaryEntry] {
        let syllables = ["ka", "to", "ri", "mi", "sha", "lo", "ven", "dra", "pa", "ne", "su", "bo", "kel", "vi", "ro", "tan"]
        var entries: [DictionaryEntry] = []
        for i in 0..<5_000 {
            let a = syllables[i % 16], b = syllables[(i / 16) % 16], c = syllables[(i / 256) % 16]
            let suffix: String = i % 3 == 0 ? String(i % 97) : ""
            let name: String = (a + b + c).capitalized + suffix
            let typed: [String] = i % 7 == 0 ? [a + " " + b + " " + c] : []
            entries.append(entry(name, typed))
        }
        return entries
    }

    static func syntheticWords() -> [String] {
        let syllables = ["ka", "to", "ri", "mi", "sha", "lo", "ven", "dra", "pa", "ne", "su", "bo", "kel", "vi", "ro", "tan"]
        var words: [String] = []
        for i in 0..<30 {
            let tail: String = i % 4 == 0 ? "ri" : ""
            words.append(syllables[i % 16] + syllables[(i * 7) % 16] + tail)
        }
        return words
    }

    /// CPU time of this thread per run: the matcher's own cost, not the scheduler's — the suite runs
    /// next to parallel builds, where wall time measures the machine's load.
    static func milliseconds(runs: Int, _ body: () -> Void) -> Double {
        let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<runs { body() }
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6 / Double(runs)
    }

    /// 5k terms × 30 heard words, every word uncertain (the worst case: 114 windows), in a few ms.
    /// The vocabulary is adversarial: 16 syllables, so thousands of names sound alike.
    @Test func fiveThousandTermsAndThirtyWordsRunInMilliseconds() {
        let index = PhoneticVocabularyIndex(terms: VocabularyTerm.dictionary(Self.syntheticVocabulary()))
        #expect(index.terms.count == 5_000 && index.formCount >= 5_000)
        let matcher = VocabularyMatcher(index: index)
        let words = Self.syntheticWords()
        let h = heard(words.joined(separator: " "), uncertain: Set(words))
        _ = matcher.matches(heard: h, limit: 30)   // warm
        let ms = Self.milliseconds(runs: 5) { _ = matcher.matches(heard: h, limit: 30) }
        print("VocabularyMatcher perf: \(index.formCount) forms, \(index.distinctCodeCount) codes, "
              + "\(index.tableKeyCount) postings; worst case (30 words, all uncertain) \(String(format: "%.2f", ms)) ms CPU")
        #expect(ms < 25, "matches() took \(ms) ms (target < 5 ms, CI bound 25 ms)")
        #expect(!matcher.matches(heard: h, limit: 30).isEmpty)
    }

    /// The typical dictation: 30 words, three of them uncertain, against the same 5k terms.
    @Test func typicalDictationIsWellUnderFiveMilliseconds() {
        let matcher = VocabularyMatcher(index: PhoneticVocabularyIndex(terms: VocabularyTerm.dictionary(Self.syntheticVocabulary())))
        let words = Self.syntheticWords()
        let h = heard(words.joined(separator: " "), uncertain: [words[3], words[14], words[25]])
        _ = matcher.matches(heard: h, limit: 30)
        let ms = Self.milliseconds(runs: 20) { _ = matcher.matches(heard: h, limit: 30) }
        print("VocabularyMatcher perf: typical (30 words, 3 uncertain) \(String(format: "%.2f", ms)) ms CPU")
        #expect(ms < 5, "typical matches() took \(ms) ms")
    }

    /// The index is rebuilt off the dictation path when the vocabulary changes; it must stay cheap.
    @Test func indexBuildForFiveThousandTermsIsBounded() {
        let terms = VocabularyTerm.dictionary(Self.syntheticVocabulary())
        _ = PhoneticVocabularyIndex(terms: Array(terms.prefix(50)))   // warm the word list and tables
        var index: PhoneticVocabularyIndex?
        let ms = Self.milliseconds(runs: 1) { index = PhoneticVocabularyIndex(terms: terms) }
        print("VocabularyMatcher perf: 5k-term index build \(String(format: "%.0f", ms)) ms CPU")
        #expect(index?.formCount ?? 0 >= 5_000)
        #expect(ms < 3_000, "5k-term index build took \(ms) ms")
    }
}
