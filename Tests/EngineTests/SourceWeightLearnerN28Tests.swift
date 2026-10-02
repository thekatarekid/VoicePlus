import Foundation
import Shared
import Testing
@testable import Engine

private func term(_ text: String, _ sources: Set<CandidateSource>) -> RubricTerm {
    RubricTerm(text: text, type: .word, source: sources.first!, sources: sources, score: 1,
               isCollision: false, hasStrongEvidence: false)
}

private func surface(_ kind: SurfaceKind) -> SurfaceResolution {
    SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: [])
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("n28-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(SourceWeightLearner.fileName)
}

@Suite("N28 source weight learner")
struct SourceWeightLearnerN28Tests {
    /// Dictionary terms keep matching in the terminal, screen-window terms never do.
    private func trainTerminal(_ l: SourceWeightLearner, turns: Int = 40) {
        for i in 0..<turns {
            l.record(TurnContextOutcome(
                surfaceID: SurfaceKind.terminal.id, app: "com.apple.Terminal",
                offered: [term("kubectl", [.dictionary]), term("Quarterly\(i)", [.screenWindow])],
                finalText: "kubectl get pods"))
        }
    }

    @Test func matchedAndUnmatchedCountsPerSurfaceAndSource() throws {
        let l = SourceWeightLearner(fileURL: nil)
        l.record(TurnContextOutcome(surfaceID: "chatComposer",
                                    offered: [term("Bhakti", [.participant, .contact]), term("Docker", [.dictionary])],
                                    finalText: "hey bhakti, see you"))
        let s = l.snapshot.stats["chatComposer"]
        #expect(s?["participant"] == SourceStats(offered: 1, matched: 1))
        #expect(s?["contact"] == SourceStats(offered: 1, matched: 1))
        #expect(s?["dictionary"] == SourceStats(offered: 1, matched: 0))
    }

    @Test func wholeWordMatchingOnly() {
        #expect(SourceWeightLearner.contains("open the Code folder", "code"))
        #expect(!SourceWeightLearner.contains("decoder ready", "code"))
        #expect(SourceWeightLearner.contains("ls ~/Developer/app", "~/Developer"))
    }

    @Test func weightsMoveTowardWhatMatchedWithinBounds() {
        let l = SourceWeightLearner(fileURL: nil)
        trainTerminal(l)
        let w = l.weights()
        let dict = w.multiplier(.dictionary, surface: "terminal")
        let screen = w.multiplier(.screenWindow, surface: "terminal")
        #expect(dict > 1.2 && dict <= 1.5)
        #expect(screen >= 0.5 && screen < 0.8)
        // Other surfaces untouched.
        #expect(w.multiplier(.dictionary, surface: "chatComposer") == 1)
        // Huge data still stays inside the bounds.
        trainTerminal(l, turns: 2000)
        let w2 = l.weights()
        #expect(RubricWeights.bounds.contains(w2.surfaceMultipliers["terminal"]?["dictionary"] ?? 1))
        #expect(RubricWeights.bounds.contains(w2.surfaceMultipliers["terminal"]?["screenWindow"] ?? 1))
        #expect((l.snapshot.stats["terminal"]?["dictionary"]?.offered ?? 0) <= l.config.decayAt)
    }

    @Test func fewOffersLeaveWeightsAtOne() {
        let l = SourceWeightLearner(fileURL: nil)
        trainTerminal(l, turns: 5)
        #expect(l.weights().surfaceMultipliers.isEmpty)
    }

    @Test func correctedAwaySwapLowersTheSource() {
        let l = SourceWeightLearner(fileURL: nil)
        for _ in 0..<30 {
            // A Contacts boost turned "bucket" into "Bucket" (a contact); the user corrected it back.
            l.record(TurnContextOutcome(surfaceID: "chatComposer",
                                        offered: [term("Bucket", [.contact]), term("Bhakti", [.participant])],
                                        rawText: "fill the Bucket Bhakti", finalText: "fill the bucket Bhakti",
                                        corrections: [HeardCorrection(heard: "Bucket", written: "bucket")]))
        }
        let s = l.snapshot.stats["chatComposer"]?["contact"]
        #expect(s?.matched == 0)
        #expect(s?.correctedAway == 30)
        let w = l.weights()
        #expect(w.multiplier(.contact, surface: "chatComposer") == 0.5)
        #expect(w.multiplier(.participant, surface: "chatComposer") > 1)
    }

    @Test func boostedSwapThatDidNotSurviveCountsAsUndone() {
        let l = SourceWeightLearner(fileURL: nil)
        l.record(TurnContextOutcome(surfaceID: "prose", offered: [term("DOCUBE", [.dictionary])],
                                    rawText: "the DOCUBE is ready", finalText: "the doc is ready"))
        #expect(l.snapshot.stats["prose"]?["dictionary"] == SourceStats(offered: 1, matched: 0, correctedAway: 1))
    }

    @Test func correctionToAnOfferedTermCountsAsNeededAndKeepsHeardAlias() {
        let l = SourceWeightLearner(fileURL: nil)
        l.record(TurnContextOutcome(surfaceID: "codeEditor", app: "com.microsoft.VSCode",
                                    offered: [term("GRDB", [.correction])],
                                    finalText: "import grid bee",
                                    corrections: [HeardCorrection(heard: "grid bee", written: "GRDB")]))
        #expect(l.snapshot.stats["codeEditor"]?["correction"]?.matched == 1)
        #expect(l.aliases(for: "GRDB") == ["grid bee"])
        #expect(l.aliases(for: "grdb", app: "com.microsoft.VSCode") == ["grid bee"])
        // Per-app alias stays scoped; a global alias is shared.
        l.record(TurnContextOutcome(surfaceID: "prose", app: "com.apple.Notes", offered: [],
                                    finalText: "x", corrections: [HeardCorrection(heard: "grid b", written: "GRDB")]))
        #expect(l.aliases(for: "GRDB", app: "com.microsoft.VSCode") == ["grid bee", "grid b"])
        #expect(l.snapshot.appAliases["com.apple.Notes"]?["grdb"] == ["grid b"])
        #expect(l.snapshot.appAliases["com.microsoft.VSCode"]?["grdb"] == ["grid bee"])
        let c = l.attachingAliases([ContextCandidate(text: "GRDB", source: .dictionary)])
        #expect(c.first?.heardAliases == ["grid bee", "grid b"])
    }

    @Test func aliasesAreCappedAndRejectNewlinesAndNoOps() {
        var cfg = SourceWeightLearner.Config()
        cfg.maxAliasesPerTerm = 3
        let l = SourceWeightLearner(fileURL: nil, config: cfg)
        let fixes = (0..<5).map { HeardCorrection(heard: "heard \($0)", written: "Term") }
            + [HeardCorrection(heard: "line\nbreak", written: "Term"), HeardCorrection(heard: "term", written: "Term")]
        l.record(TurnContextOutcome(surfaceID: "prose", offered: [], finalText: "", corrections: fixes))
        #expect(l.aliases(for: "Term") == ["heard 2", "heard 3", "heard 4"])
    }

    @Test func secureSurfaceIsNeverRecorded() {
        let url = tempURL()
        let l = SourceWeightLearner(fileURL: url)
        l.record(TurnContextOutcome(surfaceID: SurfaceKind.secure.id, offered: [term("hunter2", [.screenNear])],
                                    finalText: "hunter2", corrections: [HeardCorrection(heard: "hunter", written: "hunter2")]))
        #expect(l.snapshot == LearnedContextState())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistsAsJSONAndReloads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let l = SourceWeightLearner(fileURL: url)
        trainTerminal(l)
        l.record(TurnContextOutcome(surfaceID: "prose", offered: [], finalText: "",
                                    corrections: [HeardCorrection(heard: "voice plus", written: "VoicePlus")]))
        let data = try Data(contentsOf: url)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"version\":1"))
        #expect(!json.contains("kubectl get pods"))   // final text is never stored
        let reloaded = SourceWeightLearner(fileURL: url)
        #expect(reloaded.snapshot == l.snapshot)
        #expect(reloaded.weights() == l.weights())
        #expect(reloaded.aliases(for: "voiceplus") == ["voice plus"])
        reloaded.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(reloaded.weights() == RubricWeights())
    }

    @Test func corruptFileStartsFresh() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(SourceWeightLearner(fileURL: url).snapshot == LearnedContextState())
    }

    @Test func defaultFileLivesUnderSupportDirectory() {
        #expect(SourceWeightLearner.defaultURL().deletingLastPathComponent() == AppPaths.supportDirectory())
    }

    @Test func learnedWeightsChangeTheRubricRanking() {
        let l = SourceWeightLearner(fileURL: nil)
        trainTerminal(l)
        let candidates = [ContextCandidate(text: "Kubernetes", source: .dictionary, evidence: 0.5),
                          ContextCandidate(text: "Grafana", source: .dictionary, evidence: 0.5)]
        let rubric = ContextRubric(weights: l.weights())
        let learned = rubric.score(candidates[0], surface: surface(.terminal))?.0 ?? 0
        let base = ContextRubric().score(candidates[0], surface: surface(.terminal))?.0 ?? 0
        #expect(learned > base)
        // Ranked-context convenience init offers the boost layers.
        let ranked = rubric.ranked(candidates: candidates, surface: surface(.terminal))
        let outcome = TurnContextOutcome(surface: .terminal, ranked: ranked, finalText: "kubernetes")
        #expect(Set(outcome.offered.map(\.text)) == ["Kubernetes", "Grafana"])
        #expect(outcome.surfaceID == "terminal")
    }
}
