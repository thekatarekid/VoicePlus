import Foundation
import Shared
import Testing
@testable import Engine

private func surface(_ kind: SurfaceKind) -> SurfaceResolution {
    SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: [])
}

/// Context Writer §1 "what the booster becomes" — the CTC boost list is scoped down to Dictionary
/// terms with a spoken form and confirmed corrections: never Contacts, never screen terms, cap 100.
@Suite("Context Writer — booster scope")
struct BoostScopeTests {
    static let contacts = ["Akash", "DOCUBE", "Bucket", "Cab", "Cleaning", "Code"]

    @Test func legacyBuildKeepsOnlyVoiceableDictionaryTermsAndCorrectionEntities() {
        let ranked = ContextRanker().rank([
            ContextEntry(text: "Zephyr", source: .axTree),          // screen — never
            ContextEntry(text: "Grafana", source: .recentWords),    // recent — never
            ContextEntry(text: "Bandra", source: .dictionary),      // authored, but no spoken form
            ContextEntry(text: "gpt-4o", source: .dictionary),      // authored, verbalized
            ContextEntry(text: "tomorrow", source: .corrections),   // plain word — dropped
            ContextEntry(text: "Priya", source: .corrections),      // confirmed correction entity
            ContextEntry(text: "Bucket", source: .contacts),        // Contacts — never
        ])
        let list = BoostVocabulary.build(dictionary: ["Kothari", "a16z", "TeamViewer AG", "ok", "Code"],
                                         corrections: ["send it to Sundar tomorrow"], context: ranked)
        #expect(Array(list.prefix(3)) == ["a16z", "TeamViewer AG", "Sundar"])
        #expect(Set(list.dropFirst(3)) == ["gpt-4o", "Priya"])
    }

    @Test func typedSpokenFormsAdmitPlainNamesButNeverContacts() {
        let entries = [
            DictionaryEntry(term: "Qwen", spokenForms: ["queen"]),
            DictionaryEntry(term: "Kothari"),
            DictionaryEntry(term: "Code", origin: .contacts, spokenForms: ["code"]),
            DictionaryEntry(term: "Akash Kothari", origin: .contacts),
            DictionaryEntry(term: "k8s", origin: .imported),
            DictionaryEntry(term: "Muesli", origin: .earlier),
        ]
        #expect(BoostVocabulary.build(entries: entries, corrections: []) == ["Qwen", "k8s"])
        #expect(BoostVocabulary.typedForms(entries) == ["qwen": ["queen"]])
    }

    @Test func rubricBuildIgnoresEveryScreenContactAndSurfaceAdmission() {
        var config = ContextRubric.Config()
        config.screenTermsInBoost = true
        config.nearCaretInBoost = true
        let dictionary = ContextCandidates.dictionary([
            DictionaryEntry(term: "a16z"), DictionaryEntry(term: "Kothari"), DictionaryEntry(term: "Qwen", spokenForms: ["queen"]),
        ] + Self.contacts.map { DictionaryEntry(term: $0, origin: .contacts) })
        let candidates = dictionary
            + [ContextCandidate(text: "Priya", source: .correction),
               ContextCandidate(text: "Zephyr", source: .screenNear, caretDistance: 10, onScreenNow: true),
               ContextCandidate(text: "Grafana", source: .screenWindow, onScreenNow: true)]
            + ContextCandidates.lexicon(["kubectl", "Helmfile"], type: .command, surface: .terminal)
            + ContextCandidates.participants(["Sundar Pichai"])
            + ContextCandidates.recentDictations([(text: "ask Zyloqx", at: Date())], app: "com.a")
        for kind in [SurfaceKind.chatComposer, .emailBody, .terminal, .prose] {
            let ranked = ContextRubric(config: config).ranked(candidates: candidates, surface: surface(kind))
            let admitted = ranked.boostTerms
            let list = BoostVocabulary.build(rubric: ranked, spokenForms: ["qwen": ["queen"]])
            #expect(Set(list).isSubset(of: ["a16z", "Priya", "Qwen"]), "\(kind.id): \(list)")
            #expect(list.contains("Priya") && list.contains("a16z"), "\(kind.id)")
            #expect(!list.contains("Kothari"), "\(kind.id): no spoken form")
            #expect(Set(list).isSubset(of: Set(admitted)), "\(kind.id): the rubric's admission still applies")
            #expect(!BoostVocabulary.build(rubric: ranked).contains("Qwen"), "\(kind.id): typed forms must be passed")
            for word in Self.contacts { #expect(!list.contains(word), "\(kind.id): Contact \(word)") }
        }
        #expect(BoostVocabulary.build(rubric: ContextRubric(config: config).ranked(candidates: candidates, surface: surface(.secure))).isEmpty)
    }

    @Test func aContactNeverBoostsWhateverItsForm() {
        let code = DictionaryEntry(term: "Code", origin: .contacts, spokenForms: ["code"])
        #expect(BoostVocabulary.build(entries: [code], corrections: []).isEmpty)
        let ranked = ContextRubric.rank(candidates: ContextCandidates.dictionary([code]), surface: surface(.chatComposer))
        #expect(BoostVocabulary.build(rubric: ranked, spokenForms: ["code": ["code"]]).isEmpty)
        let term = RubricTerm(text: "Code", type: .person, source: .contact, sources: [.contact], score: 1,
                              isCollision: true, hasStrongEvidence: true)
        #expect(!BoostVocabulary.admits(term, typed: ["code"]))
        // A term the user corrected *to* is a correction, whatever else it is.
        var corrected = term; corrected.sources.insert(.correction)
        #expect(BoostVocabulary.admits(corrected))
        // …when it is entity-like: a plain word once corrected to is not vocabulary.
        let plain = RubricTerm(text: "tomorrow", type: .word, source: .correction, sources: [.correction], score: 1,
                               isCollision: true, hasStrongEvidence: true)
        #expect(!BoostVocabulary.admits(plain))
    }

    @Test func capIsOneHundred() {
        let many = (0..<1_000).map { "Term\($0)" }   // "term zero" … every one has a spoken form
        let list = BoostVocabulary.build(dictionary: many, corrections: [])
        #expect(list.count == 100 && BoostVocabulary.cap == 100)
        #expect(list.first == "Term0")
    }

    @Test func controllerPrefersEntriesAndPassesTypedFormsToTheRubric() {
        let entries = [DictionaryEntry(term: "Qwen", spokenForms: ["queen"]), DictionaryEntry(term: "Kothari"),
                       DictionaryEntry(term: "Code", origin: .contacts)]
        let legacy = BoostingController(dictionary: { ["Kothari", "a16z"] }, entries: { entries },
                                        makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(legacy.makeBoosterForUtterance()?.terms == ["Qwen"], "entries replace the strings")
        let ranked = ContextRubric.rank(candidates: ContextCandidates.dictionary(entries), surface: surface(.chatComposer))
        let rubric = BoostingController(entries: { entries }, rubric: { _ in ranked }, makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(rubric.makeBoosterForUtterance()?.terms == ["Qwen"])
        let none = BoostingController(dictionary: { ["Kothari"] }, makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(none.makeBoosterForUtterance() == nil, "a plain name alone installs no booster")
    }
}
