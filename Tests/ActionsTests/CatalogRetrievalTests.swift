import Foundation
import Testing
@testable import Actions

/// V5 CU4 — catalogue retrieval (top 3 by cosine) → fuzzy confirm → execute at ≥ 0.8; else CUA-S1
/// (single step); else the planner.
@Suite struct CatalogRetrievalTests {
    static let catalog = try! ActionCatalog.load()

    /// Hashing after a word-synonym table: "display desktop" and "show desktop" embed identically.
    struct SynonymEmbedder: ActPhraseEmbedding {
        let name = "synonym-stub"
        var synonyms: [String: String] = ["display": "show", "terminate": "close"]
        func embed(_ texts: [String]) async -> [[Float]] {
            texts.map { t in
                HashingPhraseEmbedder().vector(FuzzyMatch.tokens(t).map { synonyms[$0] ?? $0 }.joined(separator: " "))
            }
        }
    }

    /// Counts calls; every text gets the same vector.
    final class CountingEmbedder: ActPhraseEmbedding, @unchecked Sendable {
        let name = "counting"
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var texts = 0
        func embed(_ t: [String]) async -> [[Float]] {
            lock.withLock { calls += 1; texts += t.count }
            return t.map { _ in [1, 0] }
        }
    }

    /// Utterances orthogonal to every phrasing (cosine 0): the index build embeds the phrasings in one
    /// batch, an utterance arrives alone.
    struct OrthogonalEmbedder: ActPhraseEmbedding {
        let name = "orthogonal"
        func embed(_ texts: [String]) async -> [[Float]] { texts.map { _ in texts.count > 1 ? [1, 0] : [0, 1] } }
    }

    static func parser() -> ActIntentParser { ActIntentParser(catalog: catalog, activation: ActDomainState(active: true)) }

    @Test("every phrasing is embedded once; concurrent prepares share one build")
    func embedsOnce() async {
        let e = CountingEmbedder()
        let index = CatalogRetrievalIndex(catalog: Self.catalog, embedder: e)
        async let a: Void = index.prepare()
        async let b: Void = index.prepare()
        _ = await (a, b)
        _ = await index.top("close tab")
        let phrasings = Self.catalog.entries.reduce(0) { $0 + $1.phrasings.count }
        #expect(await index.phrasingCount == phrasings)
        #expect(e.texts == phrasings + 1)   // the build + one utterance
        #expect(CatalogRetrievalIndex.embeddingText("open url {arg}") == "open url")
    }

    @Test("top 3: distinct entries, best cosine first, scoped to the app kind")
    func topThree() async {
        let index = CatalogRetrievalIndex(catalog: Self.catalog, embedder: HashingPhraseEmbedder())
        let top = await index.top("close this tab", appKind: .browser)
        #expect(top.count == 3)
        #expect(top.first?.entry.id == "browser.close_tab")
        #expect(Set(top.map(\.entry.id)).count == 3)
        #expect(zip(top, top.dropFirst()).allSatisfy { $0.cosine >= $1.cosine })
        let editor = await index.top("close this tab", appKind: .editor)
        #expect(!editor.contains { $0.entry.apps == [.browser] })
    }

    @Test("a paraphrase the fuzzy catalogue alone misses executes once retrieval confirms it")
    func paraphraseConfirmed() async {
        let p = Self.parser()
        let parsed = p.parse("display desktop", appBundleID: "com.apple.Notes")
        if case .deterministic(let m, _) = parsed { #expect(m.score < ActIntentParser.retrievalExecuteScore) }
        let index = CatalogRetrievalIndex(catalog: Self.catalog, embedder: SynonymEmbedder())
        let route = await p.refine(parsed, appBundleID: "com.apple.Notes", retrieval: index)
        guard case .deterministic(let m, let req) = route else { Issue.record("\(route)"); return }
        #expect(m.entry.id == "mac.show_desktop")
        #expect(req.catalogID == "mac.show_desktop")
    }

    @Test("meaning alone never executes: a candidate failing the fuzzy confirm stays with CUA-S1 / the planner")
    func meaningAloneNeverExecutes() async {
        let p = Self.parser()
        let index = CatalogRetrievalIndex(catalog: Self.catalog, embedder: SynonymEmbedder())
        // "terminate" embeds as "close" (cosine 1 to "close tab"), but the words disagree.
        let c = await index.top("terminate tab", appKind: .browser)
        #expect(c.first?.entry.id == "browser.close_tab")
        let route = await p.refine(.agentic(goal: "terminate tab"), appBundleID: "com.apple.Safari", retrieval: index)
        #expect(route == .agentic(goal: "terminate tab"))
        #expect(ActIntentParser.confirmScore(cosine: 1, fuzzy: 0.44) == 0.44)
        #expect(ActIntentParser.confirmScore(cosine: 0.85, fuzzy: 0.6) == 0.85)
        #expect(ActIntentParser.confirmScore(cosine: 0.2, fuzzy: 1) == 1)
    }

    @Test("with retrieval a fuzzy-only match below 0.8 must be confirmed; without it the P4.1 threshold stands")
    func fuzzyBandNeedsConfirmation() async throws {
        let p = Self.parser()
        let set = try ActCatalogEvalSet.load()
        var band: (String, String)?
        outer: for c in set.cases {
            for t in c.paraphrases {
                if case .deterministic(let m, _) = p.parse(t, appBundleID: c.app), m.score < ActIntentParser.retrievalExecuteScore {
                    band = (t, c.app); break outer
                }
            }
        }
        let (text, app) = try #require(band)
        let parsed = p.parse(text, appBundleID: app)
        #expect(await p.refine(parsed, appBundleID: app, retrieval: nil) == parsed)
        let orthogonal = CatalogRetrievalIndex(catalog: Self.catalog, embedder: OrthogonalEmbedder())
        let refined = await p.refine(parsed, appBundleID: app, retrieval: orthogonal)
        #expect(refined == .agentic(goal: text), "\(text) in \(app): \(parsed) → \(refined)")
    }

    @Test("forced-agent and multi-step goals skip retrieval")
    func agentGoalsSkipRetrieval() async {
        let p = Self.parser()
        let index = CatalogRetrievalIndex(catalog: Self.catalog, embedder: SynonymEmbedder())
        for g in ["can you display desktop", "display desktop and then close tab"] {
            #expect(await p.refine(.agentic(goal: g), appBundleID: nil, retrieval: index) == .agentic(goal: g))
        }
    }

    @Test("CU6 matcher fixes: fillers, determiners inside a template head, spoken numbers")
    func matcherHygiene() {
        let p = Self.parser()
        func id(_ t: String, _ app: String? = nil) -> (String?, String?) {
            if case .deterministic(let m, _) = p.parse(t, appBundleID: app) { return (m.entry.id, m.argument) }
            return (nil, nil)
        }
        #expect(id("okay launch Preview") == ("mac.open_app", "Preview"))   // was: click OK
        #expect(id("ok click Toolbar") == ("mac.click", "Toolbar"))         // was: click OK
        #expect(id("okay") == ("mac.click_ok", nil))                         // an exact phrasing is never stripped
        #expect(id("close tab please", "com.apple.Safari").0 == "browser.close_tab")
        #expect(id("open the url github dot com").0 == "mac.open_url")      // was: open app "the url …"
        #expect(id("switch to the tab Overview") == ("mac.focus_tab", "Overview"))
        #expect(id("go to desktop two").0 == "mac.space_2")                  // was: open app "desktop two"
        #expect(id("type see you now").1 == "see you now")                    // a template keeps its trailing words
        #expect(ActIntentParser.strippedForms("um open finder for me") == ("open finder for me", "open finder"))
    }
}

/// V5 CU4 — the router's Layer 2: CUA-S1 for single-step goals the catalogue didn't take.
@Suite struct ActRouterLayer2Tests {
    static let catalog = try! ActionCatalog.load()

    final class Recorder: AgentActionBackend, @unchecked Sendable {
        var goals: [String] = []; var isRunning = false
        func run(goal: String) async -> AgentRunReport { goals.append(goal); return AgentRunReport(goal: goal, status: .completed(summary: "ok"), records: [], rounds: 1) }
        func stop() async {}
    }

    final class StubChooser: SingleStepChoosing, @unchecked Sendable {
        var pick: (label: String, p: Double)?
        var fail: Error?
        private(set) var goals: [String] = []
        private(set) var turnsEnded = 0
        init(pick: (String, Double)? = nil, fail: Error? = nil) { self.pick = pick; self.fail = fail }
        func choose(goal: String, observation: AXSummary) async throws -> CuaS1Choice {
            goals.append(goal)
            if let fail { throw fail }
            let (label, p) = pick!
            let o = CuaS1Option(elementId: "el_0", role: "Button", label: label, action: "click")
            return CuaS1Choice(option: o, probability: p, request: ActionRequest(kind: .click, params: ["name": label]), decisions: 1)
        }
        func endTurn() async { turnsEnded += 1 }
    }

    func make() -> (ActRouter, MockActionSystem, Recorder) {
        let sys = ActCatalogEvalDesktop.make(catalog: Self.catalog, front: "com.apple.Safari")
        let rec = Recorder()
        let r = ActRouter(parser: ActIntentParser(catalog: Self.catalog, activation: ActDomainState(active: true)),
                          consent: ConsentEngine(), executor: ActionExecutor(system: sys), agent: rec)
        return (r, sys, rec)
    }

    @Test("an unmatched single-step goal runs CUA-S1's pick through consent + executor; the turn ends")
    func chooserRuns() async throws {
        let (r, sys, rec) = make()
        let chooser = StubChooser(pick: ("Merge pull request", 0.9))
        r.chooser = chooser
        let d = try await r.handle("land the change on main", appBundleID: "com.apple.Safari")
        guard case .deterministic(let res, .executed) = d else { Issue.record("\(d)"); return }
        #expect(res?.outcome.isSuccess == true)
        #expect(sys.log.contains("press Merge pull request"))
        #expect(rec.goals.isEmpty)
        #expect(chooser.turnsEnded == 1)
    }

    @Test("a low-confidence pick, a chooser error or a multi-step goal goes to the planner")
    func plannerFallbacks() async throws {
        let (r, sys, rec) = make()
        let low = StubChooser(pick: ("Merge pull request", 0.2))
        r.chooser = low
        _ = try await r.handle("land the change on main")
        #expect(rec.goals == ["land the change on main"]); #expect(low.turnsEnded == 1)
        #expect(!sys.log.contains { $0.hasPrefix("press") })

        let broken = StubChooser(fail: CuaS1Error.runtimeMissing)
        r.chooser = broken
        _ = try await r.handle("land the change on main")
        #expect(rec.goals.count == 2); #expect(broken.turnsEnded == 1)

        let multi = StubChooser(pick: ("OK", 0.9))
        r.chooser = multi
        _ = try await r.handle("open the PR tab and then scroll to the failing check")
        #expect(multi.goals.isEmpty); #expect(rec.goals.count == 3)
    }

    @Test("the chooser provider is asked once, lazily; nil (8 GB plan) means planner only")
    func lazyProvider() async throws {
        let (r, _, rec) = make()
        final class Box: @unchecked Sendable { var asked = 0 }
        let box = Box()
        r.chooserProvider = { box.asked += 1; return nil }
        _ = try await r.handle("land the change on main")
        _ = try await r.handle("land it again")
        #expect(box.asked == 1); #expect(rec.goals.count == 2)
    }

    @Test("retrieval on the router: a confirmed paraphrase runs the catalogue action, not the agent")
    func retrievalOnRouter() async throws {
        let (r, sys, rec) = make()
        r.retrieval = CatalogRetrievalIndex(catalog: Self.catalog, embedder: CatalogRetrievalTests.SynonymEmbedder())
        let d = try await r.handle("display desktop", appBundleID: "com.apple.Notes")
        guard case .deterministic(let res, _) = d else { Issue.record("\(d)"); return }
        #expect(res?.request.catalogID == "mac.show_desktop")
        #expect(rec.goals.isEmpty)
        #expect(sys.log.contains { $0.hasPrefix("space") })
    }
}
