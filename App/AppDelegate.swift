import AppKit
import Shared

/// Composition root. No dock icon, no windows: a status item and the pill.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var coordinator: DictationCoordinator?
    private var orchestrator: PermissionOrchestrator?
    private let hotkey = HotkeyService()
    private let pill = PillPanelController()
    private let updater: UpdaterProtocol = NoopUpdater()
    private let flags = FeatureFlagService.local()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent until Packaging installs Info.plist
        let database = try? AppDatabase.open()
        let engine: any EngineProtocol
        if let mock = try? MockEngine(fixtureNamed: ProcessInfo.processInfo.environment["VOICEPLUS_FIXTURE"] ?? "email_reply") {
            engine = mock
        } else {
            engine = MockEngine(fixture: TranscriptFixture(name: "inline", spans: [
                .init(text: "Hello from VoicePlus.", confidence: 0.95, audioStart: 0, audioEnd: 1, delayMs: 300),
            ]))
        }
        let coordinator = DictationCoordinator(engine: engine, database: database, pill: pill)
        self.coordinator = coordinator
        hotkey.onAction = { [weak coordinator] action in coordinator?.handle(action) }

        let status = StatusItemController(flags: flags, database: database, coordinator: coordinator, hotkey: hotkey, updater: updater)
        status.onRecheckPermissions = { [weak self] in self?.runPermissions() }
        statusItem = status

        let checker: PermissionChecking = ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1"
            ? MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
            : SystemPermissionChecker()
        orchestrator = PermissionOrchestrator(checker: checker, presentPrePrompt: PrePromptWindow.present)
        runPermissions()
        Log.app.info("VoicePlus shell up (Shared \(SharedModule.version))")
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
