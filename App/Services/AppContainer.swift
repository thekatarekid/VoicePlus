import Actions
import AppKit
import Engine
import Foundation
import Injection
import Lab
import Pipeline
import Providers
import Shared

/// P1.12 T1 — composition root. Builds the real stack once; every TCC-gated path is guarded so
/// `swift run VoicePlusApp` comes up without microphone / accessibility / input-monitoring.
///
///   engine (RealEngine | MockEngine) ─▶ DictationCoordinator ─▶ UtteranceLander
///        ▲ biasing (ContextHarvester → ShallowFusionBiaser)         ├─ PipelineRunner.standard (gatekeeper → formatter → style)
///                                                                    ├─ RepairSession (route repairCommand) → ReplaceRange (AX)
///                                                                    ├─ TextInjector (LiveSystemAccess, FocusGuard)
///                                                                    └─ ZeroEditTracker / history DB / recent words
public final class AppContainer {
    public let database: AppDatabase?
    public let flags: FeatureFlagService
    public let settings: SettingsStore
    /// The stable engine face every collaborator holds. Its *contents* change when a speech model
    /// lands (or disappears) — see `refreshEngineIfNeeded()`.
    public let engine: any EngineProtocol
    private let swappableEngine: SwappableEngine
    public private(set) var engineKind: EngineFactory.Kind
    public private(set) var audio: PipelineAudioSource?
    public private(set) var modelManager: ModelManager?
    public let system: SystemAccess
    public let injector: TextInjector
    public let pipeline: PipelineRunner
    public let repair: RepairSession
    public let biasing: BiasingController?
    public let recentWords: RecentWordsRing
    public let zeroEdit: ZeroEditTracker?
    public let egressGate: EgressGate
    public let routing: RoutingTable
    public let lander: UtteranceLander
    public let labRegistry: LabRegistry
    /// P2.3 / P2.4 / P2.6 / P2.5
    public let transform: TransformLanding
    public let snippets: any SnippetStoring
    public let personas: PersonaManager
    /// P1.5.2
    public let correction: CorrectionService
    /// P3 — timeline recorder + deixis/referent resolution + AX window text feed.
    public let deixis: DeixisService
    public let axWindowText: AXReaderWindowText
    /// P4 — act domain: catalogue + consent + executor + agent behind the second key.
    public let actState = ActDomainState()
    public let actHook: ActPreRouteHook
    public let consentEngine: ConsentEngine
    public let actionSystem: ActionSystem
    public let actRouter: ActRouter
    public let agentBackend: NativeAgentBackend
    public let connectorHub: ConnectorHub
    public let connectors: ConnectorRegistry
    /// P5 — hands-free gate (directed speech + speaker + mute), wake-verb pre-route, meetings.
    public let handsFree: HandsFreeController
    public let wakeVerb: WakeVerbPreRoute
    public let meeting: MeetingCoordinator
    /// P6 — personal adaptation loop, code-switching, encrypted sync.
    public let adaptation: AdaptationService?
    public let codeSwitch: CodeSwitchService
    public let sync: SyncService
    public let audioTap = UtteranceAudioTap()
    private var recognizerProvider: BiasingRecognizerProvider?
    /// Fired on the main queue after the engine has been replaced, so the shell can rebind the
    /// things that hang off the *audio pipeline* (waveform, mic-quality) rather than off the engine.
    public var onEngineChanged: ((AppContainer) -> Void)?
    private let environment: [String: String]
    private let refreshLock = NSLock()
    private var refreshingEngine = false
    private var zeroEditTimer: Timer?
    private var adaptTimer: Timer?

    public struct Options {
        public var environment: [String: String] = ProcessInfo.processInfo.environment
        public var database: AppDatabase?
        public var flags: FeatureFlagService?
        public var settings: SettingsStore?
        public var system: SystemAccess?
        public var discoverProviders = true
        public init() {}
    }

    /// Creates `~/Library/Application Support/VoicePlus` (+ Models) so every later path has a home.
    @discardableResult
    public static func ensureSupportDirectories() -> URL {
        let root = AppPaths.supportDirectory()
        for dir in [root, ModelCatalog.modelsRoot()] {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { Log.app.error("could not create \(dir.path): \(error)") }
        }
        return root
    }

    public static func build(options: Options = Options()) async -> AppContainer {
        ensureSupportDirectories()
        let database = options.database ?? (try? AppDatabase.open())
        let flags = options.flags ?? FeatureFlagService.local()
        let settings = options.settings ?? UserDefaultsSettingsStore()
        let built = await EngineFactory.make(environment: options.environment)
        let gate = EgressGate.shared
        gate.database = database
        let routing = options.discoverProviders
            ? await ProviderWiring.makeTable(database: database, flags: flags, gate: gate)
            : RoutingTable(providers: [LocalRulesProvider()], logger: InMemoryNetworkLogger())
        return AppContainer(database: database, flags: flags, settings: settings, built: built,
                            system: options.system ?? LiveSystemAccess(), gate: gate, routing: routing,
                            environment: options.environment)
    }

    init(database: AppDatabase?, flags: FeatureFlagService, settings: SettingsStore, built: EngineFactory.Built,
         system: SystemAccess, gate: EgressGate, routing: RoutingTable,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.database = database
        self.flags = flags
        self.settings = settings
        self.environment = environment
        let swappable = SwappableEngine(built.engine)
        self.swappableEngine = swappable
        self.engine = swappable
        self.engineKind = built.kind
        self.audio = built.audio
        self.modelManager = built.modelManager
        self.recognizerProvider = built.provider
        self.system = system
        self.egressGate = gate
        self.routing = routing

        // Injection (P1.8): AX → keystroke → adapter → paste, outcomes to the DB.
        let outcomes: InjectionOutcomeStore = database.map { DatabaseOutcomeStore(database: $0) } ?? InMemoryOutcomeStore()
        injector = TextInjector(system: system, registry: .standard(), store: outcomes)

        // Pipeline (P1.7): gatekeeper → register-routed formatter → style, providers behind the hook.
        let providerRouting = RoutingTableProviderRouting(table: routing, settings: settings)
        let styleStore: any StyleProfileStore = database.map { DatabaseStyleProfileStore(database: $0) } ?? InMemoryStyleProfileStore()
        // P2.6 snippets: exact-trigger pre-route ahead of every other rule, expansion first among stages.
        let snippetStore: any SnippetStoring = database.map { DatabaseSnippetStore(database: $0) } ?? InMemorySnippetStore()
        snippets = snippetStore

        // P6.1 — adaptation loop: corrections + post-dictation edits → training pairs →
        // personal lexicon (bias-list learning) → ranker source + regression guard stage.
        let adaptationService = try? AdaptationService()
        adaptation = adaptationService
        // P4.2 — the act hook runs first: while the second key holds the domain open (or a card
        // is pending) the utterance is a command, not text.
        // P5 — then "not you" (hands-free only) and the wake-verb grammar, then snippets.
        let actHook = ActPreRouteHook()
        self.actHook = actHook
        let handsFreeController = HandsFreeController(flags: flags)
        self.handsFree = handsFreeController
        let wakeVerbPre = WakeVerbPreRoute()
        self.wakeVerb = wakeVerbPre
        let guardStage = RegressionGuardStage(lexicon: { [weak adaptationService] in adaptationService?.loop.lexicon ?? PersonalLexicon() })
        let stages: [any PipelineStage] = [WakeVerbStage(preRoute: wakeVerbPre), SnippetStage(store: snippetStore), guardStage] + StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
            stage.id == .style ? StyleStage(store: styleStore) : stage
        }
        let gatekeeper = GatekeeperStage(local: PreRoutingClassifier(hooks: [actHook, handsFreeController, wakeVerbPre, SnippetPreRoute(store: snippetStore)]))
        pipeline = PipelineRunner(gatekeeper: gatekeeper, stages: stages, providers: providerRouting)

        // P2.5 personas: the same rows Settings edits, auto-drafted from style learnings.
        personas = PersonaManager(store: database.map { DatabasePersonaStore(database: $0) } ?? InMemoryPersonaStore(), styles: styleStore)

        // P2.1–P2.4: selection → transform (replace in place, 8 s warm window) / question (answer below).
        transform = TransformLanding(session: TransformSession(executor: TransformExecutor(providers: providerRouting),
                                                               sink: InjectionTransformReplaceSink(system: system)),
                                     detector: SystemAccessSelectionDetector(system: system),
                                     qa: QuestionAnswerStage(answerer: ProviderAnswerer(providers: providerRouting)),
                                     system: system, injector: injector)

        // Zero-edit counter (P1.11) over AX readback.
        let zeroEditTracker: ZeroEditTracker? = database.map { db in
            ZeroEditTracker(observer: AXFieldObserver(system: system)) { [weak adaptationService] outcome in
                do { try ZeroEditTracker.persist(outcome, to: db) } catch { Log.db.error("zero-edit persist failed: \(error)") }
                // P6.1 — an edited landing becomes a training pair; a clean one still counts.
                if outcome.edited, let final = outcome.finalText {
                    adaptationService?.ingestEdit(utteranceID: outcome.utteranceID, original: outcome.originalText, edited: final)
                } else if !outcome.edited {
                    adaptationService?.recordCleanLanding(text: outcome.originalText)
                }
            }
        }
        zeroEdit = zeroEditTracker

        // Biasing (P1.5, Bet 2): harvest AX text / recent words / corrections / contacts when the flag is on.
        // P3.4: the AX source now reads through AXWindowReader + WindowContentCache (deep text,
        // scrollback-capable, observer-invalidated) instead of the shallow live walker.
        recentWords = RecentWordsRing()
        let axWindowText = AXReaderWindowText(system: system)
        self.axWindowText = axWindowText
        let harvester = ContextHarvester(sources: [
            AXTreeSource(provider: axWindowText),
            recentWords,
            CodeSymbolSource(provider: LiveAXOpenDocuments()),
            ContactsSource(provider: LiveContacts()),
        ])
        if let database { harvester.add(CorrectionSource(store: DatabaseCorrectionStore(database: database))) }
        if let adaptationService { harvester.add(LearnedLexiconSource(loop: adaptationService.loop)) }
        biasing = BiasingController(harvester: harvester, vocabulary: BiasVocabulary.discoverParakeet(), flags: flags)

        // Voice repair (P1.6, Bet 3): AX replace-range + correction log + zero-edit decrement.
        let dictionary = (try? database?.dictionaryTerms().map(\.term)) ?? []
        let correctionFanout = CompositeCorrectionSink(sinks: [database.map { DatabaseCorrectionSink(database: $0) },
                                                               adaptationService.map { AdaptationCorrectionSink(service: $0) }].compactMap { $0 })
        repair = RepairSession(replaceSink: InjectionReplaceRangeSink(system: system),
                               correctionSink: correctionFanout,
                               zeroEditSink: DatabaseZeroEditSink(database: database),
                               enricher: AlternateEnricher(userDictionary: dictionary))

        // P1.5.2: dual-path reconciler over the same AX replace-range + value readback.
        audio?.utteranceTap = audioTap
        correction = CorrectionService(ledger: CorrectionLedger(), flags: flags, settings: settings,
                                       readback: InjectionDocumentReadback(system: system),
                                       replaceSink: InjectionReplaceRangeSink(system: system),
                                       recognizers: built.provider.map { ProviderDualPathRecognizers(provider: $0) },
                                       samples: { [audioTap] in audioTap.samples })
        correction.correctionLog = correctionFanout

        // P3 — deixis service over the live AX hit-tester; referents from AX artifacts + contacts.
        let deixis = DeixisService(hitTester: LiveAXHitTester())
        deixis.windowText = { [weak axWindowText] in axWindowText?.windowText() }
        let referentContext = AXReferentContext(text: axWindowText, contacts: LiveContacts())
        deixis.participants = referentContext
        deixis.artifacts = referentContext
        self.deixis = deixis

        lander = UtteranceLander(pipeline: pipeline, injector: injector, system: system, repair: repair, flags: flags,
                                 database: database, zeroEdit: zeroEditTracker, recentWords: recentWords)
        lander.personaManager = personas
        lander.transform = transform
        lander.correction = correction
        lander.contextAugmenter = { [weak deixis] spans, ctx in deixis?.augment(spans, ctx) ?? ctx }
        // P6.3 — script-aware final text + pill indicator; P6.4 — sync service.
        let codeSwitchService = CodeSwitchService(router: built.codeSwitch)
        codeSwitch = codeSwitchService
        sync = SyncService(database: database, snippets: snippetStore, settings: settings)
        lander.textFinalizer = { [weak codeSwitchService] spans in codeSwitchService?.finalize(spans) }
        lander.actClaimConsumer = { [weak actHook, weak handsFreeController] in
            let act = actHook?.consumeClaim() ?? false
            let notYou = handsFreeController?.consumeClaim() ?? false
            return act || notYou
        }

        // P4 — deterministic action layer + consent + agent, all over one AX action system.
        // catalog.json resolves from the source tree in dev and from Contents/Resources in the
        // bundle (make_app.sh copies it); an empty catalogue still boots (agent-only).
        let actionSystem: ActionSystem = LiveActionSystem()
        self.actionSystem = actionSystem
        let catalog: ActionCatalog
        do { catalog = try ActionCatalog.load() } catch {
            Log.app.error("action catalog missing: \(error)")
            catalog = ActionCatalog(entries: [])
        }
        let consent = ConsentEngine()
        consentEngine = consent
        let executor = ActionExecutor(system: actionSystem)
        let agent = NativeAgentBackend(planner: ProviderPlanner(providers: providerRouting),
                                       executor: executor, consent: consent)
        agentBackend = agent
        let parser = ActIntentParser(catalog: catalog, activation: actState)
        actRouter = ActRouter(parser: parser, consent: consent, executor: executor, agent: agent)
        actHook.parser = parser

        // P4.6 — connectors: Keychain tokens, loopback OAuth, every call → Data Panel.
        let hub = ConnectorHub(log: { record in
            guard let database else { return }
            do { _ = try database.insert(record) } catch { Log.db.error("connector log failed: \(error)") }
        })
        connectorHub = hub
        connectors = hub.registry()

        // P5.5 — meeting capture: detector-driven session over the engine's recognizer (or a
        // silent transcriber under the mock engine); live mic+system capture only when real.
        // `settings` carries the opt-in: with it absent (or off) the coordinator starts nothing
        // and asks for nothing — see MeetingCoordinator.startMonitoring().
        let meetingCoordinator = MeetingCoordinator(settings: settings)
        let meetingStore = meetingCoordinator.store
        meeting = meetingCoordinator

        labRegistry = LabWiring.registry(modelManager: built.modelManager, repair: repair, biasing: biasing)

        zeroEditTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak zeroEditTracker] _ in
            zeroEditTracker?.poll()
        }
        adaptTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak adaptationService] _ in
            adaptationService?.retrainIfNeeded()
        }
        // Both read through `self`, so they must be installed after every stored property exists.
        // Reading the *current* provider/kind rather than capturing `built`'s is the point: a
        // container that came up without a model gains both when the download lands.
        meetingCoordinator.makeSession = { [weak self] prompt in
            let transcriber: any MeetingTranscriber = (self?.recognizerProvider).flatMap { p in
                ProviderMeetingTranscriber(resolve: { try await p.resolve().final })
            } ?? SilentMeetingTranscriber()
            return MeetingSession(title: prompt.title, event: prompt.event, transcriber: transcriber,
                                  labeler: DiarizationFactory.make(enrolledUserEmbedding: nil), store: meetingStore)
        }
        meetingCoordinator.makeCapture = { [weak self] in
            guard let self, case .real = self.engineKind else { return nil }
            return DualCapture(mic: CoreAudioCaptureSource(), system: SystemAudioRecorder.live(),
                               micVAD: EnergyVAD(), systemVAD: EnergyVAD())
        }
        Log.app.info("container up: engine=\(String(describing: built.kind)) db=\(database != nil) providers=\(routing.allProviders.count)")
        warmUpEngine()
    }

    /// Loads the speech model into memory in the background, as soon as there is one.
    ///
    /// Called at launch and again whenever a download lands and the engine is swapped in. Before
    /// this, the CoreML compile happened lazily inside the user's *first* `start()`: the notch sat on
    /// "Warming up…" for as long as that took, with no progress and no end in sight. Deliberately
    /// silent — it publishes no engine state, so nothing appears on screen for work nobody asked for.
    public func warmUpEngine() {
        guard case .real = engineKind else { return }
        let engine = swappableEngine.current
        guard let real = engine as? RealEngine, !real.isModelLoaded else { return }
        Task.detached(priority: .utility) { await real.preloadModel() }
    }

    /// Called at hotkey-down: refresh the decoder's bias list from the current screen/context.
    public func prepareForUtterance() {
        guard let recognizerProvider, let biasing else { return }
        let biaser = biasing.makeBiaser()
        recognizerProvider.install(biaser)
        if let biaser { Log.engine.debug("biasing: \(biaser.tree.entryCount) entries in \(String(format: "%.1f", biasing.lastBuildMs)) ms") }
    }

    /// Re-resolve the recognizer and swap the engine if what is on disk no longer matches what the
    /// app is running.
    ///
    /// This is the fix for the 1.7.0 "downloaded a model, dictation still says no model" bug: the
    /// engine used to be resolved once, at launch, and a fresh install necessarily launches with no
    /// model. Cheap enough to call on every hotkey-down — the precheck is
    /// `RecognizerFactory.chooseFinal`, i.e. a couple of `FileManager` lookups — and the expensive
    /// rebuild only runs when availability actually flipped.
    ///
    /// Both directions are handled: unavailable → real when a download lands, and real →
    /// unavailable when the models directory is emptied under a running app.
    public func refreshEngineIfNeeded() async {
        // The mock engine is an explicit developer opt-in; never take it away from them.
        if case .mock = engineKind { return }
        guard let modelManager else { return }
        let begin = refreshLock.withLock { () -> Bool in
            if refreshingEngine { return false }
            refreshingEngine = true
            return true
        }
        guard begin else { return }
        defer { refreshLock.withLock { refreshingEngine = false } }

        let choice = await RecognizerFactory.chooseFinal(manager: modelManager)
        switch Self.refreshDecision(kind: engineKind, canRecognize: choice != nil) {
        case .activate:
            let built = await EngineFactory.make(environment: environment, manager: modelManager)
            guard case .real = built.kind else { return }  // raced with a deletion; stay honest
            Log.engine.notice("speech model became available — swapping in \(String(describing: built.kind))")
            await apply(built)
        case .deactivate:
            Log.engine.notice("speech model disappeared — dictation is off until one is installed")
            await apply(EngineFactory.makeUnavailable(manager: modelManager))
        case .none:
            return
        }
    }

    /// What a refresh should do, given what the app is running and what is on disk. Pure so the
    /// rule can be tested without a microphone: only an *availability flip* swaps the engine.
    /// A real engine that gains a better model re-resolves inside `RealEngine` (provider revision),
    /// and the mock engine is a developer opt-in that nothing may take away.
    public enum RefreshDecision: Equatable, Sendable { case none, activate, deactivate }

    public static func refreshDecision(kind: EngineFactory.Kind, canRecognize: Bool) -> RefreshDecision {
        switch kind {
        case .mock: return .none
        case .unavailable: return canRecognize ? .activate : .none
        case .real: return canRecognize ? .none : .deactivate
        }
    }

    /// Installs a freshly built engine and everything that hangs off it. Swapping cancels any
    /// utterance in flight, so nothing half-recognised lands (`SwappableEngine.swap`).
    private func apply(_ built: EngineFactory.Built) async {
        await swappableEngine.swap(to: built.engine)
        engineKind = built.kind
        audio = built.audio
        audio?.utteranceTap = audioTap
        recognizerProvider = built.provider
        correction.recognizers = built.provider.map { ProviderDualPathRecognizers(provider: $0) }
        codeSwitch.setRouter(built.codeSwitch)
        // A model that just finished downloading is loaded now, not on the press that follows it.
        warmUpEngine()
        let container = self
        await MainActor.run { container.onEngineChanged?(container) }
    }

    public var activeModelName: String {
        switch engineKind {
        case .mock(let fixture): return "Mock engine (\(fixture))"
        case .real(let recognizer): return recognizer
        case .unavailable(let reason): return reason
        }
    }

    public var microphoneName: String { audio?.deviceName ?? "Default microphone" }

    /// Onboarding / Settings dependencies over the live services.
    public func onboardingDependencies(permissions: PermissionChecking) -> OnboardingDependencies {
        let installer = modelManager.map { manager -> ModelStackInstaller in
            let tiers = ModelStackInstaller(manager: manager)
            // The moment a model lands, the engine stops being `UnavailableEngine`. Without this
            // the download finishes, onboarding says "Using Parakeet TDT 0.6B v3." and every
            // dictation still reports "No speech model installed" until the app is relaunched.
            tiers.onModelsChanged = { [weak self] in
                Task { await self?.refreshEngineIfNeeded() }
            }
            return tiers
        }
        let models: ModelManaging = installer ?? OnboardingMockModelManager()
        // Always a real capture graph. Reuse the app's pipeline when one exists; otherwise build a
        // standalone one — metering a microphone needs no ASR model, and onboarding is precisely
        // the moment when no model is installed yet. There is deliberately no engine-derived
        // fallback: that was the path that let a silent user pass "Say something." on a fixture.
        let micLevel: MicLevelPublishing = audio.map { PipelineMicLevelPublisher(audio: $0) }
            ?? PipelineMicLevelPublisher.standalone()
        Log.app.info("onboarding mic meter: \(audio != nil ? "shared audio pipeline" : "standalone capture graph") (real capture)")
        var dependencies = OnboardingDependencies(
            permissions: LivePermissionChecker(checker: permissions),
            micLevel: micLevel,
            models: models,
            engine: engine,
            database: database,
            flags: flags,
            contacts: SystemContactsStore(),
            settingsStore: settings,
            openProvidersSettings: { [weak self] in
                guard let self else { return }
                Task { @MainActor in SettingsWindowController.show(dependencies: self.onboardingDependencies(permissions: permissions), tab: .models, connectedProviders: self.connectedProviderNames) }
            }
        )
        dependencies.prepareEngine = { [weak self] in await self?.refreshEngineIfNeeded() }
        return dependencies
    }

    public var connectedProviderNames: [String] {
        routing.allProviders.filter { $0.id != routing.fallback.id }.map(\.id.rawValue)
    }
}
