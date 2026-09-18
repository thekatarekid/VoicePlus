import AppKit
import Combine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// S6 — the real `StatusItemController`, built headless (no status item), driven through the same
/// methods AppKit calls, with the real `SessionCoordinator` and `DictationCoordinator` over a counting
/// engine. Proves: opening or closing the menu never records; Start is click-to-stop; the quit guard
/// asks Stop and quit / Cancel during capture and saves held drafts first.
@Suite("Status menu controller (S6)")
struct StatusMenuControllerTests {
    /// Counts every capture call. `start` opens "the microphone" (state → listening).
    final class CountingEngine: EngineProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private let subject = CurrentValueSubject<EngineState, Never>(.idle)
        private let broadcaster = EngineEventBroadcaster()
        private var current: EngineState = .idle
        private var counts = (starts: 0, stops: 0, cancels: 0)

        var starts: Int { lock.withLock { counts.starts } }
        var stops: Int { lock.withLock { counts.stops } }
        var cancels: Int { lock.withLock { counts.cancels } }

        var state: EngineState { lock.withLock { current } }
        var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
        func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
        func prewarm() async throws {}
        func start(prewarm: Bool) async throws {
            lock.withLock { counts.starts += 1 }
            set(.listening(level: 0.2))
        }
        func stop() async throws -> [TranscriptSpan] {
            lock.withLock { counts.stops += 1 }
            set(.idle)
            return []
        }
        func cancel() async {
            lock.withLock { counts.cancels += 1 }
            set(.idle)
        }
        func set(_ state: EngineState) {
            lock.withLock { current = state }
            subject.send(state)
        }
    }

    final class Recorder {
        var prompts: [MenuQuit.Prompt] = []
        var confirm = false
        var terminated = 0
        var openedWindow = 0
        var reviewed = 0
        var stoppedMeetings = 0
    }

    @MainActor
    struct Rig {
        let engine = CountingEngine()
        let dictation: DictationCoordinator
        let session: SessionCoordinator
        let controller: StatusItemController
        let recorder = Recorder()

        init(database: AppDatabase? = nil) {
            dictation = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
            session = SessionCoordinator(dictation: dictation, mute: MuteController(store: InMemoryMuteStore()))
            session.observeMute()
            controller = StatusItemController(flags: FeatureFlagService.inMemory(), database: database,
                                              coordinator: dictation,
                                              hotkey: HotkeyService(defaults: UserDefaults(suiteName: "AppTests.menu.\(UUID())")!),
                                              updater: NoopUpdater(), statusBar: nil)
            controller.session = session
            controller.capabilities = PresenceInputs.allCapabilities
            controller.micName = { "MacBook Pro Microphone" }
            let recorder = recorder
            controller.confirmQuit = { prompt in
                recorder.prompts.append(prompt)
                return recorder.confirm
            }
            controller.terminateApp = { recorder.terminated += 1 }
            controller.onOpenWindow = { recorder.openedWindow += 1 }
        }

        /// Everything AppKit does when the menu is opened from `entryPoint` and closed again.
        func openAndClose(from entryPoint: MenuEntryPoint = .glyph) {
            _ = controller.menuEntries(from: entryPoint)
            controller.menuNeedsUpdate(controller.menu)
            controller.menuWillOpen(controller.menu)
            controller.refreshIcon()
            _ = controller.accessibilityLabel()
            controller.menuDidClose(controller.menu)
        }

        func row(_ id: String) -> MenuEntry? { StatusMenuSpec.entry(id, in: controller.menuEntries()) }

        func settle() async { await dictation.settle() }
    }

    // MARK: Opening never records

    @Test @MainActor func openingAndClosingTheMenuNeverRecords() async {
        let rig = Rig()
        for entryPoint in MenuEntryPoint.allCases { rig.openAndClose(from: entryPoint) }
        await rig.settle()
        #expect(rig.engine.starts == 0 && rig.engine.stops == 0 && rig.engine.cancels == 0)
        #expect(rig.session.activeRequester == nil)
        #expect(!rig.dictation.isSessionHeld)
        // The rows were built — this was a real open, not a no-op.
        #expect(rig.controller.menu.items.count == StatusMenuSpec.entries(rig.controller.menuState()).count)
        #expect(rig.controller.menu.items.first?.identifier?.rawValue == StatusMenuSpec.ID.status)
        #expect(rig.controller.menu.items.first?.title.hasPrefix("VoicePlus · Ready") == true)
        #expect(rig.controller.accessibilityLabel() == "VoicePlus · Ready")
    }

    // MARK: Start dictation is click-to-stop

    @Test @MainActor func startFromTheMenuRecordsUntilStop() async {
        let rig = Rig()
        rig.controller.run(.startDictation)
        await rig.settle()
        #expect(rig.engine.starts == 1)
        #expect(rig.session.activeRequester == .menu)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.title == "Stop")
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.action == .stopDictation)
        #expect(rig.row(StatusMenuSpec.ID.status)?.title == "VoicePlus · Listening")

        // Closing (and reopening) the menu does not change recording.
        rig.openAndClose()
        rig.openAndClose(from: .notch)
        // There is no key to release: a hotkey release cannot end a session the menu holds.
        rig.session.handle(.finalize)
        await rig.settle()
        #expect(rig.engine.stops == 0 && rig.engine.cancels == 0)
        #expect(rig.session.activeRequester == .menu && rig.dictation.isSessionHeld)

        // Only the explicit Stop does.
        rig.controller.run(.stopDictation)
        await rig.settle()
        #expect(rig.engine.stops == 1)
        #expect(rig.session.activeRequester == nil && !rig.dictation.isSessionHeld)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.title == "Start dictation")
        #expect(rig.row(StatusMenuSpec.ID.status)?.title == "VoicePlus · Ready")
    }

    @Test @MainActor func statusLineFollowsTheEngineHonestly() {
        let rig = Rig()
        rig.engine.set(.starting)
        #expect(rig.controller.menuState().status == .starting)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.title == "Stop")
        rig.engine.set(.finishing)
        #expect(rig.controller.menuState().status == .finishing)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.isEnabled == false)
        rig.engine.set(.prewarming)
        #expect(rig.controller.menuState().status == .ready)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.action == .startDictation)
        rig.controller.meetingRunning = { true }
        rig.engine.set(.idle)
        #expect(rig.controller.menuState().status == .meeting)
        // The key needs a grant it lacks: blocked, and the menu's Start is the way to dictate.
        rig.controller.meetingRunning = nil
        rig.controller.capabilities = .init(canCapture: true, canUseGlobalHotkey: false, canInjectText: true)
        #expect(rig.controller.menuState().status == .blocked(.hotkeyUnavailable))
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.action == .startDictation)
        rig.controller.capabilities = .init(canCapture: false, canUseGlobalHotkey: true, canInjectText: true)
        rig.controller.meetingRunning = nil
        #expect(rig.controller.menuState().status == .blocked(.microphoneDenied))
        #expect(rig.controller.accessibilityLabel() == "VoicePlus · Blocked")
    }

    // MARK: Mute

    @Test @MainActor func muteClosesCaptureAndNeverResumes() async {
        let rig = Rig()
        rig.controller.run(.startDictation)
        await rig.settle()
        rig.controller.run(.toggleMute)
        await rig.settle()
        #expect(rig.session.isMuted)
        #expect(rig.engine.cancels >= 1 && rig.session.activeRequester == nil)
        #expect(rig.row(StatusMenuSpec.ID.status)?.title == "VoicePlus · Muted")
        #expect(rig.row(StatusMenuSpec.ID.mute)?.isOn == true)
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.isEnabled == false)

        rig.controller.run(.toggleMute)
        await rig.settle()
        #expect(!rig.session.isMuted)
        #expect(rig.engine.starts == 1, "unmuting started a capture")
        #expect(rig.row(StatusMenuSpec.ID.dictate)?.action == .startDictation)
    }

    // MARK: Held and the window

    @Test @MainActor func heldRowReviewsInTheWindow() {
        let rig = Rig()
        let store = HeldTextStore()
        store.hold(text: "the first thing I said", destination: "Notes", reason: "destination changed")
        store.hold(text: "and the second", destination: "Mail", reason: "destination changed")
        rig.controller.heldItems = { store.items }
        #expect(rig.row(StatusMenuSpec.ID.held)?.title == "2 held dictations")
        rig.controller.run(.reviewHeld)
        #expect(rig.recorder.openedWindow == 1)
        rig.controller.onReviewHeld = { rig.recorder.reviewed += 1 }
        rig.controller.run(.reviewHeld)
        #expect(rig.recorder.reviewed == 1 && rig.recorder.openedWindow == 1)
        // Reviewing touches nothing held.
        #expect(store.count == 2)
    }

    @Test @MainActor func heldCountsFromTheFocusGuardQueue() {
        let rig = Rig()
        let guardian = FocusGuard(system: MockSystemAccess())
        guardian.hold(InjectionRequest(text: "held by injection"), reason: "destination changed",
                      destination: FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes"))
        rig.controller.focusGuard = guardian
        #expect(rig.row(StatusMenuSpec.ID.held)?.title == "1 held dictation")
        rig.openAndClose()
        #expect(guardian.held.count == 1)
    }

    // MARK: Quit

    @Test @MainActor func quitWhenIdleQuits() {
        let rig = Rig()
        rig.controller.run(.quit)
        #expect(rig.recorder.prompts.isEmpty && rig.recorder.terminated == 1)
    }

    @Test @MainActor func quitDuringCaptureAsksStopAndQuitOrCancel() async {
        let rig = Rig()
        rig.controller.run(.startDictation)
        await rig.settle()

        rig.recorder.confirm = false
        rig.controller.run(.quit)
        await rig.settle()
        let prompt = rig.recorder.prompts.first
        #expect(prompt?.confirm == "Stop and quit" && prompt?.cancel == "Cancel")
        #expect(prompt?.message.contains(MenuQuit.dictationLine) == true)
        // Cancel: nothing quits and the recording carries on.
        #expect(rig.recorder.terminated == 0)
        #expect(rig.engine.cancels == 0 && rig.session.activeRequester == .menu && rig.dictation.isSessionHeld)

        rig.recorder.confirm = true
        rig.controller.run(.quit)
        await rig.settle()
        #expect(rig.recorder.prompts.count == 2)
        #expect(rig.recorder.terminated == 1)
        #expect(rig.engine.cancels == 1 && rig.engine.stops == 0, "Stop and quit must not type a half-finished pass")
        #expect(rig.session.activeRequester == nil && !rig.dictation.isSessionHeld)
    }

    @Test @MainActor func quitDuringAMeetingStopsIt() {
        let rig = Rig()
        rig.controller.meetingRunning = { true }
        rig.controller.onStopMeeting = { rig.recorder.stoppedMeetings += 1 }
        rig.recorder.confirm = true
        rig.controller.run(.quit)
        #expect(rig.recorder.prompts.first?.message == MenuQuit.meetingLine)
        #expect(rig.recorder.stoppedMeetings == 1 && rig.recorder.terminated == 1)
    }

    @Test @MainActor func heldDraftsAreSavedBeforeQuitting() throws {
        let db = try AppDatabase.inMemory()
        let rig = Rig(database: db)
        let store = HeldTextStore()
        store.hold(text: "words with nowhere to go", destination: "Notes", reason: "destination changed")
        rig.controller.heldItems = { store.items }
        rig.controller.run(.quit)
        #expect(rig.recorder.prompts.isEmpty, "a saved draft should not need a warning")
        #expect(rig.recorder.terminated == 1)
        #expect(try db.recentDictations(limit: 10).map(\.finalText) == ["words with nowhere to go"])
    }

    @Test @MainActor func anUnsavableDraftGetsTheUnsavedDataWarning() {
        let rig = Rig(database: nil)
        let store = HeldTextStore()
        let item = store.hold(text: "words with nowhere to go", destination: "Notes", reason: "destination changed")
        rig.controller.heldItems = { store.items }
        rig.recorder.confirm = false
        rig.controller.run(.quit)
        let prompt = rig.recorder.prompts.first
        #expect(prompt?.confirm == "Quit anyway" && prompt?.stopsCapture == false)
        #expect(prompt?.message.contains(HeldMenu.header(for: item)) == true)
        #expect(rig.recorder.terminated == 0 && store.count == 1)
    }

    // MARK: Rendering

    @Test @MainActor func rowsRenderAsTheSpecSays() {
        let rig = Rig()
        rig.controller.menuNeedsUpdate(rig.controller.menu)
        let items = rig.controller.menu.items
        let status = items.first
        #expect(status?.identifier?.rawValue == StatusMenuSpec.ID.status)
        #expect(status?.image?.isTemplate == true)
        #expect(status?.image?.size == MenuBarGlyph.menuHeadingSize)
        #expect(status?.isEnabled == false)
        // The helper line is the subtitle, or the attributed title's second line where macOS 14 would
        // hide a subtitle behind the ready dot.
        let statusText = Self.visibleText(status)
        #expect(statusText.contains("VoicePlus · Ready") && statusText.contains("Microphone is closed."))
        #expect(statusText.contains(MenuItemText.dot) || status?.attributedTitle?.string.contains(MenuItemText.dot) == true)
        // The dot is decoration: VoiceOver hears the words.
        #expect(status?.accessibilityLabel() == "VoicePlus · Ready, Microphone is closed.")

        let dictate = items.first { $0.identifier?.rawValue == StatusMenuSpec.ID.dictate }
        #expect(dictate?.keyEquivalent == "d" && dictate?.isEnabled == true && dictate?.action != nil)
        #expect(Self.visibleText(dictate).contains("Menu capture has an explicit Stop control."))
        let quit = items.first { $0.identifier?.rawValue == StatusMenuSpec.ID.quit }
        #expect(quit?.keyEquivalent == "q")
        #expect(items.filter(\.isSeparatorItem).count == 3)
        #expect(items.filter { $0.image != nil }.count == 1, "only the status line carries the glyph")

        rig.controller.run(.toggleMute)
        let mute = rig.controller.menu.items.first { $0.identifier?.rawValue == StatusMenuSpec.ID.mute }
        #expect(mute?.state == .on)
        let muted = rig.controller.menu.items.first
        #expect(!(Self.visibleText(muted).contains(MenuItemText.dot)), "the ready dot shows only when ready")
    }

    static func visibleText(_ item: NSMenuItem?) -> String {
        guard let item else { return "" }
        var text = item.attributedTitle?.string ?? item.title
        if #available(macOS 14.4, *), let subtitle = item.subtitle { text += "\n" + subtitle }
        return text
    }
}
