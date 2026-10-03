import Foundation
import Shared
import Testing
@testable import Engine

private func surface(_ kind: SurfaceKind) -> SurfaceResolution {
    SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: [])
}

private struct Fixture082: Decodable {
    var before: String; var after: String; var raw: String; var expectedTerm: String; var expected: String
}

private func fixture082() throws -> Fixture082 {
    let dir = try #require(AppPaths.fixturesDirectory())
    let data = try Data(contentsOf: dir.appendingPathComponent("context/regression/135111-082.json"))
    return try JSONDecoder().decode(Fixture082.self, from: data)
}

/// Tokens the way the TDT final pass writes them: one "▁word" per word, 0.1 s each.
private func tokens(_ text: String, p: Float = 0.9) -> [DecodedToken] {
    text.split(separator: " ").enumerated().map { i, w in
        DecodedToken(tokenId: 100 + i, text: "\u{2581}" + w, logProb: log(p),
                     startTime: Double(i) * 0.1, endTime: Double(i) * 0.1 + 0.1)
    }
}

private func text(_ t: [DecodedToken]) -> String {
    t.map { $0.text.replacingOccurrences(of: "\u{2581}", with: " ") }.joined().trimmingCharacters(in: .whitespaces)
}

@Suite struct NearCaretContextH17Tests {
    @Test func onScreenHyphenTermNearTheCaretReachesThePerTurnLayer() throws {
        let f = try fixture082()
        let cands = ContextCandidates.nearCaret(before: f.before, after: f.after)
        let term = try #require(cands.first { $0.text == f.expectedTerm })
        #expect(term.source == .screenNear)
        #expect(term.caretDistance != nil && term.caretDistance! < 100)
        #expect(term.heardAliases == ["hold to talk"])
        let r = ContextRubric.rank(candidates: cands, surface: surface(.chatComposer))
        #expect(r.perTurnLayer.contains { $0.text == "hold-to-talk" })
        #expect(r.boostTerms.contains("hold-to-talk"))
    }

    @Test func farWindowTermsStayBehindTheLabGate() {
        let window = ContextCandidates.screen(text: "Meeting with Priyanka about TeamViewer")   // no caret
        #expect(window.allSatisfy { $0.source == .screenWindow })
        let r = ContextRubric.rank(candidates: window, surface: surface(.prose))
        #expect(r.boostTerms.isEmpty)
        var c = ContextRubric.Config(); c.nearCaretInBoost = false
        let near = ContextCandidates.nearCaret(before: "ship hold-to-talk ", after: "")
        #expect(ContextRubric(config: c).ranked(candidates: near, surface: surface(.prose)).boostTerms.isEmpty)
    }

    @Test func secureSurfaceGivesNothing() {
        let near = ContextCandidates.nearCaret(before: "hunter2-Secret ", after: "")
        #expect(ContextRubric.rank(candidates: near, surface: surface(.secure)) == .empty)
    }

    @Test func commonWordsNearTheCaretAreNotBoosted() {
        let near = ContextCandidates.nearCaret(before: "Will you Code this. Thanks, Priyanka", after: " and kubectl")
        let texts = Set(near.map(\.text))
        #expect(!texts.contains("Will") && !texts.contains("Code"))
        #expect(texts.contains("Priyanka") && texts.contains("kubectl"))
        let r = ContextRubric.rank(candidates: near, surface: surface(.chatComposer))
        #expect(!r.boostTerms.contains { CollisionLexicon.isCommonWord($0) })
    }

    @Test func caretDistanceIsInUTF16UnitsFromEitherSide() {
        let near = ContextCandidates.nearCaret(before: "Zephyrine 👋 ", after: " Quillon")
        #expect(near.first { $0.text == "Zephyrine" }?.caretDistance == 4)   // " 👋 " = 4 UTF-16 units
        #expect(near.first { $0.text == "Quillon" }?.caretDistance == 1)
    }
}

@Suite struct HeardAliasesH18Tests {
    @Test func hyphenUnderscoreAndCamelCaseHaveSpokenForms() {
        #expect(HeardAliases.aliases(for: "hold-to-talk") == ["hold to talk"])
        #expect(HeardAliases.aliases(for: "snake_case_name") == ["snake case name"])
        #expect(HeardAliases.aliases(for: "TeamViewer") == ["Team Viewer"])
        #expect(HeardAliases.aliases(for: "kubectl").isEmpty)
        #expect(HeardAliases.aliases(for: "iPhone").isEmpty, "a part shorter than 2 letters does not split")
        #expect(HeardAliases.spokenForm("hold-to-talk") == "hold to talk")
        #expect(HeardAliases.spokenForm("TeamViewer") == "TeamViewer")
    }

    @Test func lowercasePhrasesNearTheCaretBecomeCandidates() {
        let near = ContextCandidates.nearCaret(before: "press and hold to talk, then release ", after: "")
        #expect(near.contains { $0.text == "hold to talk" && $0.source == .screenNear })
        #expect(near.contains { $0.text == "then release" })
        let far = ContextCandidates.nearCaret(before: "press and hold to talk " + String(repeating: "x ", count: 200), after: "")
        #expect(!far.contains { $0.text.contains(" ") && $0.text.contains("talk") }, "phrases only close to the caret")
    }

    @Test func spokenAliasIsWrittenInTheOnScreenForm() {
        let out = HeardAliasText.rewrite("in case of hold to talk.", terms: ["hold-to-talk"])
        #expect(out.text == "in case of hold-to-talk.")
        #expect(out.replacements.count == 1)
        #expect(HeardAliasText.rewrite("hold, to talk", terms: ["hold-to-talk"]).replacements.isEmpty)
        #expect(HeardAliasText.rewrite("open team viewer now", terms: ["TeamViewer"]).text == "open TeamViewer now")
    }

    @Test func tokenRewriteKeepsUntouchedTokensAndTakesTheLowestConfidence() throws {
        let f = try fixture082()
        var toks = tokens("In case of hold to talk.")
        toks[4] = DecodedToken(tokenId: 104, text: "\u{2581}to", logProb: log(0.4), startTime: 0.4, endTime: 0.5)
        let o = try #require(HeardAliasRewrite.apply(toks, terms: [f.expectedTerm]))
        #expect(text(o.tokens) == f.expected)
        #expect(Array(o.tokens.prefix(3)) == Array(toks.prefix(3)))
        let swapped = o.tokens[3]
        #expect(swapped.tokenId == BoostAlignment.replacementTokenId)
        #expect(abs(swapped.startTime - 0.3) < 1e-9 && abs(swapped.endTime - 0.6) < 1e-9)
        #expect(abs(swapped.logProb - log(0.4)) < 1e-6)
        #expect(HeardAliasRewrite.apply(tokens("hold the talk"), terms: ["hold-to-talk"]) == nil)
    }

    @Test func boostGuardAcceptsTheOnScreenForm() {
        #expect(BoostGuard.accepts(original: "hold to talk", replacement: "hold-to-talk"))
        #expect(BoostGuard.accepts(original: "whole to talk", replacement: "hold-to-talk"))
    }

    @Test func aliasRewriteLandsEvenWhileTheCTCModelIsNotReady() async {
        struct NoModel: CTCBoostingModelSource {
            func runtime() async -> CTCBoostingRuntime? { nil }
            func readyRescorer() async -> (any CTCRescoring)? { nil }
            func prepare() async {}
        }
        let b = CTCVocabularyBooster(terms: ["hold-to-talk"], source: NoModel())
        let r = await b.boostReport(tokens: tokens("press hold to talk"), samples: [0])
        #expect(r.status == .modelNotReady)
        #expect(r.outcome.map { text($0.tokens) } == "press hold-to-talk")
        let none = await b.boostReport(tokens: tokens("press to talk"), samples: [0])
        #expect(none.outcome == nil)
    }
}
