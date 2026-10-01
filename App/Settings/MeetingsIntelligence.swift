import Engine
import Foundation
import Pipeline
import Providers
import Shared

// MARK: - V5 M17 / M16+M21 / M18 · meeting notes, Ask and named export wiring
//
// - `MeetingLocalLLMProvider`: the on-device default for `meeting.notes` / `meeting.ask` — D2's
//   llama.cpp runtime and GGUF (the slot CU8's planner model takes later), same `ModelResidency` key
//   and shared engine as cleanup, with a meeting-sized deadline and token cap. It serves only
//   `meeting.*` stages, so cleanup's 500 ms path never waits on it.
// - `RoutingMeetingGenerator`: every generation goes through `RoutingTable` (§10). A provider pinned
//   for the stage (`routing.meeting.notes` / `routing.meeting.ask` = `provider:<id>` — Ollama,
//   LM Studio, claude/codex CLI, ChatGPT OAuth, a BYO key) is tried first; otherwise the local model.
//   The rules fallback "completing" means no model ran → `.notConfigured` (notes go extractive).
// - `MeetingIntelligence.shared`: installed once by the composition root; hands the notes provider to
//   `MeetingSession`, the asker and route to the detail view, and speaker names to export.

/// On-device model for meeting stages, over the same GGUF/engine/residency key as cleanup.
public final class MeetingLocalLLMProvider: TextGenerator, @unchecked Sendable {
    public static let providerID: ProviderID = "local.llamacpp.meetings"
    /// Notes over a 7 k-character part and an answer over 8 windows both finish well inside this.
    public static let deadline: TimeInterval = 120
    public static let maxTokens = 1_024

    public let id: ProviderID = MeetingLocalLLMProvider.providerID
    public let capabilities: ProviderCapabilities = [.pipeline]
    public let costClass: CostClass = .free
    public let privacyClass: PrivacyClass = .onDevice
    public let inner: LlamaCppProvider
    public var displayName: String { inner.displayName }

    public init(inner: LlamaCppProvider) { self.inner = inner }

    public convenience init(model: LocalLLMModel = CleanupWiring.model, residency: ModelResidency = .shared,
                            plan: ResidencyPlan = ResidencyPlanStore.shared.plan) {
        self.init(inner: LlamaCppProvider(
            config: LlamaCppConfig(modelPath: model.localURL(), residencyKey: ResidencyKey.cleanup,
                                   tier: plan.tier(for: .cleanup) ?? .onDemand, estimatedBytes: model.residentBytes,
                                   maxTokens: Self.maxTokens, deadline: Self.deadline),
            displayName: "\(model.displayName) on this Mac", residency: residency))
    }

    public static func serves(_ stage: StageID) -> Bool { stage.rawValue.hasPrefix("meeting.") }

    public func isAvailable() async -> Bool { await inner.isAvailable() }

    /// Synchronous check for the route disclosure: runtime linked and GGUF on disk.
    public var isInstalled: Bool {
        LlamaCppEngine.runtimeAvailable && FileManager.default.fileExists(atPath: inner.config.modelPath.path)
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws
        -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        guard Self.serves(stage) else { throw ProviderError.unavailable("meeting stages only") }
        return try await inner.generate(prompt: prompt, system: system, stage: stage)
    }
}

/// `MeetingTextGenerating` over `RoutingTable`.
public final class RoutingMeetingGenerator: MeetingTextGenerating, @unchecked Sendable {
    public let table: RoutingTable
    private let settings: SettingsStore
    private let stage: StageID
    private let localID: ProviderID

    public init(table: RoutingTable, settings: SettingsStore, stage: StageID,
                localID: ProviderID = MeetingLocalLLMProvider.providerID) {
        self.table = table; self.settings = settings; self.stage = stage; self.localID = localID
    }

    /// The provider pinned for the stage, if any.
    var pinned: ProviderID? {
        guard case .provider(let id)? = settings.string(SettingsKeys.routingPrefix + stage.rawValue)
            .flatMap(ProviderChoice.init(rawValue:)) else { return nil }
        return ProviderID(rawValue: id)
    }

    /// The provider a question/notes request goes to first.
    public var routeProvider: (any Provider)? { table.provider(pinned ?? localID) }

    public var routeName: String { routeProvider?.displayName ?? pinned?.rawValue ?? "Local model" }

    public func generate(stage: StageID, system: String, user: String) async throws -> String {
        var ctx = StageContext()
        ctx.extra[PromptBuilder.systemOverrideKey] = system
        ctx.extra[PromptBuilder.userOverrideKey] = user
        table.setChoice(.provider(pinned ?? localID), for: stage)
        let span = TranscriptSpan(text: user, confidence: 1, audioRange: 0...0, provenance: [.asr])
        let outcome: RouteOutcome
        do {
            outcome = try await table.complete(stage: stage, spans: [span], context: ctx, purpose: "meetings:\(stage.rawValue)")
        } catch {
            throw MeetingGenerationError.transient("\(error)")
        }
        guard outcome.provider != table.fallback.id else { throw Self.classify(outcome.attempts.map(\.1)) }
        return outcome.completion.spans.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Why no model completed: a retryable failure anywhere wins; then a hard one; else nothing configured.
    static func classify(_ errors: [ProviderError?]) -> MeetingGenerationError {
        var permanent: String?
        for case let e? in errors {
            switch e {
            case .timeout, .malformedResponse: return .transient("\(e)")
            case .http(let code, _) where code == 429 || code >= 500: return .transient("\(e)")
            case .unauthorized, .capabilityMissing, .http: permanent = permanent ?? "\(e)"
            case .unavailable, .cancelled, .flagDisabled: continue
            }
        }
        return permanent.map(MeetingGenerationError.permanent) ?? .notConfigured
    }
}

/// Holds the routing table and settings the meeting features run on. Installed once at launch.
public final class MeetingIntelligence: @unchecked Sendable {
    public static let shared = MeetingIntelligence()

    private let lock = NSLock()
    private var routing: RoutingTable?
    private var settings: SettingsStore?
    private var asker: MeetingAsker?
    private var libraryAsker: MeetingLibraryAsker?
    private var local: MeetingLocalLLMProvider?
    public var names: any MeetingSpeakerNameSource = FileMeetingSpeakerNames()

    public init() {}

    /// Registers the local meeting model in `routing` and keeps both for the meeting features.
    public func install(routing: RoutingTable, settings: SettingsStore,
                        local: MeetingLocalLLMProvider = MeetingLocalLLMProvider(),
                        embedder: any SentenceEmbedding = NLSentenceEmbedder()) {
        routing.register(local)
        let generator = RoutingMeetingGenerator(table: routing, settings: settings, stage: .meetingAsk)
        let asker = MeetingAsker(generator: generator, embedder: embedder)
        let libraryAsker = MeetingLibraryAsker(generator: generator, embedder: embedder)   // V5 M19
        lock.withLock {
            self.routing = routing
            self.settings = settings
            self.local = local
            self.asker = asker
            self.libraryAsker = libraryAsker
        }
    }

    public var isInstalled: Bool { lock.withLock { routing != nil } }

    /// The routing table and settings installed at launch (V5 M22 picker, M23 MCP).
    public var routingTable: RoutingTable? { lock.withLock { routing } }
    public var settingsStore: SettingsStore? { lock.withLock { settings } }

    /// M17 — LLM notes over `meeting.notes` with the chosen template; extractive until installed.
    public func notesProvider(store: MeetingStore = MeetingStore()) -> any MeetingNotesProvider {
        guard let (routing, settings) = lock.withLock({ () -> (RoutingTable, SettingsStore)? in
            guard let r = self.routing, let s = self.settings else { return nil }
            return (r, s)
        }) else { return ExtractiveNotesProvider() }
        let box = SettingsBox(settings)
        return LLMNotesProvider(generator: RoutingMeetingGenerator(table: routing, settings: settings, stage: .meetingNotes),
                                template: { box.template })
    }

    /// The template the next notes use (`meeting.notes.template`, default Auto).
    public var template: MeetingNoteTemplate {
        get { lock.withLock { settings }.map { SettingsBox($0).template } ?? .auto }
        set { lock.withLock { settings }?.set(newValue.rawValue, for: MeetingNoteTemplate.settingsKey) }
    }

    /// M16/M21 — where Ask sends a question, disclosed before use; nil when nothing can answer
    /// (no provider pinned and the local model is not installed).
    public func askRoute() -> MeetingAskRoute? {
        guard let (routing, settings, local) = lock.withLock({ () -> (RoutingTable, SettingsStore, MeetingLocalLLMProvider?)? in
            guard let r = self.routing, let s = self.settings else { return nil }
            return (r, s, self.local)
        }) else { return nil }
        let generator = RoutingMeetingGenerator(table: routing, settings: settings, stage: .meetingAsk)
        if let pinned = generator.pinned {
            guard let p = routing.provider(pinned) else { return nil }
            return MeetingAskRoute(name: p.displayName, isLocal: p.privacyClass != .cloud)
        }
        guard let local, local.isInstalled else { return nil }
        return MeetingAskRoute(name: local.displayName, isLocal: true)
    }

    public func ask(_ question: String, about record: MeetingRecord, live: Bool) async throws -> MeetingAnswer {
        guard let asker = lock.withLock({ asker }) else { throw MeetingAskError.generation(.notConfigured) }
        return try await asker.ask(question, about: record, names: names.names(for: record.id), live: live)
    }

    /// V5 M19 — Ask across every meeting in `records` (the library as listed, live one included).
    public func askAcross(_ question: String, over records: [MeetingRecord], liveID: String?) async throws -> MeetingLibraryAnswer {
        guard let asker = lock.withLock({ libraryAsker }) else { throw MeetingAskError.generation(.notConfigured) }
        let source = names
        var byID: [String: MeetingSpeakerNames] = [:]
        for r in records { byID[r.id] = source.names(for: r.id) }
        return try await asker.ask(question, over: records, names: byID, liveID: liveID)
    }

    /// V5 M19/M23 — the library ranking without a model (MCP `search`).
    public func search(_ query: String, over records: [MeetingRecord], k: Int = MeetingRetrieval.topK) async -> [MeetingLibraryExcerpt] {
        let index = lock.withLock({ libraryAsker?.index }) ?? fallbackIndex
        let source = names
        var byID: [String: MeetingSpeakerNames] = [:]
        for r in records { byID[r.id] = source.names(for: r.id) }
        await index.refresh(records, names: byID)
        return await index.search(query, k: k)
    }

    /// Used by `search` before `install` (the MCP stdio process never installs a model).
    private let fallbackIndex = MeetingLibraryIndex(embedder: NLSentenceEmbedder())

    public func refreshLive(_ record: MeetingRecord) async {
        guard let asker = lock.withLock({ asker }) else { return }
        await asker.refreshLive(record, names: names.names(for: record.id))
    }

    /// Markdown for Export… — names from M13, ticked action items.
    public func markdown(for record: MeetingRecord, completed: Set<String>) -> String {
        MeetingMarkdownExport.markdown(record, names: names.names(for: record.id), completed: completed)
    }
}

/// Reads settings from `@Sendable` closures (the store is a reference type read on any thread).
struct SettingsBox: @unchecked Sendable {
    let settings: SettingsStore
    init(_ settings: SettingsStore) { self.settings = settings }
    var template: MeetingNoteTemplate {
        settings.string(MeetingNoteTemplate.settingsKey).flatMap(MeetingNoteTemplate.init(rawValue:)) ?? .auto
    }
}

/// Composition-root entry point.
public enum MeetingIntelligenceWiring {
    @MainActor
    public static func install(routing: RoutingTable, settings: SettingsStore) {
        MeetingIntelligence.shared.install(routing: routing, settings: settings)
    }
}

// MARK: M18 — transcript lines with names

public extension MeetingTranscriptLine {
    /// Lines with M13 names in place of "You" / "Others 2" where known; search matches the names.
    static func lines(_ transcript: MeetingTranscript, names: MeetingSpeakerNames) -> [MeetingTranscriptLine] {
        guard !names.isEmpty else { return lines(transcript) }
        return transcript.utterances.enumerated().map { index, utterance in
            MeetingTranscriptLine(id: index, start: utterance.range.lowerBound, speaker: names.name(for: utterance.speaker),
                                  text: utterance.text, isUncertain: utterance.confidence < uncertainBelow)
        }
    }
}
