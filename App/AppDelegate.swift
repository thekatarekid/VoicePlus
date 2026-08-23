import Actions
import AppKit
import Pipeline
import Shared

/// Composition root. No dock icon, no windows by default: a status item and the pill.
/// The heavy wiring lives in `AppContainer` (P1.12); this delegate only sequences launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var coordinator: DictationCoordinator?
    private var orchestrator: PermissionOrchestrator?
    private var container: AppContainer?
    private var transformPill: TransformPillDriver?
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
    private let updater: UpdaterProtocol = NoopUpdater()
    private let flags = FeatureFlagService.local()
    private let permissionChecker: PermissionChecking = ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1"
        ? MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        : SystemPermissionChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent until Packaging installs Info.plist
        AppContainer.ensureSupportDirectories()
        Task { @MainActor in
            var options = AppContainer.Options()
            options.flags = flags
            let container = await AppContainer.build(options: options)
            self.container = container
            self.wire(container)
        }
    }

    @MainActor
    private func wire(_ container: AppContainer) {
        let coordinator = DictationCoordinator(engine: container.engine, database: container.database, pill: pill)
        coordinator.lander = container.lander
        coordinator.onPrepare = { [weak container] in container?.prepareForUtterance() }
        coordinator.focusSnapshot = { [weak container] in container?.injector.focusGuard.snapshot() }
        coordinator.onLanded = { [weak container] result in
            // Focus moved mid-utterance: the request is queued; retry when the app comes back.
            if case .abortedFocusChanged? = result.injection {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { container?.injector.flushQueue() }
            }
        }
        container.audio?.onMicQuality = { [weak coordinator] q in
            DispatchQueue.main.async { coordinator?.noteMicQuality(q) }
        }
        self.coordinator = coordinator

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

        hotkey.onAction = { [weak coordinator, weak container, weak inkOverlay] action in
            switch action {
            case .startCapture:
                container?.deixis.beginCapture()
                Task { @MainActor in inkOverlay?.show() }
            case .finalize, .cancelCapture:
                container?.deixis.endCapture()
                Task { @MainActor in inkOverlay?.hide() }
            case .enterHandsFree:
                break
            }
            coordinator?.handle(action)
        }

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
        actHotkey.onAction = { [weak session, weak inkOverlay, weak container] action in
            if case .startCapture = action {
                container?.deixis.beginCapture()
                Task { @MainActor in inkOverlay?.show() }
            }
            if case .finalize = action { container?.deixis.endCapture(); Task { @MainActor in inkOverlay?.hide() } }
            if case .cancelCapture = action { container?.deixis.endCapture(); Task { @MainActor in inkOverlay?.hide() } }
            session?.handle(action)
        }
        SettingsWindowController.connectorHub = container.connectorHub

        // P5 — hands-free: wake-verb context flag rides the lander's augmenter chain; the
        // directed-speech gate opens the mic on addressed speech; hard mute pauses everything.
        let baseAugmenter = container.lander.contextAugmenter
        container.lander.contextAugmenter = { [weak coordinator] spans, ctx in
            var ctx = baseAugmenter?(spans, ctx) ?? ctx
            if coordinator?.handsFree == true {
                ctx.extra[WakeVerbPreRoute.modeKey] = WakeVerbPreRoute.handsFreeValue
            }
            return ctx
        }
        container.handsFree.isHandsFree = { [weak coordinator] in coordinator?.handsFree ?? false }
        container.handsFree.onShouldCapture = { [weak coordinator] _ in
            // Addressed speech opens the mic for the follow-on utterance (RAM-only ring;
            // nothing is stored). The engine's normal finalize path lands it.
            DispatchQueue.main.async { coordinator?.start() }
        }
        container.handsFree.mute.observe { [weak self, weak coordinator] model in
            DispatchQueue.main.async {
                coordinator?.setPaused(model.muted)
                self?.statusItem?.refreshIcon()
                if model.muted { self?.pill.model.present(.preview(text: "Muted — mic stays closed until you unmute")) }
            }
        }

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
        container.meeting.startMonitoring()

        let status = StatusItemController(flags: container.flags, database: container.database, coordinator: coordinator,
                                          hotkey: hotkey, updater: updater)
        status.activeModelName = { [weak container] in container?.activeModelName ?? "—" }
        status.micName = { [weak container] in container?.microphoneName ?? "Default microphone" }
        status.corrections = container.correction.ledger
        status.correctionSettings = container.settings
        status.correctionRevertSink = { [weak container] in container?.repair.replaceSink }
        status.onRecheckPermissions = { [weak self] in self?.runPermissions() }
        // P5.4 — ambient glyph + one-gesture hard mute; P5.3 — enrollment window.
        status.ambientSymbol = { [weak container] in
            guard let container, container.flags.isEnabled(.directedSpeech) else { return nil }
            return container.handsFree.ambientModel.menuBarSymbol
        }
        status.ambientMuted = { [weak container] in container?.handsFree.mute.isMuted ?? false }
        status.onToggleMute = { [weak container] in container?.handsFree.mute.toggleMute() }
        status.onEnrollVoice = { [weak self, weak container] in
            guard let self, let container else { return }
            self.showSpeakerEnrollment(container: container)
        }
        status.onOpenLab = { [weak container] in
            guard let container else { return }
            LabWindowController.showLab(registry: container.labRegistry, database: container.database)
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
        statusItem = status

        orchestrator = PermissionOrchestrator(checker: permissionChecker, presentPrePrompt: PrePromptWindow.present)
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
    /// prompted phrase); the finished profile arms the hands-free speaker gate.
    @MainActor
    private func showSpeakerEnrollment(container: AppContainer) {
        let model = SpeakerEnrollmentViewModel(embedder: container.handsFree.embedder) { [weak container] in
            guard let container else { return [] }
            container.audioTap.reset()
            try? await container.engine.start(prewarm: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = try? await container.engine.stop()
            return container.audioTap.samples
        }
        model.onComplete = { [weak container] profile in container?.handsFree.install(profile: profile) }
        SpeakerEnrollmentWindowController.show(model: model)
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
            pill.model.present(.preview(text: "Agent: \(String(describing: report.status))"))
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
            let caps = PermissionPlanner.capabilities(matrix)
            self.statusItem?.capabilities = caps
            if caps.canUseGlobalHotkey {
                self.hotkey.start()
                self.actHotkey.start()
            } else {
                self.hotkey.stop()
                self.actHotkey.stop()
            }
            Log.app.info("permissions: \(matrix.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: " "))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        actHotkey.stop()
    }
}
