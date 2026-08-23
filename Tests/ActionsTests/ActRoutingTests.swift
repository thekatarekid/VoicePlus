import Foundation
import Testing
@testable import Actions

@Suite("P4.2 act routing")
struct ActRoutingTests {
    static let catalog = try! ActionCatalog.load()
    func parser(active: Bool = true) -> ActIntentParser { ActIntentParser(catalog: Self.catalog, activation: ActDomainState(active: active)) }

    @Test func inertWhenDomainOff() {
        let p = parser(active: false)
        #expect(p.preRoute("close the window", appBundleID: nil) == nil)
        #expect(p.preRoute("stop", appBundleID: nil) == nil)
    }

    @Test func activationToggles() {
        let a = ActDomainState(); #expect(!a.isActDomainActive)
        a.activate(); #expect(a.isActDomainActive); a.deactivate(); #expect(!a.isActDomainActive)
        let p = ActIntentParser(catalog: Self.catalog, activation: a)
        #expect(p.preRoute("scroll down", appBundleID: nil) == nil)
        a.activate(); #expect(p.preRoute("scroll down", appBundleID: nil)?.isDeterministic == true)
    }

    @Test(arguments: ["stop", "Stop!", "halt", "abort", "never mind", "cancel that"])
    func stopGrammar(_ s: String) { #expect(parser().parse(s) == .stop) }

    @Test func confirmAndCancelGrammar() {
        #expect(parser().parse("confirm") == .confirm); #expect(parser().parse("do it") == .confirm)
        #expect(parser().parse("cancel") == .cancel); #expect(parser().parse("no") == .cancel)
        #expect(parser().parse("") == .empty); #expect(parser().parse("   ") == .empty)
    }

    /// Routing matrix: every catalogue phrasing resolves to its own entry, deterministically.
    @Test func routingMatrixCatalogue() {
        let p = parser(); var hits = 0, total = 0
        for e in Self.catalog.entries {
            total += 1
            guard case .deterministic(let m, let req) = p.parse(DeterministicMockApps.phrase(for: e)) else { continue }
            if m.entry.id == e.id, req.kind == e.kind, req.reversibility == e.reversibility { hits += 1 }
        }
        #expect(hits == total, "\(hits)/\(total)")
    }

    @Test(arguments: [
        ("scrol down", true), ("close the windw", true), ("open url github dot com", true),
        ("open the PR tab and then scroll to the failing check", false),
        ("find the invoice from last march and forward it to accounting", false),
        ("can you tidy my desktop", false), ("please reorganise these tabs by topic", false),
        ("book a table for two on friday", false),
    ])
    func routingMatrixFuzzyVsAgentic(_ phrase: String, deterministic: Bool) {
        let r = parser().parse(phrase)
        #expect(r.isDeterministic == deterministic, "\(phrase) -> \(r)")
        #expect(r.isAgentic == !deterministic)
    }

    @Test func agenticGoalPreservesRawText() {
        guard case .agentic(let g) = parser().parse("  Open the PR tab and then scroll to the failing check ") else { Issue.record("not agentic"); return }
        #expect(g == "Open the PR tab and then scroll to the failing check")
    }

    @Test func appKindScopingUsesBundleID() {
        let p = parser()
        let inBrowser = p.parse("new tab", appBundleID: "com.apple.Safari")
        #expect(inBrowser.isDeterministic)
        if case .deterministic(let m, _) = inBrowser { #expect(m.entry.applies(to: .browser)) }
        // Unknown bundle → unscoped match still allowed.
        #expect(p.parse("new tab", appBundleID: "com.example.unknown").isDeterministic)
    }

    @Test func argumentCapturedIntoRequest() {
        guard case .deterministic(_, let req) = parser().parse("switch to Preview") else { Issue.record("x"); return }
        #expect(req.kind == .focusApp); #expect(req.params["target"] == "Preview")
    }
}

@Suite("P4.2 act router")
struct ActRouterTests {
    static let catalog = try! ActionCatalog.load()
    final class Recorder: AgentActionBackend, @unchecked Sendable {
        var goals: [String] = []; var stops = 0; var isRunning = false
        func run(goal: String) async -> AgentRunReport { goals.append(goal); return AgentRunReport(goal: goal, status: .completed(summary: "ok"), records: [], rounds: 1) }
        func stop() async { stops += 1 }
    }
    func make(front: String = "com.apple.Safari") -> (ActRouter, MockActionSystem, Recorder, ConsentEngine) {
        let sys = DeterministicMockApps.desktop(catalog: Self.catalog, front: front)
        let consent = ConsentEngine(); let rec = Recorder()
        let r = ActRouter(parser: ActIntentParser(catalog: Self.catalog, activation: ActDomainState(active: true)), consent: consent, executor: ActionExecutor(system: sys), agent: rec)
        return (r, sys, rec, consent)
    }

    @Test func deterministicRunsThroughConsentAndExecutor() async throws {
        let (r, sys, rec, _) = make()
        let d = try await r.handle("scroll down", appBundleID: "com.apple.Safari")
        guard case .deterministic(let res, let out) = d else { Issue.record("\(d)"); return }
        #expect(res?.outcome.isSuccess == true); #expect(out == .executed(ExecutionReceipt(handle: res!.request.catalogID!)))
        #expect(sys.log.contains { $0.contains("scroll") }); #expect(rec.goals.isEmpty)
    }

    @Test func unmatchedGoesToAgent() async throws {
        let (r, _, rec, _) = make()
        let d = try await r.handle("open the PR tab and then scroll to the failing check")
        #expect(rec.goals == ["open the PR tab and then scroll to the failing check"])
        if case .agentic(let rep) = d { #expect(rep.status == .completed(summary: "ok")) } else { Issue.record("\(d)") }
    }

    @Test func inactiveDomainIgnored() async throws {
        let (r0, _, _, _) = make()
        let r = ActRouter(parser: ActIntentParser(catalog: Self.catalog, activation: ActDomainState(active: false)), consent: r0.consent, executor: r0.executor, agent: r0.agent)
        #expect(try await r.handle("scroll down") == .ignored(reason: "act domain inactive"))
    }

    @Test func irreversibleWaitsThenConfirms() async throws {
        let (r, sys, _, _) = make()
        let entry = try #require(Self.catalog.entries.first { $0.reversibility == .irreversible && $0.kind == .shortcut })
        let d = try await r.handle(entry.phrasings[0])
        guard case .deterministic(let res, .awaitingConfirmation) = d else { Issue.record("\(d)"); return }
        #expect(res == nil); #expect(r.hasPendingConfirmation); #expect(!sys.log.contains { $0.hasPrefix("key") })
        let c = try await r.handle("confirm")
        guard case .confirmed(.executed) = c else { Issue.record("\(c)"); return }
        #expect(sys.log.contains { $0.hasPrefix("key") }); #expect(!r.hasPendingConfirmation)
    }

    @Test func spokenCancelDropsPendingCard() async throws {
        let (r, sys, _, _) = make()
        let entry = try #require(Self.catalog.entries.first { $0.reversibility == .irreversible && $0.kind == .shortcut })
        _ = try await r.handle(entry.phrasings[0])
        #expect(try await r.handle("cancel") == .cancelled); #expect(!r.hasPendingConfirmation)
        #expect(try await r.handle("confirm") == .ignored(reason: "nothing to confirm")); #expect(!sys.log.contains { $0.hasPrefix("key") })
    }

    @Test func stopStopsAgentAndPendingCard() async throws {
        let (r, _, rec, _) = make()
        let entry = try #require(Self.catalog.entries.first { $0.reversibility == .irreversible })
        _ = try await r.handle(entry.phrasings[0])
        #expect(try await r.handle("stop") == .stopped); #expect(rec.stops == 1); #expect(!r.hasPendingConfirmation)
    }

    @Test func executorFailureSurfaces() async throws {
        let (r, sys, _, _) = make()
        sys.failNext = .failed("boom")
        await #expect(throws: ActionSystemError.self) { try await r.handle("scroll down") }
    }
}
