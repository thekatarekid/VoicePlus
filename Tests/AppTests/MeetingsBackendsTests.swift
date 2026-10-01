import Engine
import Foundation
@testable import Providers
import Shared
import Testing
@testable import VoicePlusApp

// V5 M22 (+M24) — the Meetings provider picker: lists the on-device model, claude / codex CLI,
// ChatGPT OAuth, Ollama, LM Studio and BYO keys from what is registered (unset ones disabled with
// what to do), and one choice pins both `meeting.*` stages, which the routed generator then uses.

private struct FakeProvider: TextGenerator {
    let id: ProviderID
    var displayName: String
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .subscription
    let privacyClass: PrivacyClass
    var reply = "x"
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        (reply, 1, 1, "h")
    }
}

@Suite("V5 M22 meetings backends", .serialized)
struct MeetingsBackendsTests {
    @Test func everyBackendKindIsListedAndUnsetOnesAreDisabled() {
        let providers: [any Provider] = [
            LocalRulesProvider(),
            FakeProvider(id: "cli.claude", displayName: "claude CLI", privacyClass: .cloud),
            FakeProvider(id: "local.ollama", displayName: "Ollama · llama3", privacyClass: .localNetwork),
            FakeProvider(id: "api.openrouter", displayName: "OpenRouter · gpt-4o-mini", privacyClass: .cloud),
            FakeProvider(id: "api.groq", displayName: "Groq · llama", privacyClass: .cloud),
            FakeProvider(id: "cloud.asr", displayName: "Cloud ASR", privacyClass: .cloud),
        ]
        let options = MeetingBackends.options(providers: providers, localInstalled: false, localName: "Mini")
        #expect(options.map(\.kind) == [.local, .claudeCLI, .codexCLI, .chatGPT, .ollama, .lmStudio, .apiKey, .apiKey])
        #expect(options.filter(\.isAvailable).map(\.id) == ["cli.claude", "local.ollama", "api.groq", "api.openrouter"])
        let local = options[0]
        #expect(local.id == "local" && !local.isAvailable && local.detail.contains("Settings › Models"))
        #expect(options.first { $0.kind == .chatGPT }?.detail.contains("Sign in with ChatGPT") == true)
        #expect(options.first { $0.id == "local.ollama" }?.staysOnMac == true)
        #expect(options.first { $0.id == "cli.claude" }?.staysOnMac == false)
        #expect(!options.contains { $0.id == "local.rules" || $0.id == "cloud.asr" })
    }

    @Test func noKeyMeansOneSetupRow() {
        let options = MeetingBackends.options(providers: [], localInstalled: true, localName: "Mini on this Mac")
        #expect(options.filter { $0.kind == .apiKey }.count == 1)
        #expect(options.filter(\.isAvailable).map(\.id) == ["local"])
        #expect(options[0].detail == "Mini on this Mac")
    }

    @Test func choosingPinsBothMeetingStagesAndLocalClearsThem() throws {
        let settings = InMemorySettingsStore()
        #expect(MeetingBackends.selection(settings) == .option("local"))
        let options = MeetingBackends.options(providers: [FakeProvider(id: "cli.codex", displayName: "codex", privacyClass: .cloud)],
                                              localInstalled: true, localName: "Mini")
        let codex = try #require(options.first { $0.id == "cli.codex" })
        #expect(MeetingBackends.choose(codex, settings: settings))
        #expect(settings.string("routing.meeting.notes") == "provider:cli.codex")
        #expect(settings.string("routing.meeting.ask") == "provider:cli.codex")
        #expect(MeetingBackends.selection(settings) == .option("cli.codex"))

        let unset = try #require(options.first { $0.kind == .chatGPT })
        #expect(!MeetingBackends.choose(unset, settings: settings), "a row with nothing behind it never becomes a pin")
        #expect(settings.string("routing.meeting.ask") == "provider:cli.codex")

        settings.set("provider:api.groq", for: "routing.meeting.ask")
        #expect(MeetingBackends.selection(settings) == .mixed)

        #expect(MeetingBackends.choose(options[0], settings: settings))
        #expect(settings.string("routing.meeting.notes") == nil && settings.string("routing.meeting.ask") == nil)
        #expect(MeetingBackends.selection(settings) == .option("local"))
    }

    @Test func pickedBackendIsWhatTheRoutedGeneratorCalls() async throws {
        let settings = InMemorySettingsStore()
        let table = RoutingTable(providers: [FakeProvider(id: "oauth.chatgpt", displayName: "ChatGPT", privacyClass: .cloud, reply: "FROM CHATGPT")],
                                 logger: InMemoryNetworkLogger())
        let intelligence = MeetingIntelligence()
        #expect(intelligence.backendOptions().isEmpty)
        intelligence.install(routing: table, settings: settings,
                             local: MeetingLocalLLMProvider(inner: LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/nope.gguf")))),
                             embedder: HashingSentenceEmbedder())
        let chatGPT = try #require(intelligence.backendOptions().first { $0.kind == .chatGPT })
        #expect(chatGPT.isAvailable)
        #expect(intelligence.chooseBackend(chatGPT))
        #expect(intelligence.backendSelection == .option("oauth.chatgpt"))
        #expect(intelligence.askRoute() == MeetingAskRoute(name: "ChatGPT", isLocal: false))
        let out = try await RoutingMeetingGenerator(table: table, settings: settings, stage: .meetingNotes)
            .generate(stage: .meetingNotes, system: "S", user: "U")
        #expect(out == "FROM CHATGPT")
    }

    @Test func lookAgainRegistersLocalServersOnce() async {
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let intelligence = MeetingIntelligence()
        intelligence.install(routing: table, settings: InMemorySettingsStore(),
                             local: MeetingLocalLLMProvider(inner: LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/nope.gguf")))),
                             embedder: HashingSentenceEmbedder())
        let found = [LocalServerInfo(kind: .lmStudio, baseURL: URL(string: "http://127.0.0.1:1234")!, models: ["qwen"])]
        await intelligence.discoverLocalServers(detect: { found })
        await intelligence.discoverLocalServers(detect: { found })
        #expect(table.allProviders.filter { $0.id == "local.lmStudio" }.count == 1)
        #expect(intelligence.backendOptions().first { $0.kind == .lmStudio }?.isAvailable == true)
    }
}
