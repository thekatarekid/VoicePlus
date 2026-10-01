import Foundation
import Shared
import Testing
@testable import Actions

/// V5 CU2 — CUA-S1 element chooser against a mock manager: candidates from the AX summary, ≤ 26
/// options per decision with paging, (element, action) → ActionRequest → ActionExecutor, residency.
@Suite("CU2 CUA-S1 element chooser")
struct CuaS1ChooserTests {

    /// Mock model: scores options by a caller-supplied rule; records every state it saw.
    final class MockModel: CuaS1Deciding, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [CuaS1State] = []
        let score: @Sendable (CuaS1Option, CuaS1State) -> Double
        init(score: @escaping @Sendable (CuaS1Option, CuaS1State) -> Double) { self.score = score }
        var states: [CuaS1State] { lock.withLock { _states } }
        func decide(_ state: CuaS1State) async throws -> CuaS1Decision {
            lock.withLock { _states.append(state) }
            if state.options.count > CuaS1State.maxOptions { throw CuaS1Error.tooManyOptions(state.options.count) }
            let raw = state.options.map { score($0, state) }
            let sum = max(raw.reduce(0, +), 1e-9)
            return CuaS1Decision(probabilities: raw.map { $0 / sum })
        }
    }

    /// Picks the option whose label is in `wanted` (+ action), else uniform.
    static func oracle(_ label: String, _ action: String) -> MockModel {
        MockModel { o, _ in (o.label == label && o.action == action) ? 10 : 1 }
    }

    static func element(_ role: String, _ title: String, enabled: Bool = true) -> AXSummary.Element {
        AXSummary.Element(role: role, title: title, value: "", isSelected: false, isEnabled: enabled)
    }

    @Test("candidates: actionable roles only, tree keeps context lines, disabled controls are not offered")
    func candidates() {
        let obs = AXSummary(app: "Portal", window: "Sign in", elements: [
            Self.element("AXStaticText", "Sign in to Portal"), Self.element("AXTextField", "Username"),
            Self.element("AXButton", "Sign in"), Self.element("AXButton", "Help", enabled: false),
            Self.element("AXTab", "Overview"), Self.element("AXCheckBox", "Remember me"),
        ])
        let (tree, options) = CuaS1Chooser.candidates(from: obs, entities: [CuaS1Entity(label: "Username", value: "demo")])
        #expect(tree.contains("[el_0] StaticText \"Sign in to Portal\""))
        #expect(tree.contains("[el_3] Button \"Help\" disabled"))
        #expect(options.map(\.action) == ["fill", "click", "select", "check"])
        #expect(options[0].entityId == "ent_0")
        #expect(!options.contains { $0.label == "Help" })
    }

    @Test("one page: the model's pick becomes the executor request")
    func onePage() async throws {
        let obs = AXSummary(app: "Word", window: "Doc", elements: [Self.element("AXButton", "Bold"), Self.element("AXButton", "Italic")])
        let chooser = CuaS1Chooser(model: Self.oracle("Italic", "click"))
        let c = try await chooser.choose(goal: "make it italic", observation: obs)
        #expect(c.request == ActionRequest(kind: .click, params: ["name": "Italic"]))
        #expect(c.decisions == 1)
    }

    @Test("paging: 60 buttons → 3 pages of ≤ 26 + a final round among the winners; never > 26 options")
    func paging() async throws {
        let els = (0..<60).map { Self.element("AXButton", "Button \($0)") }
        let obs = AXSummary(app: "App", window: "W", elements: els)
        let model = Self.oracle("Button 47", "click")
        let c = try await CuaS1Chooser(model: model).choose(goal: "press button 47", observation: obs)
        #expect(c.option.label == "Button 47")
        #expect(model.states.allSatisfy { $0.options.count <= CuaS1State.maxOptions })
        #expect(model.states.count == 4, "3 pages + 1 final")
        #expect(c.decisions == 4)
        #expect(model.states.last?.options.count == 3)
    }

    @Test("pages never split one element's options, and stay ≤ size")
    func pagesKeepElementsTogether() {
        var options: [CuaS1Option] = []
        for i in 0..<10 { for e in 0..<4 { options.append(CuaS1Option(elementId: "el_\(i)", role: "TextField", label: "F\(i)", action: "fill", entityId: "ent_\(e)")) } }
        let pages = CuaS1Chooser.pages(options, size: 26)
        #expect(pages.allSatisfy { $0.count <= 26 })
        #expect(pages.flatMap { $0 } == options)
        for p in pages { #expect(Set(p.map(\.elementId)).allSatisfy { id in !pages.filter { $0 != p }.contains { $0.contains { $0.elementId == id } } }) }
    }

    @Test("paging is recursive past 26 pages of winners")
    func deepPaging() async throws {
        let els = (0..<700).map { Self.element("AXButton", "B\($0)") }
        let model = Self.oracle("B699", "click")
        let c = try await CuaS1Chooser(model: model).choose(goal: "press B699", observation: AXSummary(app: "A", window: "W", elements: els))
        #expect(c.option.label == "B699")
        #expect(model.states.allSatisfy { $0.options.count <= 26 })
    }

    @Test("fill uses the entity's value; select → focusTab; focus never clears a field")
    func requests() {
        let ents = [CuaS1Entity(label: "Email", value: "a@b.c")]
        #expect(CuaS1Chooser.request(for: .init(elementId: "el_0", role: "TextField", label: "Email", action: "fill", entityId: "ent_0"), entities: ents)
                == ActionRequest(kind: .fillField, params: ["name": "Email", "value": "a@b.c"]))
        #expect(CuaS1Chooser.request(for: .init(elementId: "el_1", role: "Tab", label: "Insert", action: "select"), entities: [])
                == ActionRequest(kind: .focusTab, params: ["target": "Insert"]))
        #expect(CuaS1Chooser.request(for: .init(elementId: "el_2", role: "TextField", label: "Search", action: "focus"), entities: [])?.kind == .click)
        #expect(CuaS1Chooser.request(for: .init(elementId: "el_0", role: "TextField", label: "Email", action: "fill", entityId: "ent_9"), entities: ents) == nil)
    }

    @Test("nothing actionable → noCandidates; a malformed model answer → invalidOutput")
    func errors() async {
        let empty = AXSummary(app: "A", window: "W", elements: [Self.element("AXStaticText", "hi")])
        await #expect(throws: CuaS1Error.noCandidates) { _ = try await CuaS1Chooser(model: Self.oracle("x", "click")).choose(goal: "g", observation: empty) }
        struct Bad: CuaS1Deciding { func decide(_ s: CuaS1State) async throws -> CuaS1Decision { CuaS1Decision(probabilities: [1]) } }
        let two = AXSummary(app: "A", window: "W", elements: [Self.element("AXButton", "a"), Self.element("AXButton", "b")])
        await #expect(throws: CuaS1Error.self) { _ = try await CuaS1Chooser(model: Bad()).choose(goal: "g", observation: two) }
    }

    @Test("chooseAndRun hands the pick to ActionExecutor")
    func executes() async throws {
        let system = MockActionSystem()
        let obs = AXSummary(system: system)
        guard let target = obs.elements.first(where: { $0.role == "AXButton" && $0.isEnabled && !$0.title.isEmpty }) else { return }
        let (choice, result) = try await CuaS1Chooser(model: Self.oracle(target.title, "click"))
            .chooseAndRun(goal: "press \(target.title)", observation: obs, executor: ActionExecutor(system: system))
        #expect(choice.request.kind == .click)
        #expect(result.request == choice.request)
    }

    // MARK: Residency

    actor CountingBackend: CuaS1Backend {
        var loads = 0, unloads = 0
        var isLoaded = false
        func load() async throws { loads += 1; isLoaded = true }
        func unload() { unloads += 1; isLoaded = false }
        func decide(_ state: CuaS1State) async throws -> CuaS1Decision {
            CuaS1Decision(probabilities: state.options.indices.map { $0 == 0 ? 0.9 : 0.1 / Double(max(state.options.count - 1, 1)) })
        }
    }

    @Test("ResidentCuaS1 loads once through ModelResidency as .exclusive and unloads on release")
    func residency() async throws {
        let backend = CountingBackend()
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let resident = ResidentCuaS1(backend: backend, residency: residency)
        let obs = AXSummary(app: "A", window: "W", elements: [Self.element("AXButton", "a"), Self.element("AXButton", "b")])
        _ = try await CuaS1Chooser(model: resident).choose(goal: "g", observation: obs)
        _ = try await CuaS1Chooser(model: resident).choose(goal: "g", observation: obs)
        #expect(await backend.loads == 1)
        #expect(await residency.isResident(CuaS1Catalog.residencyKey))
        #expect(await residency.snapshot().entries.first { $0.key == CuaS1Catalog.residencyKey }?.tier == .exclusive)
        await resident.release()
        #expect(await backend.unloads == 1)
    }

    @Test("this build's backend reports runtimeMissing (FluidUse pin has no CuaS1FourBManager)")
    func unavailableBackend() async {
        let resident = ResidentCuaS1(backend: UnavailableCuaS1Backend(), residency: ModelResidency(budgetBytes: 8 << 30))
        let obs = AXSummary(app: "A", window: "W", elements: [Self.element("AXButton", "a"), Self.element("AXButton", "b")])
        await #expect(throws: (any Error).self) { _ = try await CuaS1Chooser(model: resident).choose(goal: "g", observation: obs) }
    }

    @Test("catalog: text/L1024-gptq + embeddings.f16, ~4 GB, exclusive; forms model on demand")
    func catalog() {
        let e = CuaS1Catalog.fourBText
        #expect(e.hfRepo == "FluidInference/cua-s1-4b-coreml")
        #expect(e.files.contains("text/L1024-gptq/") && e.files.contains("embeddings.f16"))
        #expect(e.tier == .exclusive && e.license == "Apache-2.0")
        #expect((3_800_000_000...4_200_000_000).contains(e.bytes))
        #expect(CuaS1Catalog.variant == "gptq" && CuaS1Catalog.modality == "text")
        #expect(CuaS1Catalog.forms.hfRepo == "FluidInference/cua-s1-forms-coreml")
    }

    // MARK: Forms

    struct MockFormsScorer: FormOptionScoring {
        /// Picks `fill <label>: …` when the context names that label, else skip.
        func score(context: String, options: [String]) async throws -> [Double] {
            options.map { o in
                if o.hasPrefix("fill "), let label = o.dropFirst(5).split(separator: ":").first, context.contains("\"\(label)\"") { return 0.9 }
                return o == "skip" ? 0.5 : 0.01
            }
        }
    }

    @Test("cua-s1-forms: entity → fillField per field, skip yields no request")
    func forms() async throws {
        let obs = AXSummary(app: "Safari", window: "Apply - Safari", elements: [
            Self.element("AXTextField", "Email"), Self.element("AXTextField", "Phone"), Self.element("AXStaticText", "Note"),
        ])
        let decisions = try await CuaS1FormsChooser(scorer: MockFormsScorer())
            .fill(form: obs, entities: [CuaS1Entity(label: "Email", value: "a@b.c")])
        #expect(decisions.count == 2)
        #expect(decisions[0].request == ActionRequest(kind: .fillField, params: ["name": "Email", "value": "a@b.c"]))
        #expect(decisions[1].request == nil && decisions[1].option == "skip")
    }

    @Test("the real forms scorer never downloads: not on disk → notInstalled")
    func formsNotInstalled() async {
        let scorer = FluidCuaS1FormsScorer(residency: ModelResidency(budgetBytes: 1 << 30),
                                           modelURL: URL(fileURLWithPath: "/nonexistent/cua.mlmodelc"))
        #expect(!scorer.isInstalled)
        await #expect(throws: CuaS1Error.notInstalled) { _ = try await scorer.score(context: "c", options: ["a", "b"]) }
    }

    // MARK: GUI-360-style fixture

    @Test("fixture: loads, every expected (element, action) is a candidate, oracle scores 100 %, harness reports")
    func fixture() async throws {
        let set = try CuaS1FixtureSet.load()
        #expect(set.tasks.count >= 25)
        for t in set.tasks {
            let (_, options) = CuaS1Chooser.candidates(from: t.observation, entities: t.entities)
            #expect(options.contains { $0.label == t.expect.label && $0.action == t.expect.action }, "\(t.id)")
        }
        // An oracle per task proves the harness and paging are sound; the real model's ≥ 80 % is T1.
        var hits = 0
        for t in set.tasks {
            let chooser = CuaS1Chooser(model: Self.oracle(t.expect.label, t.expect.action))
            let report = await CuaS1FixtureEval.run(CuaS1FixtureSet(name: set.name, note: set.note, tasks: [t]),
                                                    chooser: chooser, model: "oracle")
            hits += report.rows.filter(\.hit).count
        }
        #expect(hits == set.tasks.count)
        let wrong = await CuaS1FixtureEval.run(set, chooser: CuaS1Chooser(model: MockModel { _, _ in 1 }), model: "uniform")
        #expect(wrong.rows.count == set.tasks.count)
        #expect(CuaS1EvalReport.target == 0.8)
    }
}
