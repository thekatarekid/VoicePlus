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
///        ▲ boosting (Dictionary + corrections → CTC booster)         ├─ PipelineRunner.standard (gatekeeper → formatter → style)
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
    /// V5 B1 — per-utterance CTC vocabulary boosting (replaces decode-time shallow fusion, A1).
    public let boosting: BoostingController?
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
    /// V5 B2 + E1 — the ranked context, rebuilt per utterance, as `StageContext.extra["context.prompt"]`.
    public let contextPrompt: ContextPromptSession
    /// P4 — act domain: catalogue + consent + executor + agent behind the second key.
    public let actState = ActDomainState()
    public let actHook: ActPreRouteHook
    public let consentEngine: ConsentEngine
    public let actionSystem: ActionSystem
    public let actRouter: ActRouter
    public let agentBackend: NativeAgentBackend
    public let connectorHub: ConnectorHub
    public let connectors: ConnectorRegistry
    /// P5 — the latch gate (directed speech + speaker + mute), wake-verb pre-route, meetings.
    public let latchController: LatchController
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
    /// FX3 — one engine refresh at a time, and a caller that arrives mid-refresh waits for it.
    private let refreshGate = RefreshGate()
    private var zeroEditTimer: Timer?
    private var adaptTimer: Timer?
    /// V4.7 — re-prewarms the capture graph when the input route changes (see `startBackgroundWork`).
    private var deviceMonitor: AudioDeviceMonitor?
    private var devicePrewarm: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?
    /// V5 C1 — Settings › Voice changed the capture enhancement: rebuild the engine's capture graph.
    private var captureEnhancementObserver: NSObjectProtocol?

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
        // V4.8 — the model store's maintenance pass (layout migration + parked sweep, under a
        // cross-process lock) is no longer on this path. `.deferred` leaves it for
        // `startBackgroundWork()`, which the app calls once it is wired and the hotkey is live.
        let manager = EngineFactory.mockFixtureName(environment: options.environment) == nil
            ? ModelManager(maintenance: .deferred) : nil
        let built = await EngineFactory.make(environment: options.environment, manager: manager)
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
        ITNWiring.install(environment: environment)   // V5 D1 + K7 — NeMo ITN, LANG locale, preview == final
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
        // P5 — then "not you" (only while latched) and the wake-verb grammar, then snippets.
        let actHook = ActPreRouteHook()
        self.actHook = actHook
        let latchController = LatchController(flags: flags)
        self.latchController = latchController
        let wakeVerbPre = WakeVerbPreRoute()
        self.wakeVerb = wakeVerbPre
        let guardStage = RegressionGuardStage(lexicon: { [weak adaptationService] in adaptationService?.loop.lexicon ?? PersonalLexicon() })
        // R4.2 — `FieldRolePipeline` puts `FieldRoleFormatterStage` *in place of* the five
        // register-routed formatters (it runs one of them itself, chosen by the field role, so
        // keeping both would format the same spans twice). Everything else keeps its position.
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
            stage.id == .style ? DictionaryWiring.styleStage(store: styleStore) : stage   // V5 P5 entity guard
        }
        let stages: [any PipelineStage] = TurnTraceWiring.traced(   // V5 I3 per-stage diff, in memory (last 20 turns)
            [WakeVerbStage(preRoute: wakeVerbPre), SnippetStage(store: snippetStore), guardStage]
            + FieldRolePipeline.replacingFormatters(in: CleanupWiring.inserting(   // V5 D2 cleanup LLM, before style
                CleanupWiring.stage(routing: routing, settings: settings), into: builtIn)))
        let gatekeeper = GatekeeperStage(local: PreRoutingClassifier(hooks: [actHook, latchController, wakeVerbPre, SnippetPreRoute(store: snippetStore)]))
        pipeline = PipelineRunner(gatekeeper: gatekeeper, stages: stages, providers: providerRouting)

        // P2.5 personas: the same rows Settings edits, auto-drafted from style learnings.
        let personaManager = PersonaManager(store: database.map { DatabasePersonaStore(database: $0) } ?? InMemoryPersonaStore(), styles: styleStore)
        personas = personaManager
        // V5 F1 — every closed landing teaches the app's style; auto-drafted personas follow it.
        let personaLearning = PersonaLearningLoop(personas: personaManager)

        // P2.1–P2.4: selection → transform (replace in place, 8 s warm window) / question (answer below).
        transform = TransformLanding(session: TransformSession(executor: TransformExecutor(providers: providerRouting),
                                                               sink: InjectionTransformReplaceSink(system: system)),
                                     detector: SystemAccessSelectionDetector(system: system),
                                     qa: QuestionAnswerStage(answerer: ProviderAnswerer(providers: providerRouting)),
                                     system: system, injector: injector)

        // Zero-edit counter (P1.11) over AX readback.
        let zeroEditTracker: ZeroEditTracker? = database.map { db in
            ZeroEditTracker(observer: AXFieldObserver(system: system)) { [weak adaptationService, personaLearning] outcome in
                do { try ZeroEditTracker.persist(outcome, to: db) } catch { Log.db.error("zero-edit persist failed: \(error)") }
                personaLearning.observe(original: outcome.originalText, fieldValue: outcome.edited ? outcome.finalText : nil,
                                        bundleID: outcome.field.appBundleID)
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
        DictionaryWiring.install(harvester: harvester, windowText: axWindowText)   // V5 P1/P2/P7 public dictionaries
        boosting = BoostingWiring.controller(database: database, adaptation: adaptationService, modelManager: built.modelManager)
        // V5 B2 (X2) — the ranked list now has a caller: one session over the same harvester.
        contextPrompt = ContextPromptSession(harvester: harvester, idleDiscardAfter: 120)

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
        // S7d — the app's Dictionary & Apps rule applies last: Verbatim switches the style pass and
        // writing instructions off; contextual reading off drops what was read from the screen.
        // V5 B2 — then the ranked-context prompt for the cleanup stage (D2), after the rule.
        lander.contextAugmenter = ContextPromptAugmenter.applying(
            after: AppRules.applying(after: { [weak deixis] spans, ctx in deixis?.augment(spans, ctx) ?? ctx }),
            session: contextPrompt)
        // R4.2 — the AX hints the field-role formatter classifies on, read once per utterance.
        let fieldContextReader = FieldContextReader(system: system)
        lander.fieldContextProvider = { [fieldContextReader] bundleID in fieldContextReader.fieldContext(bundleID: bundleID) }
        // P6.3 — script-aware final text + pill indicator; P6.4 — sync service.
        let codeSwitchService = CodeSwitchService(router: built.codeSwitch)
        codeSwitch = codeSwitchService
        sync = SyncService(database: database, snippets: snippetStore, settings: settings)
        lander.textFinalizer = { [weak codeSwitchService] spans in codeSwitchService?.finalize(spans) }
        lander.actClaimConsumer = { [weak actHook, weak latchController] in
            let act = actHook?.consumeClaim() ?? false
            let notYou = latchController?.consumeClaim() ?? false
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
        // ── S12 · outbound action preview (design §8.8) ─────────────────────────────────────────
        // Sends, posts and submits wait behind the preview card (destination + proposed action)
        // instead of running first with an undo toast. Nothing sends because text was inserted.
        let previewedCatalog = ActionPreviewPolicy.previewingOutbound(catalog)
        // Selected-text transforms (R1): the edited preview dwells as long as Settings' preview
        // dwell, read per turn, before the target is revalidated and replaced. "Until I insert"
        // (manual) replaces nothing on time: the pill draws Replace text / Cancel and waits.
        transform.previewDwell = { [settings] in
            TransformPreviewDwell.fromSetting(seconds: TurnSettings.previewDwell(settings).seconds)
        }
        // ── end S12 ─────────────────────────────────────────────────────────────────────────────
        let consent = ConsentEngine()
        consentEngine = consent
        let executor = ActionExecutor(system: actionSystem)
        let agent = NativeAgentBackend(planner: ProviderPlanner(providers: providerRouting),
                                       executor: executor, consent: consent)
        agentBackend = agent
        let parser = ActIntentParser(catalog: previewedCatalog, activation: actState)   // S12
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

        labRegistry = LabWiring.registry(modelManager: built.modelManager, repair: repair, boosting: boosting)

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
            // V5 O1 — the meeting's mic leg is a recorder on the app's one capture graph, never a
            // second HAL client: dictation during a meeting and the meeting both hear the same audio.
            let mic = SharedMicrophoneSource(recorder: .meeting, audio: { [weak self] in self?.audio })
            return DualCapture(mic: mic, system: SystemAudioRecorder.live(),
                               micVAD: EnergyVAD(), systemVAD: EnergyVAD())
        }
        Log.app.info("container up: engine=\(String(describing: built.kind)) db=\(database != nil) providers=\(routing.allProviders.count)")
        // V4.7 — the kept capture graph is fully released on hard mute and on quit; everything
        // else only pauses it between turns. Unmuting prepares it again (microphone still closed).
        // Transitions only: the mute controller also notifies on every processing / directed
        // change (each turn), and `observe` replays the current state at once.
        let muteEdge = MuteEdge(muted: latchController.mute.isMuted)
        latchController.mute.observe { [weak self] model in
            guard let self, let muted = muteEdge.change(to: model.muted) else { return }
            if muted {
                // V5 O1 — hard mute closes the microphone for every subscriber: a meeting recording
                // on the shared graph ends first, then the graph itself is released.
                if self.meeting.session != nil { self.meeting.apply(.recordingStopped) }
                self.releaseCapture(.mute)
            } else {
                DispatchQueue.main.async { [weak self] in self?.prewarmCapture() }
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseCapture(.quit) }
        captureEnhancementObserver = NotificationCenter.default.addObserver(
            forName: CaptureEnhancement.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { await self?.rebuildEngineForCaptureChange() } }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        if let captureEnhancementObserver { NotificationCenter.default.removeObserver(captureEnhancementObserver) }
        deviceMonitor?.stop()
    }

    /// V4.6–V4.8 — the work the launch path must not wait for, started once the app is wired and
    /// the hotkey is live: the model store's maintenance pass (detached, still under its
    /// cross-process lock), the model preload and the capture-graph prewarm, and the route watcher
    /// that prepares the graph again after a device change.
    public func startBackgroundWork() {
        modelManager?.startMaintenance()
        warmUpEngine()
        guard case .real = engineKind, deviceMonitor == nil else { return }
        let monitor = AudioDeviceMonitor()
        monitor.onDefaultInputChanged = { [weak self] _ in self?.scheduleDevicePrewarm() }
        monitor.onDeviceListChanged = { [weak self] _ in self?.scheduleDevicePrewarm() }
        monitor.start()
        deviceMonitor = monitor
    }

    /// Loads the speech model into memory in the background, as soon as there is one, then prepares
    /// the capture graph (V4.7): AUHAL pinned, formats synced, tap installed, engine prepared — and
    /// the microphone still closed, so the first press is one `engine.start()`.
    ///
    /// Called from `startBackgroundWork()` and again whenever a download lands and the engine is
    /// swapped in. `.userInitiated`, not `.utility`: a cold first press races it (V4.7). Deliberately
    /// silent — it publishes no engine state, so nothing appears on screen for work nobody asked for.
    public func warmUpEngine() {
        guard case .real = engineKind else { return }
        let engine = swappableEngine.current
        guard let real = engine as? RealEngine else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = real.isModelLoaded ? true : await real.preloadModel()
            await MainActor.run { [weak self] in self?.prewarmCapture(engine: real, modelLoaded: loaded) }
        }
    }

    /// Builds the capture graph without opening the microphone. Skipped without microphone
    /// permission (preparing the HAL device must not be what first asks for it), while muted, and
    /// while somebody holds capture (a prewarm resets the VAD).
    private func prewarmCapture(engine: RealEngine? = nil, modelLoaded: Bool? = nil) {
        guard case .real = engineKind, let audio else { return }
        guard PipelineAudioSource.microphoneAuthorized, !latchController.mute.isMuted, !audio.isCapturing else { return }
        let real = engine ?? (swappableEngine.current as? RealEngine)
        if let real, modelLoaded ?? real.isModelLoaded {
            // `engine.prewarm()` with the model already resolved publishes nothing; it only
            // prewarms the audio behind it.
            Task.detached(priority: .userInitiated) {
                do { try await real.prewarm() } catch { Log.engine.warning("capture prewarm failed: \(error)") }
            }
        } else {
            // No model in memory: `engine.prewarm()` would publish "Warming up…" and resolve one.
            // The graph does not need the model, so prepare it directly.
            do { try audio.prewarm() } catch { Log.engine.warning("capture prewarm failed: \(error)") }
        }
    }

    /// Route changes arrive in bursts (a device appears, then becomes the default).
    private func scheduleDevicePrewarm() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.devicePrewarm?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.prewarmCapture() }
            self.devicePrewarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// V4.7 — the full stop of the kept capture graph. Off the caller's thread except at quit.
    public func releaseCapture(_ reason: CaptureReleaseReason) {
        guard let source = audio?.pipeline.source else { return }
        if reason == .quit {
            source.release(reason: reason)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { source.release(reason: reason) }
        }
    }

    /// Called at hotkey-down: refresh the decoder's bias list from the current screen/context.
    public func prepareForUtterance() {
        guard let recognizerProvider, let boosting else { return }
        let booster = boosting.makeBoosterForUtterance()
        recognizerProvider.install(booster)
        if let booster { Log.engine.debug("boosting: \(booster.terms.count) terms in \(String(format: "%.1f", boosting.lastBuildMs)) ms") }
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
    ///
    /// FX3: returning means the engine is settled. A caller that arrives while another refresh is
    /// running *waits for that refresh* (`RefreshGate`) instead of returning at once — the early
    /// return is what let onboarding's model step look at the box 7 ms before the swap, find
    /// `UnavailableEngine`, and say "The speech model isn't ready" for a verified stack on disk.
    public func refreshEngineIfNeeded() async {
        // The mock engine is an explicit developer opt-in; never take it away from them.
        if case .mock = engineKind { return }
        guard modelManager != nil else { return }
        await refreshGate.run { [weak self] in await self?.performEngineRefresh() }
    }

    /// Posted (object: the container) after `refreshEngineIfNeeded` swapped the engine, from
    /// whichever thread the refresh ran on. Onboarding listens so a model load that failed while a
    /// swap was pending retries itself.
    public static let engineDidChangeNotification = Notification.Name("VoicePlus.AppContainer.engineDidChange")

    /// V5 C1/C1b — the capture enhancement (plain tap / Apple VP-IO / LocalVQE) is decided when the
    /// engine is built, so a change rebuilds a real engine (inside `refreshGate`, like a model swap).
    public func rebuildEngineForCaptureChange() async {
        guard case .real = engineKind, let modelManager else { return }
        let environment = self.environment
        await refreshGate.run { [weak self] in
            let built = await EngineFactory.make(environment: environment, manager: modelManager)
            guard let self, case .real = built.kind else { return }
            Log.engine.notice("capture enhancement changed — rebuilt the capture graph")
            await self.apply(built)
            NotificationCenter.default.post(name: Self.engineDidChangeNotification, object: self)
        }
    }

    /// One refresh pass; only ever run inside `refreshGate`.
    private func performEngineRefresh() async {
        guard let modelManager else { return }
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
        NotificationCenter.default.post(name: Self.engineDidChangeNotification, object: self)
    }

    /// One engine refresh at a time — and a caller that arrives while one is running waits for it.
    ///
    /// Until FX3 the guard was `if refreshingEngine { return }`: the second caller returned while
    /// the first was still between `chooseFinal` and the swap, and so saw the engine as it was
    /// *before* a refresh it had every reason to believe had happened. After a first-run download
    /// that second caller was onboarding's model load.
    ///
    /// A caller that joined a run already in flight also runs one more pass once it ends: the run it
    /// joined may have read the disk before this caller's reason to refresh existed (a download
    /// landing mid-run). The pass is cheap — `chooseFinal` is a few file lookups, and only an
    /// availability flip rebuilds anything — so correctness does not depend on who asked first.
    public final class RefreshGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight: Task<Void, Never>?

        public init() {}

        /// True while a pass is running.
        public var isRefreshing: Bool { lock.withLock { inFlight != nil } }

        /// Runs `pass`, or waits for the pass already running and then runs one more.
        public func run(_ pass: @escaping @Sendable () async -> Void) async {
            let first = claim(pass)
            await first.task.value
            guard first.joined else { return }
            await claim(pass).task.value
        }

        private func claim(_ pass: @escaping @Sendable () async -> Void) -> (task: Task<Void, Never>, joined: Bool) {
            lock.withLock {
                if let inFlight { return (inFlight, true) }
                // Created under the lock, so the pass's own `finish()` (which takes the lock) can
                // only clear this task, never one assigned after it.
                let task = Task { [weak self] in
                    await pass()
                    self?.finish()
                }
                inFlight = task
                return (task, false)
            }
        }

        private func finish() { lock.withLock { inFlight = nil } }
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
        // V4.7 — the outgoing engine's graph is kept between turns; nobody will start it again.
        let outgoing = audio?.pipeline.source
        engineKind = built.kind
        audio = built.audio
        if let outgoing, outgoing !== audio?.pipeline.source { outgoing.release(reason: .replaced) }
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
            //
            // FX3: awaited, not spawned. `downloadStack` returns only once the engine has been
            // re-resolved, so onboarding's "download finished" → "Loading" can never look at the
            // engine before the swap.
            tiers.onModelsChanged = { [weak self] in
                await self?.refreshEngineIfNeeded()
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
        // R6.2 — the practice field in "Try the key" has to use the real R2 commit path (the same
        // `UtteranceLander` production dictation lands through, `DeliveryOutcome` and all), never a
        // simulated success. `system.frontmostApp()` is the same focus snapshot the real hotkey path
        // takes at key release; while the practice field has keyboard focus, VoicePlus *is* the
        // frontmost app, so this is a real injection into a real AX text field, not a stand-in.
        dependencies.landUtterance = { [weak self] spans in
            guard let self else {
                return GuidedLanding(text: spans.map(\.text).joined(separator: " "), injected: false)
            }
            let focus = self.system.frontmostApp()
            let result = await self.lander.land(spans, startedAt: Date(), focus: focus)
            let appName = result.destinationName.isEmpty ? nil : result.destinationName
            return GuidedLanding(text: result.text, injected: result.landed, appName: appName)
        }
        return dependencies
    }

    public var connectedProviderNames: [String] {
        routing.allProviders.filter { $0.id != routing.fallback.id }.map(\.id.rawValue)
    }
}

/// V4.7 — the hard-mute flag's edges. The mute controller calls its observers synchronously on
/// whichever thread mutated it, and on far more than the flag, so the release / re-prepare is
/// keyed on an actual change.
final class MuteEdge: @unchecked Sendable {
    private let lock = NSLock()
    private var muted: Bool

    init(muted: Bool) { self.muted = muted }

    /// The new value when `muted` differs from the last one seen, else nil.
    func change(to muted: Bool) -> Bool? {
        lock.withLock {
            guard muted != self.muted else { return nil }
            self.muted = muted
            return muted
        }
    }
}

// MARK: - V4.6 launch order

/// A3 / V4.6 — a press made while the container is still being built.
///
/// The hotkey is armed before `AppContainer.build` (which loads the VAD on the ANE and used to run
/// the model store's maintenance under a file lock), so the first press no longer disappears. Until
/// the container is wired the gate holds **one** press: the pill says "Starting microphone…"
/// (`.starting`); if the key is still down — or latched — when the container lands, capture starts
/// through the real handler; if it was released, nothing lands and the pill goes quietly (K03's
/// first isolated tap is quiet). Main thread only, like the hotkey callbacks it sits behind.
final class LaunchPressGate {
    enum Pending: Equatable {
        case none
        /// Key down (or a hold in progress) when the container lands → replay `.startCapture`.
        case held
        /// A double-tap latch was made → replay `.startCapture`, `.enterLatch`.
        case latched
        /// The press ended before the container landed → nothing.
        case released
    }

    private(set) var pending: Pending = .none
    private(set) var isReady = false
    private let present: (PillState) -> Void
    private let dismiss: () -> Void

    init(present: @escaping (PillState) -> Void, dismiss: @escaping () -> Void) {
        self.present = present
        self.dismiss = dismiss
    }

    /// Everything the hotkey sends before the container is ready.
    func handle(_ action: HotkeyStateMachine.Action) {
        guard !isReady else { return }
        // Compared rather than switched on, so a gesture the hotkey learns later is simply not
        // queued instead of breaking this file's build.
        if action == .startCapture {
            // One queued press max: a second down while one is held changes nothing; a new press
            // after a released one replaces it.
            guard pending != .held, pending != .latched else { return }
            pending = .held
            present(.starting)
        } else if action == .enterLatch {
            guard pending == .held else { return }
            pending = .latched
        } else if action == .finalize || action == .cancelCapture {
            guard pending == .held || pending == .latched else { return }
            pending = .released
            dismiss()
        }
    }

    /// The container is wired: replay the held press (if any) through `forward`, exactly once.
    func containerReady(forward: (HotkeyStateMachine.Action) -> Void) {
        guard !isReady else { return }
        isReady = true
        let queued = pending
        pending = .none
        switch queued {
        case .held:
            forward(.startCapture)
        case .latched:
            forward(.startCapture)
            forward(.enterLatch)
        case .none, .released:
            break
        }
    }
}

/// A3 — build the container behind an armed hotkey, wire it, then hand the gate's held press to the
/// real handler. Separate from `AppDelegate` so it can run against a fake container future.
enum LaunchSequence {
    @MainActor
    static func run<Container>(gate: LaunchPressGate,
                               build: () async -> Container,
                               wire: (Container) -> Void,
                               forward: (HotkeyStateMachine.Action) -> Void) async -> Container {
        let container = await build()
        wire(container)
        gate.containerReady(forward: forward)
        return container
    }
}
