import Actions
import AppKit
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
    private let hotkey = HotkeyService()
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

        let status = StatusItemController(flags: container.flags, database: container.database, coordinator: coordinator,
                                          hotkey: hotkey, updater: updater)
        status.activeModelName = { [weak container] in container?.activeModelName ?? "—" }
        status.micName = { [weak container] in container?.microphoneName ?? "Default microphone" }
        status.corrections = container.correction.ledger
        status.correctionSettings = container.settings
        status.correctionRevertSink = { [weak container] in container?.repair.replaceSink }
        status.onRecheckPermissions = { [weak self] in self?.runPermissions() }
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
            if caps.canUseGlobalHotkey { self.hotkey.start() } else { self.hotkey.stop() }
            Log.app.info("permissions: \(matrix.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: " "))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { hotkey.stop() }
}
