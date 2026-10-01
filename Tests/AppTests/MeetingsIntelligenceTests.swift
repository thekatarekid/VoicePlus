import Engine
import Foundation
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

// V5 M17 / M16+M21 / M18 — app wiring: `meeting.notes` / `meeting.ask` go through RoutingTable
// (local meeting model by default, a pin first), the rules fallback is never a model, the local
// meeting model serves meeting stages only, Ask's route is disclosed, the detail view model asks,
// names the transcript and exports with names. No GGUF, no network: scripted providers and engines.

private struct EchoProvider: TextGenerator {
    let id: ProviderID
    var displayName: String { "Echo \(id.rawValue)" }
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .free
    let privacyClass: PrivacyClass
    let reply: String
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        (reply, 1, 1, "h")
    }
}

private struct ThrowingProvider: TextGenerator {
    let id: ProviderID
    let displayName = "throws"
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .free
    let privacyClass: PrivacyClass = .onDevice
    let error: ProviderError
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        throw error
    }
}

private final class RecordingEngine: LocalLLMEngine, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var generated: [(maxTokens: Int, budget: TimeInterval)] = []
    func load(modelPath: URL) async throws {}
    func unload() async {}
    func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
        lock.withLock { generated.append((maxTokens, deadline.timeIntervalSinceNow)) }
        return "## Summary\n- From the local model.\n"
    }
}

private let notesReply = "## Summary\n- Picked Postgres.\n\n## Decisions\n- Postgres.\n\n## Action items\n- Sam: migration plan\n"

private let transcript = MeetingTranscript(utterances: [
    MeetingUtterance(speaker: .you, text: "Let's go with Postgres.", range: 0...3, confidence: 0.9),
    MeetingUtterance(speaker: .others(1), text: "I'll write the migration plan.", range: 4...8, confidence: 0.9),
])

@Suite("V5 M17 M16 M18 meetings intelligence", .serialized)
struct MeetingsIntelligenceTests {
    @Test func meetingStagesDefaultToTheLocalMeetingModel() async throws {
        let table = RoutingTable(providers: [EchoProvider(id: "cloudy", privacyClass: .cloud, reply: "CLOUD"),
                                             EchoProvider(id: MeetingLocalLLMProvider.providerID, privacyClass: .onDevice, reply: "LOCAL")],
                                 logger: InMemoryNetworkLogger())
        let gen = RoutingMeetingGenerator(table: table, settings: InMemorySettingsStore(), stage: .meetingNotes)
        let out = try await gen.generate(stage: .meetingNotes, system: "S", user: "U")
        #expect(out == "LOCAL")
        #expect(table.choice(for: .meetingNotes) == .provider(MeetingLocalLLMProvider.providerID))
        #expect(gen.routeName == "Echo local.llamacpp.meetings")
    }

    @Test func aPinnedProviderIsTriedFirst() async throws {
        let settings = InMemorySettingsStore()
        settings.set("provider:claude-cli", for: SettingsKeys.routingPrefix + "meeting.ask")
        let logger = InMemoryNetworkLogger()
        let table = RoutingTable(providers: [EchoProvider(id: "claude-cli", privacyClass: .cloud, reply: "CLI"),
                                             EchoProvider(id: MeetingLocalLLMProvider.providerID, privacyClass: .onDevice, reply: "LOCAL")],
                                 logger: logger)
        let out = try await RoutingMeetingGenerator(table: table, settings: settings, stage: .meetingAsk)
            .generate(stage: .meetingAsk, system: "S", user: "U")
        #expect(out == "CLI")
        #expect(logger.records.map(\.stage) == ["meeting.ask"], "a cloud call is logged to the Data Panel")
    }

    @Test func rulesFallbackIsNotAModelAndFailuresAreClassified() async {
        let empty = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        await #expect(throws: MeetingGenerationError.notConfigured) {
            _ = try await RoutingMeetingGenerator(table: empty, settings: InMemorySettingsStore(), stage: .meetingNotes)
                .generate(stage: .meetingNotes, system: "S", user: "U")
        }
        let timingOut = RoutingTable(providers: [ThrowingProvider(id: MeetingLocalLLMProvider.providerID, error: .timeout)],
                                     logger: InMemoryNetworkLogger())
        await #expect(throws: MeetingGenerationError.transient("timeout")) {
            _ = try await RoutingMeetingGenerator(table: timingOut, settings: InMemorySettingsStore(), stage: .meetingNotes)
                .generate(stage: .meetingNotes, system: "S", user: "U")
        }
        #expect(RoutingMeetingGenerator.classify([.unauthorized, .unavailable("x")]) == .permanent("unauthorized"))
        #expect(RoutingMeetingGenerator.classify([.http(503, "")]).isTransient)
        #expect(RoutingMeetingGenerator.classify([.unavailable("not installed")]) == .notConfigured)
    }

    @Test func localMeetingModelServesMeetingStagesOnly() async throws {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("m17-\(UUID().uuidString).gguf")
        let engine = RecordingEngine()
        let inner = LlamaCppProvider(config: LlamaCppConfig(modelPath: model, residencyKey: "cleanup.llm",
                                                            maxTokens: MeetingLocalLLMProvider.maxTokens,
                                                            deadline: MeetingLocalLLMProvider.deadline),
                                     residency: ModelResidency(budgetBytes: 4 << 30), engine: engine, fileExists: { _ in true })
        let local = MeetingLocalLLMProvider(inner: inner)
        await #expect(throws: ProviderError.unavailable("meeting stages only")) {
            _ = try await local.generate(prompt: "p", system: "s", stage: "cleanup")
        }
        let out = try await local.generate(prompt: "p", system: "s", stage: .meetingNotes)
        #expect(out.text.contains("From the local model."))
        #expect(engine.generated.first?.maxTokens == 1_024)
        #expect((engine.generated.first?.budget ?? 0) > 60, "a meeting gets minutes, not cleanup's 500 ms")
        #expect(local.privacyClass == .onDevice)

        let defaults = MeetingLocalLLMProvider(residency: ModelResidency(budgetBytes: 4 << 30))
        #expect(defaults.inner.config.residencyKey == ResidencyKey.cleanup, "same GGUF, same residency key as cleanup")
        #expect(defaults.inner.config.modelPath == CleanupWiring.model.localURL())
    }

    @Test func installedNotesProviderRunsTheTemplateThroughTheTable() async throws {
        let settings = InMemorySettingsStore()
        settings.set("standup", for: MeetingNoteTemplate.settingsKey)
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let intelligence = MeetingIntelligence()
        #expect(intelligence.notesProvider() is ExtractiveNotesProvider, "extractive until installed")
        let engine = RecordingEngine()
        let inner = LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/tmp/none.gguf")),
                                     residency: ModelResidency(budgetBytes: 4 << 30), engine: engine, fileExists: { _ in true })
        intelligence.install(routing: table, settings: settings, local: MeetingLocalLLMProvider(inner: inner),
                             embedder: HashingSentenceEmbedder())
        #expect(table.provider(MeetingLocalLLMProvider.providerID) != nil)
        let notes = try await intelligence.notesProvider().notes(for: transcript)
        #expect(notes.summary == ["From the local model."])
        #expect(notes.provider.hasSuffix("· standup"))
        #expect(intelligence.template == .standup)
    }

    @Test func notesFallBackToExtractiveWhenNoModelCompletes() async throws {
        let intelligence = MeetingIntelligence()
        intelligence.install(routing: RoutingTable(providers: [], logger: InMemoryNetworkLogger()), settings: InMemorySettingsStore(),
                             local: MeetingLocalLLMProvider(inner: LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/nope.gguf")),
                                                                                    fileExists: { _ in false })),
                             embedder: HashingSentenceEmbedder())
        let notes = try await intelligence.notesProvider().notes(for: transcript)
        #expect(notes.provider == "extractive-local")
    }

    @Test func askRouteIsDisclosed() throws {
        let settings = InMemorySettingsStore()
        let table = RoutingTable(providers: [EchoProvider(id: "claude-cli", privacyClass: .cloud, reply: "x")], logger: InMemoryNetworkLogger())
        let missing = MeetingLocalLLMProvider(inner: LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/nope.gguf"))))
        let intelligence = MeetingIntelligence()
        #expect(intelligence.askRoute() == nil)
        intelligence.install(routing: table, settings: settings, local: missing, embedder: HashingSentenceEmbedder())
        #expect(intelligence.askRoute() == nil, "no local model and nothing pinned: Needs a configured service")

        settings.set("provider:claude-cli", for: SettingsKeys.routingPrefix + "meeting.ask")
        let pinned = try #require(intelligence.askRoute())
        #expect(pinned == MeetingAskRoute(name: "Echo claude-cli", isLocal: false))
        #expect(pinned.disclosure.contains("sent there when you ask"))

        let gguf = FileManager.default.temporaryDirectory.appendingPathComponent("m16-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: gguf.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: gguf) }
        let installed = MeetingLocalLLMProvider(inner: LlamaCppProvider(config: LlamaCppConfig(modelPath: gguf), displayName: "Mini on this Mac"))
        let local = MeetingIntelligence()
        local.install(routing: table, settings: InMemorySettingsStore(), local: installed, embedder: HashingSentenceEmbedder())
        #expect(local.askRoute() == MeetingAskRoute(name: "Mini on this Mac", isLocal: true))
    }

    @Test func meetingStagesAreRoutableInSettings() {
        let ids = RoutableStage.all.map(\.id)
        #expect(ids.contains(.meetingNotes) && ids.contains(.meetingAsk))
        #expect(RoutableStage.all.last?.id == ProviderPlanner.stage)
    }

    // MARK: Detail view model

    @MainActor
    static func model(_ record: MeetingRecord, settings: InMemorySettingsStore = InMemorySettingsStore(),
                      ask: ((String, MeetingRecord, Bool) async throws -> MeetingAnswer)? = nil,
                      notes: any MeetingNotesProvider = ExtractiveNotesProvider()) -> (MeetingsSectionViewModel, MeetingStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-m18-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(root: root)
        _ = try? store.save(record)
        let vm = MeetingsSectionViewModel(store: store, settings: settings, calendarAuthorized: { false },
                                          list: { _ in (records: [record], unreadable: []) },
                                          capture: MeetingCaptureController(), notesProvider: notes,
                                          askRoute: { MeetingAskRoute(name: "Local", isLocal: true) }, ask: ask)
        return (vm, store)
    }

    static let record = MeetingRecord(id: "r1", title: "Sync", startedAt: Date(timeIntervalSince1970: 1_789_700_000),
                                      endedAt: Date(timeIntervalSince1970: 1_789_700_600), transcript: transcript,
                                      notes: ExtractiveNotesProvider.generate(transcript))

    @MainActor @Test func detailAsksAboutTheOpenMeeting() async throws {
        final class Box: @unchecked Sendable { var seen: (String, String, Bool)? }
        let box = Box()
        let (vm, _) = Self.model(Self.record, ask: { q, r, live in
            box.seen = (q, r.id, live)
            return MeetingAnswer(text: "Postgres [00:00].", citations: [0], route: "Local")
        })
        await vm.reload()
        await #expect(throws: MeetingAskError.nothingToSearch) { _ = try await vm.ask("x") }
        vm.open(id: "r1")
        let answer = try await vm.ask("What did we pick?")
        #expect(answer.citations == [0])
        #expect(box.seen?.0 == "What did we pick?" && box.seen?.1 == "r1" && box.seen?.2 == false)
        #expect(vm.isSelectedLive == false)
    }

    @MainActor @Test func transcriptSearchAndExportUseNames() async throws {
        let (vm, store) = Self.model(Self.record)
        try FileMeetingSpeakerNames(store: store).save(MeetingSpeakerNames([.others(1): "Sam"]), for: "r1")
        await vm.reload()
        vm.open(id: "r1")
        #expect(vm.lines.map(\.speaker) == ["You", "Sam"])
        vm.transcriptQuery = "sam"
        #expect(vm.visibleLines.map(\.text) == ["I'll write the migration plan."])
        let md = vm.markdown(for: Self.record)
        #expect(md.contains("**Sam** [00:04] I'll write the migration plan."))
    }

    @MainActor @Test func choosingATemplatePreparesNotesAgain() async throws {
        struct TemplateEcho: MeetingNotesProvider {
            let settings: InMemorySettingsStore
            let name = "t"
            func notes(for transcript: MeetingTranscript) async throws -> MeetingNotes {
                MeetingNotes(summary: [settings.string(MeetingNoteTemplate.settingsKey) ?? "auto"], actionItems: [], decisions: [], provider: "t")
            }
        }
        let settings = InMemorySettingsStore()
        let (vm, _) = Self.model(Self.record, settings: settings, notes: TemplateEcho(settings: settings))
        await vm.reload()
        vm.open(id: "r1")
        #expect(vm.noteTemplate == .auto)
        await vm.regenerateNotes(template: .interview)
        #expect(vm.noteTemplate == .interview)
        #expect(vm.notes?.summary == "interview")
    }
}
