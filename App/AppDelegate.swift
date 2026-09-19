import Actions
import AppKit
import Pipeline
import Shared

/// Composition root. No dock icon, no windows by default: a status item and the pill.
/// The heavy wiring lives in `AppContainer` (P1.12); this delegate only sequences launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var coordinator: DictationCoordinator?
    /// R3.1 — the one owner of start / stop / cancel and of microphone arbitration.
    private var session: SessionCoordinator?
    /// R3.2 — endpoint-driven segment delivery while latched.
    private var latchRuntime: LatchRuntime?
    /// H2 — holds feed passive enrollment; latch audio feeds the speaker guard.
    private var speakerAudio: SpeakerAudioWiring?
    /// R8.1 — held so the ambient store outlives `applicationDidFinishLaunching`.
    private var ambientStore: AmbientTranscriptStore?
    private var orchestrator: PermissionOrchestrator?
    private var permissionPoller: PermissionPoller?
    /// Owns the tap lifecycle for the whole life of the process — see `CapabilityWatcher`.
    private var capabilityWatcher: CapabilityWatcher?
    private var container: AppContainer?
    private var transformPill: TransformPillDriver?
    /// R2.4 — delivery rows on the pill plus the held-text queue the menu recovers from.
    private var deliveryPill: DeliveryPillDriver?
    private var correctionOverlay: CorrectionOverlayController?
    private var inkOverlay: InkOverlayController?
    private var actSession: ActSessionController?
    private var consentPanels: ConsentPanelsController?
    private var agentCursor: AgentCursorController?
    private var meetingPanel: MeetingPromptPanel?
    private let hotkey = HotkeyService()
    /// P4.2 — second key opens the act domain (Bet 5: two keys, never inferred from phrasing).
    private let actHotkey = HotkeyService(bindingKey: HotkeyService.actBindingDefaultsKey,
                                          defaultBinding: HotkeyBinding(kind: .rightCommand))
    private let pill = PillPanelController()
    /// P5 — the persistent presence indicator near the notch (the status item is the first thing
    /// macOS culls from a crowded menu bar; this one is always there).
    private let presence = PresenceIndicatorController()
    private let updater: UpdaterProtocol = NoopUpdater()
    private let flags = FeatureFlagService.local()
    private let permissionChecker: PermissionChecking = ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1"
        ? MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        : SystemPermissionChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent until Packaging installs Info.plist
        AppContainer.ensureSupportDirectories()
        // A3 / V4.6 — the hotkey is armed *before* the container is built (VAD on the ANE, engine,
        // providers). A press made meanwhile shows "Starting microphone…" and is replayed through the
        // real handler once the container is wired: one press at most, and a released one lands
        // nothing. Until 1.11 presses before `wire()` simply did nothing.
        let gate = LaunchPressGate(present: { [weak self] state in self?.pill.model.present(state) },
                                   dismiss: { [weak self] in self?.pill.model.hide() })
        hotkey.onAction = { action in gate.handle(action) }
        armHotkeys()
        Task { @MainActor in
            var options = AppContainer.Options()
            options.flags = flags
            let built = options
            let container = await LaunchSequence.run(
                gate: gate,
                build: { await AppContainer.build(options: built) },
                wire: { container in
                    self.container = container
                    self.wire(container)
                },
                forward: { [weak self] action in self?.hotkey.onAction?(action) })
            // The watcher may have read capabilities before the menu and the indicator existed.
            if let caps = self.capabilityWatcher?.capabilities {
                self.statusItem?.capabilities = caps
                self.presence.setCapabilities(caps)
            }
            // V4.7 / V4.8 — model-store maintenance, model preload and capture prewarm: all after
            // wiring, all off the launch path.
            container.startBackgroundWork()
        }
    }

    /// Arm the hotkey from the permission *matrix*, continuously, before anything else — not from
    /// the completion of the permission walk. Until 1.6.5 `hotkey.start()` had exactly one caller,
    /// that completion, which does not run while onboarding is on screen and is withheld while a
    /// pre-prompt window is up. On the reporting machine Input Monitoring had been granted for
    /// twenty minutes and no tap had ever been created, because the walk was parked on the
    /// Accessibility pre-prompt — a permission the hotkey does not need. That is the whole of the
    /// "it needs a relaunch" symptom: the app only ever tried once, at the wrong moment.
    /// A3 moved this out of `wire()` so the tap is live while the container is still building.
    @MainActor
    private func armHotkeys() {
        // Actions ships off (`ActKeySettings`): with the switch off the act service is never armed
        // at all, so the key it is bound to reaches the frontmost app untouched. Read per tick, so
        // the Settings picker takes effect within a second and without a relaunch. Before the
        // container exists there are no settings to read, so it stays off until then.
        actHotkey.isWanted = { [weak self] in ActKeySettings.isEnabled(self?.container?.settings) }
        let watcher = CapabilityWatcher(checker: permissionChecker, hotkeys: [hotkey, actHotkey])
        watcher.onCapabilitiesChanged = { [weak self] caps, _ in
            self?.statusItem?.capabilities = caps
            self?.presence.setCapabilities(caps)   // P5 — a missing permission is a visible state
        }
        watcher.onTapProvenDead = { [weak self] in
            // The tap is armed, was re-armed once, and the system is still delivering modifier keys
            // to everyone but us. Say so; never restart behind the user's back.
            self?.pill.model.present(.preview(text: "macOS isn't sending keys to VoicePlus — quit and reopen it to fix the hotkey"))
            self?.presence.setTapProvenDead()   // P5 — and it stays visible after the pill goes
        }
        // P6 — the trigger that covers the case `onTapProvenDead` structurally cannot: a Microphone
        // or Input Monitoring grant made while this process was already running. macOS withholds
        // those until the app next starts (it says so in its own alert), so the status never flips,
        // the tap never arms, and nothing above ever fires. Offer the restart, once per trip.
        PermissionSettingsOpener.onOpened = { [weak watcher] permission in
            Task { @MainActor in watcher?.noteSentToSettings(permission) }
        }
        watcher.onRelaunchAdvised = { permission in
            RelaunchPrompt.present(for: permission)
        }
        capabilityWatcher = watcher
        watcher.start()
    }

    @MainActor
    private func wire(_ container: AppContainer) {
        let coordinator = DictationCoordinator(engine: container.engine, database: container.database, pill: pill)
        coordinator.lander = container.lander
        coordinator.onPrepare = { [weak container] in container?.prepareForUtterance() }
        coordinator.focusSnapshot = { [weak container] in container?.injector.focusGuard.snapshot() }
        // R2.4 — every `DeliveryOutcome` becomes a pill row: the committed text on land, the
        // "Landed · not confirmed" variant when readback could not confirm it, and a held row with
        // Insert here / Copy / Discard when the text has nowhere safe to go.
        //
        // This replaces the 1.5 s "flush the queue when focus comes back" retry that used to live
        // here. V3 §6 reverses it deliberately: returning focus alone does not insert held text,
        // because by then the caret is somewhere the user did not dictate into. The three actions
        // are the recovery path now — on the row and in the menu.
        //
        // `FocusGuard.held` (R2.3) is the queue that owns the words; the driver's queue is what the
        // pill row and the menu *draw*. They share `HeldText.id`, so all three actions act on the
        // same item and no copy of a discarded dictation is left alive behind the surface.
        let delivery = DeliveryPillDriver(pill: pill.model)
        delivery.held.insertSink = { [weak container] item in
            guard let container else { return false }
            // `insertHere` re-runs the whole stack against whatever has focus *now*.
            if let outcome = container.injector.focusGuard.insertHere(item.id) { return outcome.succeeded }
            // Not in Injection's list (no id was carried through): insert it directly instead of
            // telling the user it could not be done. Spelled `.init` to avoid an `import Injection`.
            return container.injector.inject(.init(text: item.text)).succeeded
        }
        delivery.held.copySink = { [weak container] item in
            guard container?.injector.focusGuard.copy(item.id) != true else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
        delivery.held.discardSink = { [weak container] item in
            _ = container?.injector.focusGuard.discard(item.id)
        }
        self.deliveryPill = delivery
        coordinator.onLanded = { [weak delivery, weak container] result in
            // The injector has already held this text if it is held at all; adopt its id.
            let heldID = container?.injector.focusGuard.held.last { $0.text == result.text }?.id
            delivery?.handle(result, destination: result.destinationName, heldID: heldID)
        }
        container.audio?.onMicQuality = { [weak coordinator] q in
            DispatchQueue.main.async { coordinator?.noteMicQuality(q) }
        }
        // The pill waveform runs off real captured audio for the whole utterance (levels from
        // `EngineState` stop at the first preview). No pipeline (mock engine) → engine states.
        if let audio = container.audio { coordinator.bindWaveform(to: audio) }
        coordinator.preflight = { [weak container] in await container?.refreshEngineIfNeeded() }
        // Capture never opened. Clear the gesture so the key-up that follows emits nothing: without
        // this the release ran `finalize()` against an engine that was never started, which is the
        // "broken notch animation that appears and disappears" at the end of a dead press.
        coordinator.onStartFailure = { [weak self] _ in self?.hotkey.resetGesture() }
        // A model downloaded mid-session replaces the engine *and* the audio pipeline behind it;
        // rebind the things that hang off the pipeline rather than off the engine.
        container.onEngineChanged = { [weak self, weak coordinator] container in
            guard let coordinator, let audio = container.audio else { return }
            coordinator.bindWaveform(to: audio)
            self?.speakerAudio?.bind(to: audio)
            audio.onMicQuality = { [weak coordinator] q in
                DispatchQueue.main.async { coordinator?.noteMicQuality(q) }
            }
            Log.app.info("engine swapped: \(container.activeModelName)")
        }
        self.coordinator = coordinator

        // R3.1 — one coordinator owns start / stop / cancel and microphone arbitration for the
        // hotkey, the menu, onboarding and meetings (V3 §4.6), on top of the ranked capture-graph
        // ownership in `PipelineAudioSource.Owner`. R3.2's latch runtime hangs off it: endpoints
        // close segments through R2.2 while listening continues, and committed text lands through
        // the same lander and the same held queue as a hold.
        let latchDelivery = LanderLatchDelivery(   // S2 wires its `onLanded` (the S2 block below)
            lander: container.lander,
            focusGuard: container.injector.focusGuard,
            focusSnapshot: { [weak container] in container?.injector.focusGuard.snapshot() })
        let latch = LatchRuntime(delivery: latchDelivery)
        latch.onOutcome = { outcome, segment in
            Log.app.info("latch segment \(segment.description): \(String(describing: outcome))")
        }
        let sessionCoordinator = SessionCoordinator(dictation: coordinator, mute: container.latchController.mute, latch: latch)
        sessionCoordinator.observeSystemEvents()
        sessionCoordinator.onStopped = { [weak self] _, reason in
            guard reason == .locked || reason == .slept else { return }
            self?.pill.model.present(.preview(text: "Dictation stopped — start it again when you're ready"))
        }
        self.latchRuntime = latch
        self.session = sessionCoordinator

        // ── S3 · turn controller: preview before insert (design §5, §12) ────────────────────────
        // Every hold and every latch segment goes key-down snapshot → final preview → one insert
        // through `TurnController` (the lander's gate). Escape (I2), the pill's turn buttons, hover,
        // lock/sleep/mute and deixis are wired inside; the turn records go to `TurnStore.current`.
        TurnWiring.attach(container: container, pill: pill.model, coordinator: coordinator, session: sessionCoordinator,
                          finishLatch: { [weak self] in
                              self?.session?.stop(.hotkey)
                              self?.hotkey.resetGesture()
                          })
        // ── end S3 ──────────────────────────────────────────────────────────────────────────────

        // H2 (V4.49) — every hold-to-talk utterance with ≥ 1.5 s of speech teaches the voice until
        // ten have; then latch segments go through the speaker filter, fed the latch audio here.
        let speakerAudio = SpeakerAudioWiring(
            isLatched: { [weak coordinator] in coordinator?.latched ?? false },
            wantsHolds: { [weak container] in !(container?.latchController.hasEnrolledVoice ?? true) },
            observe: SpeakerAudioWiring.observeHolds(on: container.latchController))
        if let audio = container.audio { speakerAudio.bind(to: audio) }
        container.latchController.attach(runtime: latch, segmentAudio: { [weak speakerAudio] in speakerAudio?.segmentAudio.take() })
        container.latchController.onVoiceLearned = { [weak self] _ in
            DispatchQueue.main.async { self?.pill.model.present(.preview(text: LatchController.voiceLearnedMessage)) }
        }
        self.speakerAudio = speakerAudio

        // R8.1/R8.2 — ambient capture hangs off the latch runtime's transcript seam, which is the
        // only place ambient text exists. It is read through `gate` on every segment rather than
        // captured once, so turning the switch off stops capture on the next utterance instead of
        // the next relaunch, and the enrolled-speaker verdict is re-read for the same reason.
        //
        // Ambient text never reaches `delivery` — that is the property `AmbientNeverInjectsTests`
        // and `AmbientInjectionAudit` exist to defend (V3 §8: never type or act from ambient speech).
        let ambientStore = AmbientWiring.store(database: container.database, settings: container.settings)
        self.ambientStore = ambientStore
        AmbientWiring.attach(to: latch,
                             sink: ambientStore,
                             gate: { [weak container] in
                                 AmbientWiring.gate(settings: container?.settings,
                                                    filter: container?.latchController.speakerFilter)
                             })
        // The verdict stays at its default `.unknown`: the transcript seam carries text and a
        // SegmentID, not audio, and `SpeakerGate.verdict(for:embedder:)` needs samples. With the
        // enrolled-only path that means every segment is discarded — `.modelUnavailable` on a
        // machine without WeSpeaker weights suppresses, which is the honest answer rather than a
        // claim that a check ran. Ambient therefore keeps nothing until the seam carries audio.
        // Recorded as gap G11 in the build document.

        // P2.3 — transform pill (tint, "editing N words", ghost, 8 s warm window).
        let transformPill = TransformPillDriver(pill: pill.model, warmWindow: container.transform.session.warmWindow)
        container.transform.onEvent = { [weak transformPill] e in Task { @MainActor in transformPill?.handle(e) } }
        transformPill.onAction = { [weak container] action in
            guard let container else { return }
            switch action {
            case .undo: container.transform.undo()
            case .tryAgain: Task { _ = await container.transform.tryAgain() }
            }
        }
        self.transformPill = transformPill

        // ── S12 · selected-text transform recovery (design §6 R1/R2, §8.8) ─────────────────────
        // An edit whose target changed before the replacement, or an undo whose range changed, is
        // never written: the text goes to the held row (Insert here · Copy · Discard) and the menu.
        container.transform.onRecovery = { [weak self] recovery in
            Task { @MainActor in
                self?.deliveryPill?.handle(.held(reason: recovery.heldReason), text: recovery.text,
                                           destination: recovery.destination)
            }
        }
        // Nothing is written during R1, so Escape (borrowed only while the edit runs or is previewed)
        // keeps the original, and the pointer on the pill freezes the preview's dwell.
        transformPill.onCancel = { [weak container] in container?.transform.cancelPreview() }
        transformPill.onPause = { [weak container] on in container?.transform.pausePreview(on) }
        let transformEscape = EscapeHotkey()
        transformEscape.observeMenuTracking()
        transformPill.escape = transformEscape
        // ── end S12 ─────────────────────────────────────────────────────────────────────────────

        // P1.5.2 — shimmer/underline + hover "was: …" + one-tap revert on silent corrections.
        let overlay = CorrectionOverlayController(ledger: container.correction.ledger)
        overlay.revertSink = container.repair.replaceSink
        overlay.isEnabled = { [weak container] in
            guard let container else { return false }
            return CorrectionSettings.isEnabled(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, store: container.settings)
        }
        correctionOverlay = overlay

        // P3 — ink overlay per display; strokes render as the tap records them; region bundle
        // counter surfaces in the pill; deixis capture brackets the hotkey hold.
        let inkOverlay = InkOverlayController()
        self.inkOverlay = inkOverlay
        container.deixis.attachRecorder(normalizer: .current(), inkSink: inkOverlay)
        inkOverlay.onBundleChanged = { [weak self] text in
            guard let text else { return }
            self?.pill.model.present(.preview(text: text))
        }
        container.deixis.onElicitationChange = { [weak self] state in
            Task { @MainActor in self?.presentElicitation(state) }
        }

        // G1–G3 — the dictation key gates deixis. A drag draws a box only while the key is down
        // (or in latch with "draw without a key"); the overlay is in front only while it is down;
        // `.enterLatch` releases the tap; a press inside latch that overlaps a drag points instead
        // of stopping. Each box gets an AX hit-test and AX text, and — with Screen Recording — a
        // screenshot kept for the turn and OCR when the tree has no text.
        let deixis = container.deixis
        deixis.settings = container.settings
        deixis.isDictationKeyDown = { [weak hotkey = self.hotkey, weak act = self.actHotkey] in
            (hotkey?.isDictationKeyDown ?? false) || (act?.isGestureKeyHeld ?? false)   // P4: the act key points too
        }
        deixis.isLatched = { [weak sessionCoordinator] in sessionCoordinator?.isLatched ?? false }
        deixis.regionText = LiveAXRegionTextReader()
        deixis.screen = ScreenTextService(customWords: { [weak container] in
            container?.adaptation?.loop.lexicon.terms.values.map(\.text) ?? []
        })
        deixis.onNotice = { [weak self] line in
            Task { @MainActor in self?.pill.model.present(.preview(text: line)) }
        }
        let deixisKeys = DeixisKeyController(
            capture: deixis,
            overlay: { [weak inkOverlay] command in
                let apply: @MainActor () -> Void = {
                    switch command {
                    case .show: inkOverlay?.show()
                    case .hide(let fading): inkOverlay?.hide(fading: fading)
                    }
                }
                if Thread.isMainThread { MainActor.assumeIsolated(apply) } else { Task { @MainActor in apply() } }
            },
            // R3.1 — every gesture goes through the one session owner, which arbitrates the
            // microphone and owns the mode before `DictationCoordinator` sees it.
            forward: { [weak sessionCoordinator] action in sessionCoordinator?.handle(action) },
            keyProbe: { [weak hotkey = self.hotkey] in hotkey?.isDictationKeyDown ?? false },
            sessionLatched: { [weak sessionCoordinator] in sessionCoordinator?.isLatched ?? false },
            drawWithoutKey: { [weak container] in DeixisSettings.drawsWithoutKey(container?.settings) })
        deixis.onRegionStarted = { [weak deixisKeys] in deixisKeys?.regionStarted() }
        hotkey.onAction = { action in deixisKeys.handle(action) }

        // P4 — act session behind the second key: consent panels, agent cursor, step chips.
        let panels = ConsentPanelsController()
        panels.consent = container.consentEngine
        panels.router = container.actRouter
        consentPanels = panels
        container.consentEngine.onToast = { token, toast in
            Task { @MainActor in panels.showToast(token, toast) }
        }
        let agent = container.agentBackend
        container.consentEngine.onCard = { [weak agent] _, card in
            // The agent presents its own card through `confirmation`; only the deterministic
            // path surfaces cards from here.
            guard agent?.isRunning != true else { return }
            Task { @MainActor in panels.showCard(card) }
        }
        agent.confirmation = { card in await panels.requestAgentConfirmation(card) }
        agent.onChips = { [weak self] chips in
            Task { @MainActor in self?.pill.model.present(.preview(text: chips.pillText)) }
        }

        let cursor = AgentCursorController(overlay: inkOverlay)
        agentCursor = cursor
        let session = ActSessionController(engine: container.engine, router: container.actRouter,
                                           state: container.actState)
        session.contextLines = { [weak container] in container?.deixis.actContextLines ?? [] }
        session.onDispatch = { [weak self, weak container] dispatch in
            Task { @MainActor in self?.showActDispatch(dispatch, container: container) }
        }
        actSession = session
        container.actHook.onRoute = { [weak session] route in
            Task { await session?.route(route) }
        }
        actHotkey.onAction = { [weak session, weak inkOverlay, weak container, weak self] action in
            // The act key must be a *different* key from the dictation key. Re-checked per event
            // rather than at launch, because either binding can change from Settings while the
            // app runs. See `ActKeyBinding`.
            guard let self,
                  ActKeyBinding.isLive(enabled: ActKeySettings.isEnabled(container?.settings),
                                       act: self.actHotkey.binding, dictation: self.hotkey.binding) else {
                Log.app.notice("act key is switched off or bound to the dictation key — the act domain stays closed so dictation lands normally")
                return
            }
            if case .startCapture = action {
                container?.deixis.beginCapture()
                Task { @MainActor in inkOverlay?.show() }
            }
            if case .finalize = action { container?.deixis.endCapture(); Task { @MainActor in inkOverlay?.hide() } }
            if case .cancelCapture = action { container?.deixis.endCapture(); Task { @MainActor in inkOverlay?.hide() } }
            session?.handle(action)
        }
        SettingsWindowController.connectorHub = container.connectorHub
        SettingsWindowController.syncService = container.sync
        // R7.1 / R7.2 — the one window. Everything that used to open a window of its own (Settings,
        // the Lab, the Data Panel, enrollment) now selects a section of it, so it needs the same
        // dependencies and the same live pieces the menu has.
        MainWindowController.dependencies = container.onboardingDependencies(permissions: permissionChecker)
        MainWindowController.updater = updater
        MainWindowController.environment.connectedProviders = container.connectedProviderNames
        MainWindowController.environment.labRegistry = container.labRegistry
        MainWindowController.environment.egressGate = container.egressGate
        MainWindowController.environment.personalWER = container.adaptation?.personalWER
        MainWindowController.environment.heldItems = { [weak delivery] in delivery?.held.items ?? [] }
        MainWindowController.environment.heldAction = { [weak delivery] item, action in
            delivery?.perform(action, on: item.id) ?? .unavailable
        }
        MainWindowController.environment.makeEnrollment = { [weak self, weak container] in
            guard let self, let container else { return nil }
            return self.makeSpeakerEnrollment(container: container)
        }
        MainWindowController.environment.setMeetingCapture = { [weak container] on in
            guard let meeting = container?.meeting else { return }
            Task { await meeting.setMeetingCaptureEnabled(on) }
        }
        // R4.3 — Dictionary tab's "learned automatically" list + Forget action read and mutate
        // the same adaptation loop the pipeline uses, so a forget takes effect on the next utterance.
        SettingsWindowController.adaptationLoop = container.adaptation?.loop
        SettingsWindowController.trainingPairStore = container.adaptation?.store
        // P6.2 — "Train by voice": ~2 s through the engine's audio tap → pronunciation store.
        SettingsWindowController.trainByVoice = { [weak container] word in
            guard let container, let adaptation = container.adaptation else { return nil }
            container.audioTap.reset()
            try? await container.engine.start(prewarm: true)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try? await container.engine.stop()
            let samples = container.audioTap.samples
            guard !samples.isEmpty else { return "Couldn't hear anything — try again." }
            return adaptation.trainByVoice(word: word, samples: samples)
        }
        // P6.3 — script indicator into the pill badge.
        container.codeSwitch.onIndicatorChange = { [weak self] label in
            DispatchQueue.main.async { self?.pill.model.scriptBadge = label }
        }

        // P5 — latch: the wake-verb context flag rides the lander's augmenter chain; the
        // directed-speech gate opens the mic on addressed speech; hard mute pauses everything.
        let baseAugmenter = container.lander.contextAugmenter
        container.lander.contextAugmenter = { [weak coordinator] spans, ctx in
            var ctx = baseAugmenter?(spans, ctx) ?? ctx
            if coordinator?.latched == true {
                ctx.extra[WakeVerbPreRoute.modeKey] = WakeVerbPreRoute.latchedValue
            }
            return ctx
        }
        container.latchController.isLatched = { [weak coordinator] in coordinator?.latched ?? false }
        container.latchController.onShouldCapture = { [weak coordinator] _ in
            // Addressed speech opens the mic for the follow-on utterance (RAM-only ring;
            // nothing is stored). The engine's normal finalize path lands it.
            DispatchQueue.main.async { coordinator?.start() }
        }
        container.latchController.mute.observe { [weak self, weak sessionCoordinator] model in
            DispatchQueue.main.async {
                // R3.3 — hard mute goes through the session owner: capture stops on every path,
                // pending insertion is cancelled, and the latch ends. Unmuting never resumes.
                if model.muted { sessionCoordinator?.muteEngaged() } else { sessionCoordinator?.muteReleased() }
                self?.statusItem?.refreshIcon()
            }
        }
        // S7f — Privacy's hard-mute row acts on the same mute as the menu bar and the pill.
        PrivacyWiring.mute = container.latchController.mute

        // P5.5 — meeting capture: detector effects → notch prompt / recording / notes notification.
        let meetingPanel = MeetingPromptPanel()
        meetingPanel.onChoice = { [weak container] choice in container?.meeting.choose(choice) }
        self.meetingPanel = meetingPanel
        container.meeting.onPrompt = { prompt in
            Task { @MainActor in
                if let prompt { meetingPanel.show(prompt) } else { meetingPanel.dismiss() }
            }
        }
        container.meeting.onNotes = { record in MeetingNotifier.post(record) }
        // Inert unless the user opted in (menu-bar › "Capture meetings"). Before the opt-in gate
        // this line asked TCC for Calendar — and, via EKEventStore's initialiser, Reminders — on
        // every single launch, with no user intent anywhere in the chain.
        container.meeting.startMonitoring()
        // S7c — manual meeting capture (Meetings › Start recording, the expanded panel, the pill's
        // Q0 / Q1 / Q2 rows) runs over the same coordinator; the pill's meeting buttons reach it first.
        MeetingCaptureWiring.install(coordinator: container.meeting, pill: pill.model)

        let status = StatusItemController(flags: container.flags, database: container.database, coordinator: coordinator,
                                          hotkey: hotkey, updater: updater)
        status.activeModelName = { [weak container] in container?.activeModelName ?? "—" }
        status.micName = { [weak container] in container?.microphoneName ?? "Default microphone" }
        status.actHotkey = actHotkey
        status.actKeyStore = container.settings
        status.corrections = container.correction.ledger
        status.correctionSettings = container.settings
        status.correctionRevertSink = { [weak container] in container?.repair.replaceSink }
        status.onRecheckPermissions = { [weak self] in self?.runPermissions() }
        status.meetingCaptureEnabled = { [weak container] in container?.meeting.isMeetingCaptureEnabled ?? false }
        status.onToggleMeetingCapture = { [weak container] in
            guard let meeting = container?.meeting else { return }
            let next = !meeting.isMeetingCaptureEnabled
            Task { await meeting.setMeetingCaptureEnabled(next) }
        }
        // P5.4 — ambient glyph + one-gesture hard mute; P5.3 — enrollment window.
        status.ambientSymbol = { [weak container] in
            guard let container, container.flags.isEnabled(.directedSpeech) else { return nil }
            return container.latchController.ambientModel.menuBarSymbol
        }
        status.ambientMuted = { [weak container] in container?.latchController.mute.isMuted ?? false }
        status.onToggleMute = { [weak container] in container?.latchController.mute.toggleMute() }
        status.onEnrollVoice = { [weak self, weak container] in
            guard let self, let container else { return }
            self.showSpeakerEnrollment(container: container)
        }
        status.onOpenLab = { [weak container] in
            guard let container else { return }
            LabWindowController.showLab(registry: container.labRegistry, database: container.database,
                                        personalWER: container.adaptation?.personalWER)
        }
        status.onOpenDataPanel = { [weak container] in
            guard let container else { return }
            LabWindowController.showDataPanel(database: container.database, gate: container.egressGate)
        }
        status.onOpenSettings = { [weak self, weak container] in
            guard let self, let container else { return }
            SettingsWindowController.show(dependencies: container.onboardingDependencies(permissions: self.permissionChecker),
                                          connectedProviders: container.connectedProviderNames)
        }
        // R7.3/R7.1 — "Open VoicePlus" and "Settings…" are the same window at different sections
        // (V3 §9.2). Without this, openWindow fell back to onOpenSettings and both landed on
        // Settings, so the menu had no route to Today at all.
        status.onOpenWindow = { [weak self, weak container] in
            guard let self, let container else { return }
            _ = MainWindowController.show(dependencies: container.onboardingDependencies(permissions: self.permissionChecker),
                                          section: .today,
                                          connectedProviders: container.connectedProviderNames)
        }
        // R2.4 — "Recover text" carries the same three actions as the held pill row, off the same
        // queue, and Quit warns while anything is still held (V3 §6). Both are invisible until
        // something is actually held.
        status.heldItems = { [weak delivery] in delivery?.held.items ?? [] }
        status.onHeldAction = { [weak delivery] item, action in delivery?.perform(action, on: item.id) }
        delivery.onHeldChanged = { [weak status] _ in MainActor.assumeIsolated { status?.rebuild() } }
        // R7.3 — the one menu goes through the session owner (R3) for Start / Stop / latch, and it
        // is the only place an explicit Stop exists while capture is open (V3 §9.3).
        status.session = sessionCoordinator
        status.onToggleLatch = { [weak sessionCoordinator] in
            guard let sessionCoordinator else { return }
            if sessionCoordinator.isLatched {
                sessionCoordinator.stop(sessionCoordinator.activeRequester ?? .menu, reason: .userStopped)
            } else {
                sessionCoordinator.start(.menu, mode: .latched)
            }
        }
        // "Stop meeting" ends a recording the user started; the opt-in remains the Calendar gesture.
        status.meetingRunning = { [weak container] in container?.meeting.session != nil }
        status.onStopMeeting = { [weak container] in
            guard let meeting = container?.meeting else { return }
            Task { _ = await meeting.finishSession() }
        }
        status.presenceIndicatorEnabled = { [weak container] in PresenceSettings.isEnabled(container?.settings) }
        status.onTogglePresenceIndicator = { [weak container] in
            PresenceSettings.setEnabled(!PresenceSettings.isEnabled(container?.settings), store: container?.settings)
        }
        statusItem = status

        // P5 — persistent presence indicator. Never takes focus, never swallows a click, and its
        // click pops the status menu so there is a way into Settings/Quit even when macOS has
        // culled the status item. `PresenceIndicatorController` logs every computed frame.
        presence.settings = container.settings
        // Any click on the dot — left, right or ⌃-click — pops the status menu; `PresenceClickRouter`
        // owns that decision. (1.7.9 briefly made the left click explain/repair instead; reverted at
        // the owner's request.) Popping a menu takes no focus from the app being typed into.
        presence.onClick = { [weak self] in self?.statusItem?.popUpMenu(from: .notch) }
        presence.pausedProvider = { [weak coordinator] in coordinator?.paused ?? false }
        // R8.4 — the indicator reflects *actual* microphone ownership, never the dictation engine's
        // state alone: the shared capture graph's ranked owner (dictation, the onboarding meter,
        // diagnostics) plus meeting capture, which opens its own device. R3's arbitration claim comes
        // along to name the holder — `MicrophoneOwnership` never lets a claim alone light the chin.
        presence.microphoneOwnership = { [weak container, weak sessionCoordinator] in
            MicrophoneOwnership(graphOwner: container?.audio?.currentOwner,
                                meetingCapturing: container?.meeting.session != nil,
                                // Ambient capture rides the shared graph, so `graphOwner` already
                                // reports it; the flag stays for a future path that opens its own
                                // device, the way meeting capture does.
                                ambientCapturing: false,
                                claim: sessionCoordinator?.activeRequester)
        }
        presence.bind(pill: pill.model, mute: container.latchController.mute)
        presence.start()

        // ── S2 · the Spool pill and the presence chin (design §4–§6, §10) ─────────────────────────
        // Hints name the configured key (read on every render, so a Settings change applies at once);
        // the pill's non-turn buttons reach their owner (the turn's own buttons, hover and the
        // key-down destination are `TurnWiring`'s, above); latch segments get the same delivery row
        // as a hold; deixis boxes show as chips in the text lane; mute is the I2 row with its
        // explicit Unmute; the status menu reads the chin's blockers.
        let pillModel = pill.model
        pillModel.keyLabel = { [weak hotkey = self.hotkey] in hotkey?.label ?? HotkeyBinding.default.label }
        if pillModel.destinationProvider == nil { pillModel.destinationProvider = { PillDestination.frontmostName() } }
        presence.readyHint = { [weak hotkey = self.hotkey] in (hotkey?.binding ?? .default).readyHint() }
        presence.hotkeyHint = { [weak hotkey = self.hotkey] in
            hotkey.map { PresenceHover.keyHint(for: $0.binding) } ?? HotkeyHint.unknown
        }
        statusItem?.presenceState = { [weak presence = self.presence] in presence?.substance ?? .ready }
        let turnButtons = pillModel.onAction   // `TurnWiring` routes the turn's own buttons
        pillModel.onAction = { [weak self, weak container, weak pillModel] action, shown in
            if MeetingCaptureWiring.handle(action) { return }   // S7c: a manual meeting's own buttons
            turnButtons?(action, shown)
            let effect = PillActionRoute.effect(for: action, shown: shown, text: pillModel?.actionText ?? "")
            guard !effect.isTurnEffect, let self, let container else { return }
            let deps = { container.onboardingDependencies(permissions: self.permissionChecker) }
            switch effect {
            case .unmute:
                container.latchController.mute.unmute()
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .open(.models):
                SettingsWindowController.show(dependencies: deps(), tab: .models,
                                              connectedProviders: container.connectedProviderNames)
            case .open(let screen):
                let section: MainWindowSection
                switch screen {
                case .today, .models: section = .today
                case .voice: section = .voice
                case .privacy: section = .privacy
                case .meetings: section = .meetings
                }
                _ = MainWindowController.show(dependencies: deps(), section: section,
                                              connectedProviders: container.connectedProviderNames)
            case .stopMeeting:
                let meeting = container.meeting
                Task { _ = await meeting.finishSession() }
            case .insertNow, .cancelPreview, .cancelFinishing, .useAvailableText, .pauseForReview, .undo,
                 .finishLatch, .none:
                break
            }
        }
        latchDelivery.onLanded = { [weak delivery, weak container] result in
            DispatchQueue.main.async {
                let heldID = container?.injector.focusGuard.held.last { $0.text == result.text }?.id
                delivery?.handle(result, destination: result.destinationName, heldID: heldID)
            }
        }
        let pillDeixis = container.deixis
        pillDeixis.onRegionsChanged = { [weak pillModel, weak pillDeixis] regions in
            DispatchQueue.main.async {
                pillModel?.showDeixis(regions) { pillDeixis?.image(for: $0) }
            }
        }
        container.latchController.mute.observe { [weak pillModel] model in
            DispatchQueue.main.async {
                guard let pillModel else { return }
                if model.muted { pillModel.present(.muted) }
                else if case .muted = pillModel.state { pillModel.dismissNotice() }
            }
        }
        // ── end S2 ───────────────────────────────────────────────────────────────────────────────

        // ── W3H · wave-2 gate hand-offs (HandoffWiring.swift, PillReviewRouting.swift) ─────────────
        // The saved window theme before any window or menu is drawn; "Double-tap to latch" on the live
        // key and in the chin's hint; sound cues at the turn's cue points (off by default, no success
        // sound before a verified insertion); "Save dictation history" off honoured by every writer;
        // the pill's Review / Check → Today's recovery sheet (or the turn's detail); the transform
        // preview's before/after rows and its Replace text / Cancel.
        let w3hSettings = container.settings
        LaunchAppearance.apply(settings: w3hSettings)
        let dictationKey = hotkey.onAction
        let latchGesture = LatchGestureHook(isEnabled: { LatchGestureSettings.isEnabled(w3hSettings) },
                                            resetGesture: { [weak hotkey = self.hotkey] in hotkey?.resetGesture() },
                                            forward: { dictationKey?($0) })
        hotkey.onAction = { latchGesture.handle($0) }
        presence.readyHint = { [weak hotkey = self.hotkey] in
            LatchGestureHook.readyHint(binding: hotkey?.binding ?? .default, settings: w3hSettings)
        }
        DictationHistoryGate.attach(settings: w3hSettings, lander: container.lander, coordinator: coordinator,
                                    store: TurnStore.current)
        if let turnStore = TurnStore.current { TurnSoundCues().attach(to: turnStore, settings: w3hSettings) }
        TransformRowsFeed.attach(to: container.transform, pill: pillModel)
        PillReviewWiring.install(
            on: pillModel,
            openToday: { [weak self, weak container] in
                guard let self, let container else { return nil }
                _ = MainWindowController.show(dependencies: container.onboardingDependencies(permissions: self.permissionChecker),
                                              route: WindowRoute(.today),
                                              connectedProviders: container.connectedProviderNames)
                return PillReviewWiring.liveToday()
            },
            transform: { [weak landing = container.transform] button in
                switch button {
                case .confirm: landing?.confirmPreview()
                case .cancel: landing?.cancelPreview()
                }
            })
        // ── end W3H ──────────────────────────────────────────────────────────────────────────────

        // The hotkey and its capability watcher were armed at launch, before the container (A3):
        // see `armHotkeys()`.

        let orchestrator = PermissionOrchestrator(checker: permissionChecker, presentPrePrompt: PrePromptWindow.present)
        // macOS answers Input Monitoring / Accessibility only in System Settings, so "Check
        // permissions…" polls instead of stopping the walk after opening the pane.
        let poller = PermissionPoller(checker: permissionChecker)
        permissionPoller = poller
        orchestrator.watchUntilGranted = { permission, granted in
            Task { @MainActor in poller.watch(permission, granted: granted) }
        }
        self.orchestrator = orchestrator
        // An ad-hoc signature makes TCC match this app by cdhash, which changes with every build.
        Log.app.info("code identity: \(PermissionDiagnostics.summary())")

        // MARK: S8 — onboarding wiring (design §8.7, V4.48, I1) ────────────────────────────────
        // Everything onboarding needs that only the composition root can reach (model loader, the
        // live hotkey, the enrollment recorder), applied to every way the window opens: launch,
        // resume, Settings' "Run onboarding again". See `OnboardingDependencies.wireLive`.
        let onboardingKeyEvents = DictationKeyEvents(fnEventsSeen: hotkey.fnEventsSeen)
        hotkey.onFnEvent = { onboardingKeyEvents.noteFnEvent() }
        OnboardingWindowController.configure = { [weak self, weak container] deps in
            guard let self, let container else { return }
            deps.wireLive(container: container, hotkey: self.hotkey, keyEvents: onboardingKeyEvents,
                          makeEnrollment: { [weak self, weak container] in
                              guard let self, let container else { return nil }
                              return self.makeSpeakerEnrollment(container: container)
                          })
        }
        // ─────────────────────────────────────────────────────────────── end S8 onboarding wiring

        if OnboardingWindowController.isNeeded(settings: container.settings) {
            OnboardingWindowController.show(dependencies: container.onboardingDependencies(permissions: permissionChecker)) { [weak self] _ in
                self?.runPermissions()
            }
        } else {
            runPermissions()
        }
        Log.app.info("VoicePlus up: \(container.activeModelName) (Shared \(SharedModule.version))")
    }

    /// P5.3 — onboarding-2: enroll the user's voice through the engine's audio tap (~3 s per
    /// prompted phrase); the finished profile arms the latch's speaker gate.
    @MainActor
    private func showSpeakerEnrollment(container: AppContainer) {
        SpeakerEnrollmentWindowController.show(model: makeSpeakerEnrollment(container: container))
    }

    /// The enrollment view model, separated from showing it: R7.2 runs enrollment inside the one
    /// window's Voice section, which builds it on demand through `MainWindowEnvironment`.
    @MainActor
    private func makeSpeakerEnrollment(container: AppContainer) -> SpeakerEnrollmentViewModel {
        let model = SpeakerEnrollmentViewModel(embedder: container.latchController.embedder) { [weak container] in
            guard let container else { return [] }
            container.audioTap.reset()
            try? await container.engine.start(prewarm: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = try? await container.engine.stop()
            return container.audioTap.samples
        }
        model.onComplete = { [weak container] profile in container?.latchController.install(profile: profile) }
        return model
    }

    /// P4 — act feedback: pill text per dispatch; the agent cursor animates the action
    /// (it never moves the real pointer — `AgentCursorTests` enforce that).
    @MainActor
    private func showActDispatch(_ dispatch: ActDispatch, container: AppContainer?) {
        let anchor = container?.deixis.lastBindings.first?.anchor.map { CGPoint(x: $0.x, y: $0.y) }
            ?? NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        switch dispatch {
        case .deterministic(let result, let outcome):
            inkOverlay?.show()
            agentCursor?.glide(to: anchor, then: { [weak self] in self?.agentCursor?.click(at: anchor) })
            if case .awaitingConfirmation = outcome {
                pill.model.present(.preview(text: "Confirm to proceed — say “confirm” or click"))
            } else if let result, result.outcome.isSuccess {
                pill.model.present(.preview(text: "Done: \(result.request.catalogID ?? result.request.kind.rawValue)"))
            } else if let result {
                pill.model.present(.preview(text: "Couldn't do that (\(result.request.kind.rawValue))"))
            }
        case .agentic(let report):
            // Plain language only. `String(describing:)` on the status put
            // `Agent: failed(reason: "planner: disabled(stage: act.planner)")` in the pill.
            pill.model.present(.preview(text: report.userMessage))
        case .stopped:
            pill.model.present(.preview(text: "Stopped"))
        case .cancelled:
            pill.model.present(.preview(text: "Cancelled"))
            consentPanels?.dismissCard()
        case .confirmed:
            pill.model.present(.preview(text: "Confirmed"))
            consentPanels?.dismissCard()
        case .ignored:
            break
        }
    }

    /// P3.6 — reverse elicitation: pulse rings on the candidates + "which one?" in the pill;
    /// timeout falls back to clarifying text (the state machine produces it).
    @MainActor
    private func presentElicitation(_ state: ElicitationState) {
        switch state {
        case .prompting(let prompt):
            inkOverlay?.show()
            for candidate in prompt.candidates {
                inkOverlay?.pulse(BoundRegion(frame: candidate.ring, displayID: candidate.displayID))
            }
            let labels = prompt.candidates.map(\.label).joined(separator: " / ")
            pill.model.present(.preview(text: "\(prompt.question) \(labels)"))
            // Drive the deadline: a tick after the timeout resolves .prompting → .timedOut.
            let deadline = prompt.deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in
                guard let container = self?.container else { return }
                container.deixis.elicit(.tick(now: max(deadline + 0.01, container.deixis.clock.now())))
            }
        case .timedOut(let clarifyingText, _):
            pill.model.present(.preview(text: clarifyingText))
            inkOverlay?.hide()
        case .resolved, .cancelled, .idle:
            inkOverlay?.hide()
        }
    }

    private func runPermissions() {
        orchestrator?.run { [weak self] matrix in
            guard let self else { return }
            // Arming is the watcher's job and only the watcher's job — one owner of the tap
            // lifecycle, so a walk that reports late can never stack a second tap or tear down a
            // live one. All this does is make the walk's answer visible immediately.
            Log.app.notice("permissions: \(matrix.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: " "))")
            Task { @MainActor in self.capabilityWatcher?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capabilityWatcher?.stop()
        hotkey.stop()
        actHotkey.stop()
    }
}
