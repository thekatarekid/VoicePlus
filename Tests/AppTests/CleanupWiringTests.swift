import Foundation
import Testing
import Pipeline
import Providers
import Shared
@testable import VoicePlusApp

// V5 D2 — app wiring: cleanup sits right before style, the generator goes through RoutingTable stage
// `cleanup` (local only unless pinned), the rules fallback never counts as a model, mode from Settings.

private struct EchoProvider: TextGenerator {
    let id: ProviderID
    let displayName = "echo"
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .free
    let privacyClass: PrivacyClass
    let reply: String
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        (reply + "|" + system.prefix(6) + "|" + prompt, 1, 1, "h")
    }
}

@Suite struct CleanupWiringTests {
    @Test func cleanupGoesRightBeforeStyle() {
        let stages = CleanupWiring.inserting(CleanupStage(generator: nil), into: StageRegistry.allStages())
        let ids = stages.map(\.id)
        let c = ids.firstIndex(of: .cleanup)!, s = ids.firstIndex(of: .style)!
        #expect(c + 1 == s)
        #expect(ids.firstIndex(of: .formatterProse)! < c)
    }

    @Test func generatorRoutesThroughTheTableLocalOnly() async throws {
        let table = RoutingTable(providers: [EchoProvider(id: "cloudy", privacyClass: .cloud, reply: "CLOUD"),
                                             EchoProvider(id: "local.llamacpp", privacyClass: .onDevice, reply: "LOCAL")],
                                 logger: InMemoryNetworkLogger())
        let gen = RoutingCleanupGenerator(table: table, settings: InMemorySettingsStore(), promptStyle: .delimited)
        let out = try await gen.cleanup(CleanupPrompt(system: "SYSTEM rules", user: "hello", style: .delimited), context: StageContext())
        #expect(out == "LOCAL|SYSTEM|hello")
        #expect(table.choice(for: .cleanup) == .localOnly)
    }

    @Test func explicitPinIsHonoured() async throws {
        let settings = InMemorySettingsStore()
        settings.set("provider:cloudy", for: SettingsKeys.routingPrefix + "cleanup")
        let table = RoutingTable(providers: [EchoProvider(id: "cloudy", privacyClass: .cloud, reply: "CLOUD")], logger: InMemoryNetworkLogger())
        let out = try await RoutingCleanupGenerator(table: table, settings: settings, promptStyle: .delimited)
            .cleanup(CleanupPrompt(system: "S", user: "u", style: .delimited), context: StageContext())
        #expect(out.hasPrefix("CLOUD"))
    }

    @Test func rulesFallbackIsNotAModel() async {
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let gen = RoutingCleanupGenerator(table: table, settings: InMemorySettingsStore(), promptStyle: .delimited)
        await #expect(throws: (any Error).self) {
            _ = try await gen.cleanup(CleanupPrompt(system: "S", user: "u", style: .delimited), context: StageContext())
        }
    }

    @Test func modeComesFromSettings() {
        let settings = InMemorySettingsStore()
        #expect(CleanupWiring.mode(settings: settings) == .automatic)
        settings.set("always", for: CleanupMode.settingsKey)
        #expect(CleanupWiring.mode(settings: settings) == .always)
    }

    @Test func providerUsesThePlanTierAndCleanupKey() {
        let p = CleanupWiring.provider(residency: ModelResidency(budgetBytes: 4 << 30))
        #expect(p.config.residencyKey == "cleanup.llm")
        #expect(p.config.tier == .onDemand)
        #expect(p.config.modelPath.lastPathComponent == LocalLLMCatalog.cleanupDefault.fileName)
    }
}
