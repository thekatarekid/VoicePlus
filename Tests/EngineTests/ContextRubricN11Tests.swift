import Foundation
import Shared
import Testing
@testable import Engine

private func surface(_ kind: SurfaceKind, _ confidence: Double = 0.9) -> SurfaceResolution {
    SurfaceResolution(kind: kind, confidence: confidence, isWebArea: false, signals: [])
}

private func contacts(_ names: [String]) -> [ContextCandidate] {
    ContextCandidates.dictionary(names.map { DictionaryEntry(term: $0, origin: .contacts) })
}

private func all(_ r: RankedContext) -> [String] {
    r.boostTerms + r.spellList + r.promptTerms
}

/// N11 — the context rubric: typed candidates, one score, quotas, collision rule, two boost layers.
@Suite("Context rubric (N11)")
struct ContextRubricN11Tests {
    static let damage = ["Akash", "DOCUBE", "Bucket", "Cab", "Cleaning", "Code"]

    @Test func contactsNeverReachAnyChannelOffConversationalSurfaces() {
        for kind in [SurfaceKind.terminal, .prose, .codeEditor, .spreadsheetCell, .urlBar, .markdownEditor] {
            let r = ContextRubric.rank(candidates: contacts(Self.damage), surface: surface(kind))
            #expect(all(r).isEmpty, "\(kind.id)")
            #expect(r.terms.isEmpty)
        }
    }

    @Test func contactsReturnOnChatEmailAndNameFieldsButCommonWordsStillNeedEvidence() {
        for kind in [SurfaceKind.chatComposer, .emailBody, .formField(label: "name")] {
            let r = ContextRubric.rank(candidates: contacts(Self.damage), surface: surface(kind))
            #expect(r.boostTerms.contains("Akash") && r.boostTerms.contains("DOCUBE"), "\(kind.id)")
            for w in ["Bucket", "Cab", "Cleaning", "Code"] {
                #expect(!r.boostTerms.contains(w), "collision word \(w) without evidence")
                #expect(!r.spellList.contains(w))
            }
            let akash = r.perTurnLayer.first { $0.text == "Akash" }
            #expect(akash?.source == .contact)
            #expect(abs((akash?.score ?? 0) - 0.6) < 1e-9, "Contacts weigh 0.6 on these surfaces")
        }
    }

    @Test func aCollisionWordOnScreenNowIsAdmitted() {
        var c = ContextRubric.Config()
        c.screenTermsInBoost = true
        let cands = contacts(["Bucket"]) + ContextCandidates.screen(text: "Ask Bucket about it", caretOffset: 0)
        let r = ContextRubric(config: c).ranked(candidates: cands, surface: surface(.chatComposer))
        #expect(r.boostTerms.contains("Bucket"))
        let dict = ContextCandidates.dictionary([DictionaryEntry(term: "Code")])
        #expect(!ContextRubric.rank(candidates: dict, surface: surface(.prose)).boostTerms.contains("Code"))
        let both = dict + ContextCandidates.screen(text: "Code review", caretOffset: 0)
        #expect(ContextRubric.rank(candidates: both, surface: surface(.prose)).boostTerms.contains("Code"))
    }

    @Test func correctionsSurviveAFullBudget() {
        let dict = (0..<500).map { DictionaryEntry(term: "Dictterm\($0)x", weight: 1) }
        let lex = ContextCandidates.lexicon((0..<500).map { "lexcmd\($0)" }, type: .command, surface: .terminal)
        let old = Date(timeIntervalSinceNow: -86_400 * 30)
        let corr = (0..<50).map { ContextCandidate(text: "Corrterm\($0)z", source: .correction, observedAt: old, evidence: 0.05) }
        let r = ContextRubric.rank(candidates: ContextCandidates.dictionary(dict) + lex + corr, surface: surface(.terminal))
        let stable = Set(r.stableLayer.map(\.text))
        #expect(r.stableLayer.count == 200)
        #expect(corr.filter { stable.contains($0.text) }.count == 50, "every correction (up to the guaranteed share) kept despite a low score")
    }

    @Test func noSingleSourceTakesMoreThanHalfWhenOthersCompete() {
        let dict = ContextCandidates.dictionary((0..<400).map { DictionaryEntry(term: "Dictterm\($0)x") })
        let lex = ContextCandidates.lexicon((0..<400).map { "lexcmd\($0)" }, type: .command, surface: .terminal)
        let r = ContextRubric.rank(candidates: dict + lex, surface: surface(.terminal))
        let counts = Dictionary(grouping: r.stableLayer, by: \.source).mapValues(\.count)
        #expect(r.stableLayer.count == 200)
        #expect((counts[.dictionary] ?? 0) <= 100 && (counts[.surfaceLexicon] ?? 0) <= 100)
        // Alone, a source may fill the budget (the quota protects others' room, never wastes it).
        #expect(ContextRubric.rank(candidates: dict, surface: surface(.prose)).stableLayer.count == 200)
    }

    @Test func surfaceLexiconOnlyOnItsSurface() {
        let fns = ContextCandidates.lexicon(["XLOOKUP", "SUMIFS"], type: .formulaFunction, surface: .spreadsheetCell)
        #expect(ContextRubric.rank(candidates: fns, surface: surface(.spreadsheetCell)).stableLayer.count == 2)
        #expect(ContextRubric.rank(candidates: fns, surface: surface(.prose)).boostTerms.isEmpty)
        // Scaled by the surface's confidence.
        let hi = ContextRubric.rank(candidates: fns, surface: surface(.spreadsheetCell, 0.9)).stableLayer[0].score
        let lo = ContextRubric.rank(candidates: fns, surface: surface(.spreadsheetCell, 0.45)).stableLayer[0].score
        #expect(lo < hi)
    }

    @Test func shellContextFeedsBothLayersOnTerminalsOnly() {
        let shell = ShellContext(currentDirectory: "/Users/x", entries: [.init(name: "VoiceInput", isDirectory: true),
                                                                          .init(name: ".git", isDirectory: true)],
                                 knownCommands: ["kubectl"])
        let cands = ContextCandidates.shell(shell)
        let r = ContextRubric.rank(candidates: cands, surface: surface(.terminal))
        #expect(r.stableLayer.contains { $0.text == "kubectl" && $0.type == .command })
        #expect(r.perTurnLayer.contains { $0.text == "VoiceInput" && $0.type == .path }, "folder entries are per-turn")
        #expect(!r.boostTerms.contains(".git"))
        #expect(ContextRubric.rank(candidates: cands, surface: surface(.prose)).boostTerms.isEmpty)
    }

    @Test func secureSurfaceGetsNothing() {
        let cands = ContextCandidates.dictionary([DictionaryEntry(term: "Kothari")])
            + [ContextCandidate(text: "Postgres", source: .correction)]
        let r = ContextRubric.rank(candidates: cands, surface: surface(.secure))
        #expect(r == .empty)
    }

    @Test func screenTermsStayOutOfBoostUntilMeasuredButReachThePrompt() {
        // H17: window terms (no caret) stay gated; near-caret terms are admitted without the gate.
        let cands = ContextCandidates.screen(text: "Meeting with Priyanka about TeamViewer")
        let r = ContextRubric.rank(candidates: cands, surface: surface(.prose))
        #expect(r.boostTerms.isEmpty, "F27 off by default")
        let near = ContextCandidates.screen(text: "Meeting with Priyanka about TeamViewer", caretOffset: 10)
        #expect(ContextRubric.rank(candidates: near, surface: surface(.prose)).perTurnLayer.contains { $0.text == "TeamViewer" })
        #expect(r.promptTerms.contains("Priyanka") && r.promptTerms.contains("TeamViewer"))
        #expect(!r.spellList.contains("Priyanka"), "screen-only terms are not spell-exactly terms")
        var c = ContextRubric.Config(); c.screenTermsInBoost = true
        #expect(ContextRubric(config: c).ranked(candidates: cands, surface: surface(.prose)).perTurnLayer.contains { $0.text == "TeamViewer" })
    }

    @Test func nearTermsOutrankFarOnesAndFreshOutrankStale() {
        let text = "Zephyrine " + String(repeating: "x ", count: 1_500) + "Quillon"
        let cands = ContextCandidates.screen(text: text, caretOffset: text.count)
        #expect(cands.first { $0.text == "Quillon" }?.source == .screenNear)
        #expect(cands.first { $0.text == "Zephyrine" }?.source == .screenWindow)
        let r = ContextRubric.rank(candidates: cands, surface: surface(.prose))
        #expect(r.promptTerms.firstIndex(of: "Quillon")! < r.promptTerms.firstIndex(of: "Zephyrine")!)

        let now = Date()
        let fresh = ContextCandidate(text: "Freshterm", source: .recentDictation, observedAt: now)
        let stale = ContextCandidate(text: "Staleterm", source: .recentDictation, observedAt: now.addingTimeInterval(-3_600))
        let rubric = ContextRubric()
        #expect(rubric.score(fresh, surface: surface(.prose), now: now)!.score > rubric.score(stale, surface: surface(.prose), now: now)!.score)
    }

    @Test func spellListIsChosenByScoreNotDictionaryFirst() {
        let corr = [ContextCandidate(text: "Kothari", source: .correction)]
        let dict = ContextCandidates.dictionary([DictionaryEntry(term: "Zyloqx")], neverUsed: ["zyloqx"])
        let r = ContextRubric.rank(candidates: dict + corr, surface: surface(.prose))
        #expect(r.spellList == ["Kothari", "Zyloqx"])
        #expect(abs(r.stableLayer.first { $0.text == "Zyloqx" }!.score - 0.6) < 1e-9, "never-used dictionary weighs 0.6")
    }

    @Test func participantsOnlyInChatAndEmail() {
        let p = ContextCandidates.participants(["Anand Rao"])
        #expect(ContextRubric.rank(candidates: p, surface: surface(.chatComposer)).perTurnLayer.count == 1)
        #expect(ContextRubric.rank(candidates: p, surface: surface(.terminal)).boostTerms.isEmpty)
    }

    @Test func recentDictationsOnlyFromThisApp() {
        let c = ContextCandidates.recentDictations([(text: "ask Moravec", at: Date())], app: "com.a")
        #expect(ContextRubric.rank(candidates: c, surface: surface(.prose), app: "com.a").perTurnLayer.count == 1)
        #expect(ContextRubric.rank(candidates: c, surface: surface(.prose), app: "com.b").boostTerms.isEmpty)
    }

    @Test func learnedWeightsMoveScoresWithinBounds() {
        let c = [ContextCandidate(text: "Kothari", source: .dictionary)]
        let w = RubricWeights(surfaceMultipliers: ["prose": ["dictionary": 9]])
        let s = ContextRubric(weights: w).ranked(candidates: c, surface: surface(.prose)).stableLayer[0].score
        #expect(abs(s - 0.9 * RubricWeights.bounds.upperBound) < 1e-9)
    }

    @Test func candidateTypesAreInferred() {
        #expect(CandidateType.infer("github.com") == .link)
        #expect(CandidateType.infer("main.swift") == .path)
        #expect(CandidateType.infer("~/Documents") == .path)
        #expect(CandidateType.infer("TeamViewer") == .techTerm)
        #expect(CandidateType.infer("gpt-4o") == .techTerm)
        #expect(CandidateType.infer("Priyanka") == .person)
        #expect(CandidateType.infer("tomorrow") == .word)
    }

    @Test func collisionLexicon() {
        for w in ["Bucket", "Cab", "Cleaning", "Code", "Comp"] { #expect(CollisionLexicon.isCommonWord(w)) }
        for w in ["Akash", "DOCUBE", "Kothari", "TeamViewer", "gpt-4o", "Sundar Pichai"] { #expect(!CollisionLexicon.isCommonWord(w)) }
    }

    @Test func contactsPolicyIsSurfaceAware() {
        #expect(!ContactsChannelPolicy.admits(.contacts, channel: .boost, surface: nil))
        #expect(!ContactsChannelPolicy.admits(.contacts, channel: .boost, surface: .terminal))
        #expect(ContactsChannelPolicy.admits(.contacts, channel: .spellList, surface: .emailBody))
        #expect(ContactsChannelPolicy.admits(.dictionary, channel: .boost, surface: .terminal))
    }

    // MARK: boosted words: lower confidence, tagged

    @Test func boostedWordsAreTaggedAndTakeTheLowerConfidence() {
        func tk(_ id: Int, _ t: String, _ p: Float, _ s: Double, _ e: Double) -> DecodedToken {
            DecodedToken(tokenId: id, text: t, logProb: log(p), startTime: s, endTime: e)
        }
        let toks = [tk(1, "▁ask", 0.95, 0, 0.3), tk(2, "▁kot", 0.5, 0.3, 0.5), tk(3, "ari", 0.8, 0.5, 0.7)]
        let out = BoostAlignment.apply(rescoredText: "ask Kothari", to: toks)
        let spans = BoostTag.spans(from: out)
        #expect(spans.map(\.text) == ["ask", "Kothari"])
        #expect(!BoostTag.isBoosted(spans[0]) && BoostTag.isBoosted(spans[1]))
        #expect(spans[1].provenance == [.asr, .boosted])
        #expect(abs(spans[1].confidence - 0.5) < 1e-4, "lower of the replaced tokens")
    }

    // MARK: controller wiring

    @Test func controllerUsesTheRubricWhenASurfaceIsKnown() {
        let cands = contacts(Self.damage) + [ContextCandidate(text: "Kothari", source: .correction)]
        let terminal = BoostingController(rubric: { _ in ContextRubric.rank(candidates: cands, surface: surface(.terminal)) },
                                          makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(terminal.makeBoosterForUtterance()?.terms == ["Kothari"])
        let secure = BoostingController(dictionary: { ["Kothari"] },
                                        rubric: { _ in ContextRubric.rank(candidates: cands, surface: surface(.secure)) },
                                        makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(secure.makeBoosterForUtterance() == nil, "secure field: nothing boosted, legacy list not used")
        let legacy = BoostingController(dictionary: { ["gpt-4o"] }, rubric: { _ in nil },
                                        makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(legacy.makeBoosterForUtterance()?.terms == ["gpt-4o"], "Context Writer scope-down: spoken form required")
    }
}
