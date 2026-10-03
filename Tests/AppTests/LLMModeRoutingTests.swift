import Foundation
import Testing
import Pipeline
import Providers
import Shared
@testable import VoicePlusApp

// H13 — LLM edits reach the on-device model without a pin (instruction + selection + context), a
// pinned provider still comes first, no model → the executor's rules, never a cloud provider unless
// pinned, and the H16 memory refusal surfaces. X4 — the LLM modes persist through CleanupWiring.

final class RecordingProvider: TextGenerator, @unchecked Sendable {
    let id: ProviderID
    let displayName = "rec"
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .free
    let privacyClass: PrivacyClass
    let reply: String
    private let lock = NSLock()
    private var _seen: [(prompt: String, system: String)] = []
    var seen: [(prompt: String, system: String)] { lock.withLock { _seen } }
    init(id: ProviderID, privacy: PrivacyClass = .onDevice, reply: String) {
        self.id = id; self.privacyClass = privacy; self.reply = reply
    }
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        lock.withLock { _seen.append((prompt, system)) }
        return (reply, 0, 0, "on-device")
    }
}

private func request(_ instruction: String, _ selection: String, before: String = "", after: String = "") -> TransformRequest {
    let spans = instruction.split(separator: " ").enumerated().map { i, w in
        TranscriptSpan(text: String(w), confidence: 0.95, audioRange: Double(i)...Double(i) + 0.5, provenance: [.asr])
    }
    return TransformRequest(instruction: spans,
                            selection: SelectionSnapshot(text: selection, range: 0..<selection.count, before: before, after: after),
                            context: StageContext(register: .email))
}

private func routing(_ providers: [any Provider], settings: SettingsStore = InMemorySettingsStore(), ready: Bool = true,
                     refusal: LocalLLMRefusal? = nil) -> RoutingTableProviderRouting {
    let table = RoutingTable(providers: providers, logger: InMemoryNetworkLogger())
    return RoutingTableProviderRouting(table: table, settings: settings,
                                       onDevice: OnDeviceEditRoute(providerID: "local.llamacpp.shared", isReady: { ready },
                                                                   refusal: { refusal }))
}

@Suite struct LLMModeRoutingTests {
    @Test func onDeviceModelGetsInstructionSelectionAndContextWithoutAPin() async throws {
        let model = RecordingProvider(id: "local.llamacpp.shared", reply: "Dear team, we will meet tomorrow.")
        let cloud = RecordingProvider(id: "cloudy", privacy: .cloud, reply: "CLOUD")
        let r = routing([cloud, model])
        #expect(r.isProviderEnabled(for: .transform, context: StageContext()))
        #expect(r.isProviderEnabled(for: .question, context: StageContext()))
        #expect(!r.isProviderEnabled(for: .cleanup, context: StageContext()))   // only edit stages

        let out = try await TransformExecutor(providers: r).execute(
            request("make this formal", "hey guys meet tmrw", before: "Project update.", after: "Thanks."), context: StageContext())
        #expect(out.source == .provider)
        #expect(out.output == "Dear team, we will meet tomorrow.")
        let seen = try #require(model.seen.first)
        #expect(seen.prompt.contains("make this formal"))
        #expect(seen.prompt.contains("hey guys meet tmrw"))
        #expect(seen.prompt.contains("Project update.") && seen.prompt.contains("Thanks."))
        #expect(seen.system.contains("You rewrite text in place"))
        #expect(cloud.seen.isEmpty)   // never a cloud provider unless pinned
    }

    @Test func noModelFallsBackToTheRules() async throws {
        let r = routing([], ready: false)
        #expect(!r.isProviderEnabled(for: .transform, context: StageContext()))
        let out = try await TransformExecutor(providers: r).execute(request("make it uppercase", "hello"), context: StageContext())
        #expect(out.source == .local)
        #expect(out.output == "HELLO")
    }

    @Test func aPinnedProviderComesFirst() async throws {
        let settings = InMemorySettingsStore()
        settings.set("provider:cloudy", for: SettingsKeys.routingPrefix + "transform")
        let model = RecordingProvider(id: "local.llamacpp.shared", reply: "LOCAL")
        let cloud = RecordingProvider(id: "cloudy", privacy: .cloud, reply: "PINNED")
        let r = routing([cloud, model], settings: settings)
        let out = try await r.complete(stage: .transform, prompt: "INSTRUCTION: x", input: "sel", context: StageContext())
        #expect(out == "PINNED")
        #expect(cloud.seen.first?.prompt == "INSTRUCTION: x")
        #expect(model.seen.isEmpty)
    }

    @Test func aFailingModelNeverFallsToAnotherLocalModel() async {
        let other = RecordingProvider(id: "local.llamacpp", reply: "CLEANUP MODEL")
        let r = routing([other])   // shared provider not registered → only the rules remain
        await #expect(throws: ProviderRoutingError.unavailable) {
            _ = try await r.complete(stage: .transform, prompt: "p", input: "i", context: StageContext())
        }
        #expect(other.seen.isEmpty)
    }

    @Test func criticalPressureRefusesWithTheMessage() async {
        let model = RecordingProvider(id: "local.llamacpp.shared", reply: "x")
        let r = routing([model], refusal: .notEnoughMemory)
        await #expect(throws: LocalLLMRefusal.notEnoughMemory) {
            _ = try await r.complete(stage: .transform, prompt: "p", input: "i", context: StageContext())
        }
        #expect(model.seen.isEmpty)
    }

    @Test func questionsGetTheirOwnSystemPrompt() {
        let ctx = RoutingTableProviderRouting.editContext(stage: .question, prompt: "Q", context: StageContext())
        #expect(ctx.extra[PromptBuilder.systemOverrideKey] == RoutingTableProviderRouting.questionSystem)
        #expect(ctx.extra[PromptBuilder.userOverrideKey] == "Q")
        let other = RoutingTableProviderRouting.editContext(stage: .cleanup, prompt: "Q", context: StageContext())
        #expect(other.extra.isEmpty)
    }

    @Test func sharedModelServesEditStages() {
        #expect(SharedLocalLLMProvider.servedStages.contains(.transform))
        #expect(SharedLocalLLMProvider.servedStages.contains(.question))
    }

    // X4
    @Test func llmModesDefaultToFastPathAndPersist() {
        let settings = InMemorySettingsStore()
        #expect(CleanupWiring.llmModes(settings: settings) == .default)
        #expect(CleanupWiring.mode(settings: settings) == .off)
        CleanupWiring.setLLMModes(LLMModes(perAppPolish: true, polishApps: ["com.apple.mail"]), settings: settings)
        #expect(CleanupWiring.llmModes(settings: settings).cleanupMode(bundleID: "com.apple.mail") == .always)
        #expect(CleanupWiring.mode(settings: settings) == .automatic)
    }

    @Test func wiredStageResolvesModesPerRun() {
        let settings = InMemorySettingsStore()
        CleanupWiring.setLLMModes(LLMModes(everyDictation: true), settings: settings)
        let stage = CleanupWiring.stage(routing: RoutingTable(providers: [], logger: InMemoryNetworkLogger()), settings: settings,
                                        residency: ModelResidency(budgetBytes: 4 << 30))
        #expect(stage.modeResolver?(StageContext()) == .always)
        #expect(stage.deadlineForMode?(.always) == LLMModes.polishDeadline)
    }

    @MainActor @Test func settingsSwitchesAreIndependentAndFastPathClearsThem() {
        let settings = InMemorySettingsStore()
        let m = AICleanupSettingsModel(settings: settings, residency: ModelResidency(budgetBytes: 4 << 30))
        #expect(m.modes.fastPathOnly)
        m.setAutoPolish(true)
        m.setPerAppPolish(true)
        m.setPolish("com.apple.mail", true)
        #expect(!m.modes.fastPathOnly && m.modes.autoPolishWhenUnsure && m.modes.perAppPolish && !m.modes.everyDictation)
        m.setFastPathOnly(true)
        #expect(m.modes.fastPathOnly)
        #expect(CleanupWiring.llmModes(settings: settings).polishApps == ["com.apple.mail"])
    }
}
