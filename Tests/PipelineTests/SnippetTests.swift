import Testing
import Foundation
import Shared
@testable import Pipeline

/// P2.6 — snippet store (CRUD, normalization), pre-route priority, expansion stage.
@Suite struct SnippetTests {
    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence, audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }
    static func store() -> InMemorySnippetStore {
        InMemorySnippetStore([Snippet(trigger: "sig", body: "Best,\nAditya"), Snippet(trigger: "my address", body: "12 Main St, Pune 411001"),
                              Snippet(trigger: "scratch that", body: "(snippet wins)")])
    }

    // MARK: Normalization + matching

    @Test func normalizationStripsCaseAndPunctuation() {
        #expect(SnippetNormalizer.normalize("  My Address. ") == "my address")
        #expect(SnippetNormalizer.normalize("Sig,") == "sig")
        #expect(SnippetNormalizer.normalize("don't-stop") == "don't-stop")
        #expect(SnippetNormalizer.normalize("!!!") == "")
    }

    @Test func exactMatchOnly() {
        let s = Self.store()
        #expect(s.match("Sig.")?.body == "Best,\nAditya")
        #expect(s.match("MY  ADDRESS")?.trigger == "my address")
        #expect(s.match("my address please") == nil)
        #expect(s.match("address") == nil)
        #expect(s.match("") == nil)
    }

    // MARK: CRUD

    @Test func createUpdateDelete() throws {
        let s = InMemorySnippetStore()
        let made = try s.create(trigger: "Phone", body: "+91 98")
        #expect(try s.all().count == 1)
        let updated = try s.update(id: made.id, body: "+91 99")
        #expect(updated.body == "+91 99" && updated.trigger == "Phone")
        _ = try s.update(id: made.id, trigger: "mobile")
        #expect(s.match("phone") == nil && s.match("Mobile") != nil)
        try s.delete(id: made.id)
        #expect(try s.all().isEmpty)
    }

    @Test func rejectsEmptyAndDuplicateTriggers() throws {
        let s = Self.store()
        #expect(throws: SnippetError.emptyTrigger) { try s.create(trigger: " . ", body: "x") }
        #expect(throws: SnippetError.emptyBody) { try s.create(trigger: "ok", body: "  ") }
        #expect(throws: SnippetError.duplicateTrigger("sig")) { try s.create(trigger: "SIG.", body: "y") }
        #expect(throws: SnippetError.notFound("nope")) { try s.delete(id: "nope") }
        #expect(throws: SnippetError.notFound("nope")) { try s.update(id: "nope", body: "b") }
    }

    @Test func updatingSameSnippetIsNotADuplicate() throws {
        let s = Self.store()
        let sig = try #require(s.match("sig"))
        _ = try s.update(id: sig.id, trigger: "Sig", body: "Cheers")
        #expect(s.match("sig")?.body == "Cheers")
        #expect(try s.all().count == 3)
    }

    @Test func databaseStoreRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        let s = DatabaseSnippetStore(database: db)
        let a = try s.create(trigger: "sig", body: "Best,\nA")
        _ = try s.create(trigger: "addr", body: "Main St")
        #expect(try s.all().map(\.trigger) == ["addr", "sig"])
        #expect(s.match("SIG")?.body == "Best,\nA")
        _ = try s.update(id: a.id, body: "Cheers")
        #expect(try db.snippets().first { $0.id == a.id }?.body == "Cheers")
        try s.delete(id: a.id)
        #expect(try s.all().count == 1)
        #expect(throws: SnippetError.notFound(a.id)) { try s.delete(id: a.id) }
    }

    @Test func databaseStoreSeesSettingsEdits() throws {
        let db = try AppDatabase.inMemory()
        try db.save(SnippetRecord(trigger: "Sig", body: "from settings"))
        #expect(DatabaseSnippetStore(database: db).match("sig")?.body == "from settings")
    }

    // MARK: Pre-route priority

    @Test func preRouteWinsOverRepairRule() {
        let gk = PreRoutingClassifier(hooks: [SnippetPreRoute(store: Self.store())])
        let d = gk.classify("scratch that", context: StageContext())
        #expect(d.route == .dictate && d.routeConfidence == 1 && d.routeSource == .rules)
        let plain = LocalGatekeeper.shared.classify("scratch that", context: StageContext())
        #expect(plain.route == .repairCommand)
    }

    @Test func preRouteDefersWhenNoTrigger() {
        let gk = PreRoutingClassifier(hooks: [SnippetPreRoute(store: Self.store())])
        let d = gk.classify("no I said Kothari", context: StageContext())
        #expect(d.route == .repairCommand)
        #expect(gk.classify("", context: StageContext()).route == .none)
    }

    @Test func preRouteKeepsContextRegister() {
        let gk = PreRoutingClassifier(hooks: [SnippetPreRoute(store: Self.store())])
        let d = gk.classify("sig", context: StageContext(register: .email))
        #expect(d.register == .email && d.registerSource == .context)
        #expect(gk.classify("sig", context: StageContext()).register == .unknown)
    }

    @Test func preRouteLatencyIsWithinBudget() {
        let gk = PreRoutingClassifier(hooks: [SnippetPreRoute(store: Self.store())])
        let d = gk.classify("my address", context: StageContext())
        #expect(d.latencyMs < 15)
    }

    @Test func gatekeeperStageAcceptsPreRoutingClassifier() async {
        let stage = GatekeeperStage(local: PreRoutingClassifier(hooks: [SnippetPreRoute(store: Self.store())]))
        let d = await stage.decide(Self.spans("scratch that"), context: StageContext(), providers: LocalOnlyProviderRouting())
        #expect(d.route == .dictate)
    }

    // MARK: Expansion stage

    @Test func expandsExactTriggerPreservingContract() async throws {
        let input = Self.spans("my address")
        let out = try await SnippetStage(store: Self.store()).process(input, context: StageContext())
        #expect(out.count == 2)
        #expect(out[0].text == "12 Main St, Pune 411001" && out[1].text == "")
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out.allSatisfy { $0.provenance == [.asr, .snippet] })
        #expect(SnippetStage.didExpand(input: input, output: out))
    }

    @Test func nonTriggerPassesThroughUntouched() async throws {
        let input = Self.spans("my address is downtown")
        let out = try await SnippetStage(store: Self.store()).process(input, context: StageContext())
        #expect(out.joinedText == "my address is downtown")
        #expect(out.allSatisfy { $0.provenance.last == .snippet })
        #expect(!SnippetStage.didExpand(input: input, output: out))
        #expect(try await SnippetStage(store: Self.store()).process([], context: StageContext()).isEmpty)
    }

    @Test func lowConfidenceTriggerIsFlaggedNotExpanded() async throws {
        var input = Self.spans("my address")
        input[1].confidence = 0.3
        let out = try await SnippetStage(store: Self.store()).process(input, context: StageContext())
        #expect(out.joinedText == "my address")
        #expect(out[1].needsRepair && !out[0].needsRepair)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
    }

    @Test func disabledByContextKey() async throws {
        var ctx = StageContext(); ctx.extra[SnippetStage.enabledKey] = "false"
        let out = try await SnippetStage(store: Self.store()).process(Self.spans("sig"), context: ctx)
        #expect(out.joinedText == "sig")
    }

    @Test func runnerExpandsSnippetBeforeFormatters() async throws {
        let store = Self.store()
        let runner = PipelineRunner(gatekeeper: GatekeeperStage(local: PreRoutingClassifier(hooks: [SnippetPreRoute(store: store)])),
                                    stages: [SnippetStage(store: store)] + StageRegistry.allStages().filter { $0.id != .gatekeeper })
        let r = try await runner.run(Self.spans("scratch that"), context: StageContext(register: .prose))
        #expect(r.decision.route == .dictate)
        #expect(r.text.hasPrefix("(snippet wins)"))
    }
}
