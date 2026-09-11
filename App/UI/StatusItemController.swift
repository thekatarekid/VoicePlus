import AppKit
import Engine
import Injection
import Shared

/// The menu-bar item and **the one menu** (R7.3, V3 §9.2–9.3, `DESIGN.md` §10).
///
/// One menu, four ways in: left click and right click on the glyph, left click and ⌃/right click on
/// the notch presence chin (`PresenceClickRouter` answers `.menu` for every state and every button,
/// and `AppDelegate` routes the chin's click to `popUpMenu(from:)`). The rows are decided by
/// `StatusMenuSpec` — pure data, so the menu can be tested without an `NSStatusItem`, an XCTest or a
/// UI test, none of which exist on this toolchain.
///
/// **Focus.** Opening the menu never activates the app: the status item pops the menu itself, the
/// chin behind it is a non-activating panel, and building the rows reads no focus and touches no
/// held text. Dictation still has somewhere to land afterwards (DESIGN §5.3).
///
/// **What is deliberately *not* here** (DESIGN §10, "Removed from today's menu"): the Lab, the Data
/// Panel, feature flags, the two key submenus, "Enroll voice…", the presence-indicator switch,
/// launch at login, update and permission checks. All of them live in the one window — keeping them
/// here as well would make two sources of truth. The callbacks below stay so the composition root
/// keeps compiling while R7.1/R7.2 finish hosting them.
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let flags: FeatureFlagService
    private let database: AppDatabase?
    private let coordinator: DictationCoordinator
    private let hotkey: HotkeyService
    private let updater: UpdaterProtocol
    /// R7.1 — the one window, at Today. Falls back to `onOpenSettings` until the window exists.
    public var onOpenWindow: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Kept for the composition root; no longer menu rows (DESIGN §10 — they live in the window).
    public var onOpenLab: (() -> Void)?
    public var onOpenDataPanel: (() -> Void)?
    public var onRecheckPermissions: (() -> Void)?
    public var onEnrollVoice: (() -> Void)?
    public var presenceIndicatorEnabled: (() -> Bool)?
    public var onTogglePresenceIndicator: (() -> Void)?
    public var corrections: CorrectionLedger?
    public var correctionSettings: SettingsStore?
    public var correctionRevertSink: (() -> ReplaceRangeSink?)?
    public var actHotkey: HotkeyService?
    public var actKeyStore: SettingsStore?
    /// Live labels supplied by the composition root (P1.12); defaults keep shell tests unchanged.
    public var activeModelName: () -> String = { "Mock engine (fixture)" }
    public var micName: () -> String = { "Default microphone" }
    /// R3 — the session owner. Start, Stop and mic arbitration go through it; the engine is never
    /// called directly from here. Nil falls back to `DictationCoordinator` (shell tests).
    public var session: SessionCoordinator?
    /// R3.1 — latch on/off. Nil uses `session`/`coordinator` directly.
    public var onToggleLatch: (() -> Void)?
    /// P5.4 — ambient state glyph + one-gesture hard mute (`MuteController`).
    public var ambientSymbol: (() -> String?)?
    public var ambientMuted: (() -> Bool)?
    public var onToggleMute: (() -> Void)?
    /// The chin's state, so the menu's first line says exactly what the chin says. Nil derives a
    /// conservative one from mute / capabilities / capture.
    public var presenceState: (() -> PresenceState)?
    /// "Copy last text". Nil reads the most recent dictation out of the database.
    public var lastCommittedText: (() -> String?)?
    /// P5.5 — meeting capture opt-in. Toggling it on is what asks for Calendar access.
    public var meetingCaptureEnabled: (() -> Bool)?
    public var onToggleMeetingCapture: (() -> Void)?
    /// R7.3 — an actual meeting recording, and the explicit stop for it.
    public var meetingRunning: (() -> Bool)?
    public var onStartMeeting: (() -> Void)?
    public var onStopMeeting: (() -> Void)?
    public var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// R2.4 — committed text with no safe destination (V3 §6). The menu carries the same three
    /// actions as the held pill row, off the same queue; Quit warns while anything is held.
    public var heldItems: (() -> [HeldItem])?
    public var onHeldAction: ((HeldItem, HeldAction) -> Void)?
    /// `Injection`'s own queue, used when the app-side mirror is not wired.
    public var focusGuard: FocusGuard?
    public var capabilities: PermissionPlanner.Capabilities = .init(canCapture: false, canUseGlobalHotkey: false, canInjectText: false)
    /// Which gesture opened the menu last. Logged, never branched on (V3 §9.3).
    public private(set) var lastEntryPoint: MenuEntryPoint = .glyph
    /// Set by `popUpMenu(from:)` so AppKit's own `menuNeedsUpdate` does not relabel a chin click.
    private var pendingEntryPoint: MenuEntryPoint?

    public init(flags: FeatureFlagService, database: AppDatabase?, coordinator: DictationCoordinator,
                hotkey: HotkeyService, updater: UpdaterProtocol) {
        self.flags = flags
        self.database = database
        self.coordinator = coordinator
        self.hotkey = hotkey
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        // Enablement is the spec's answer, not AppKit's guess: an unavailable action stays visible
        // and disabled with the reason in its title (DESIGN §10).
        menu.autoenablesItems = false
        // A status item with a menu pops it on **both** buttons, which is half of "one menu".
        statusItem.menu = menu
        statusItem.button?.toolTip = "VoicePlus"
        refreshIcon()
    }

    public func model() -> MenuModel {
        let stats = database.map { MenuModel.load(from: $0) } ?? (zeroEdit: 0, total: 0, wordsToday: 0)
        return MenuModel(zeroEditCount: stats.zeroEdit, totalCount: stats.total, wordsToday: stats.wordsToday,
                         activeModel: activeModelName(), micName: micName(),
                         micStatus: coordinator.lastMicQuality?.verdict, paused: coordinator.paused,
                         latched: coordinator.latched, hotkeyName: hotkey.binding.kind.displayName,
                         launchAtLogin: LaunchAtLogin.isEnabled)
    }

    public func refreshIcon() {
        let m = model()
        // P5.4 — ambient three-state glyph (listening/muted/processing) wins when latch is wired.
        let symbol = ambientSymbol?() ?? m.statusSymbol
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoicePlus")
        statusItem.button?.appearsDisabled = m.paused || ambientMuted?() == true
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        lastEntryPoint = pendingEntryPoint ?? .glyph
        pendingEntryPoint = nil
        rebuild()
    }

    /// The presence chin pops this same menu — that is the point of the chin: when macOS has culled
    /// the status item from a crowded menu bar, it is the remaining way into Stop, Mute, recovery
    /// and Quit. Popping a menu takes no focus from the app being typed into.
    public func popUpMenu(at point: NSPoint = NSEvent.mouseLocation, from entryPoint: MenuEntryPoint = .notch) {
        lastEntryPoint = entryPoint
        pendingEntryPoint = entryPoint
        rebuild()
        Log.app.notice("menu opened from \(entryPoint.rawValue)")
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    // MARK: - The state the menu is a function of

    /// Pure with respect to focus: nothing here reads the frontmost app or dequeues held text.
    public func menuState() -> StatusMenuState {
        let muted = ambientMuted?() ?? session?.isMuted ?? false
        let capturing = session?.activeRequester != nil || coordinator.engine.state.isActive
        let latched = session?.isLatched ?? coordinator.latched
        return StatusMenuState(presence: presenceState?() ?? derivedPresence(muted: muted, capturing: capturing),
                               micName: micName(), micStatus: coordinator.lastMicQuality?.verdict,
                               micAvailable: capabilities.canCapture,
                               isCapturing: capturing, isLatched: latched, isMuted: muted,
                               hasLastText: lastText() != nil, held: heldSummaries(),
                               meeting: meetingState())
    }

    public func menuEntries(from entryPoint: MenuEntryPoint? = nil) -> [MenuEntry] {
        StatusMenuSpec.entries(menuState(), from: entryPoint ?? lastEntryPoint)
    }

    /// Only the microphone can block dictation here: a missing *hotkey* permission must not disable
    /// "Start dictation", because the menu is exactly the fallback for that case.
    private func derivedPresence(muted: Bool, capturing: Bool) -> PresenceState {
        if muted { return .muted }
        if !capabilities.canCapture { return .blocked(.microphoneDenied) }
        if coordinator.paused { return .paused }
        switch coordinator.engine.state {
        case .listening(let level): return .listening(level: level)
        case .previewing: return .listening(level: 0)
        case .finalizing: return .processing
        default: return capturing ? .listening(level: 0) : .ready
        }
    }

    private func heldSummaries() -> [StatusMenuState.Held] {
        if let heldItems { return heldItems().map(StatusMenuState.Held.init) }
        if let focusGuard { return HeldMenuRouter.held(in: focusGuard) }
        return []
    }

    private func lastText() -> String? {
        if let lastCommittedText { return lastCommittedText().flatMap { $0.isEmpty ? nil : $0 } }
        guard let database, let record = (try? database.recentDictations(limit: 1))?.first,
              !record.finalText.isEmpty else { return nil }
        return record.finalText
    }

    private func meetingState() -> StatusMenuState.Meeting {
        if meetingRunning?() == true { return .running }
        if let meetingCaptureEnabled, onToggleMeetingCapture != nil, !meetingCaptureEnabled() {
            return .needsCalendarAccess
        }
        return .idle(canStart: onStartMeeting != nil)
    }

    // MARK: - Rendering

    func rebuild() {
        menu.removeAllItems()
        render(menuEntries(), into: menu)
    }

    private func render(_ entries: [MenuEntry], into menu: NSMenu) {
        for entry in entries {
            guard !entry.isSeparator else { menu.addItem(.separator()); continue }
            let hasAction = entry.action != nil && entry.isEnabled
            let item = NSMenuItem(title: entry.title,
                                  action: hasAction ? #selector(performEntry(_:)) : nil,
                                  keyEquivalent: entry.keyEquivalent)
            item.target = hasAction ? self : nil
            item.isEnabled = entry.isEnabled
            item.state = entry.isOn ? .on : .off
            item.representedObject = entry.id
            item.identifier = NSUserInterfaceItemIdentifier(entry.id)
            // The one red-tinted row (DESIGN §10): mute is a promise about the microphone.
            if entry.isDestructive {
                item.attributedTitle = NSAttributedString(string: entry.title,
                                                          attributes: [.foregroundColor: NSColor.systemRed])
            }
            if !entry.children.isEmpty {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                render(entry.children, into: submenu)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    @objc private func performEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = StatusMenuSpec.entry(id, in: menuEntries()), let action = entry.action else { return }
        run(action)
    }

    // MARK: - Doing what the row says

    func run(_ action: MenuAction) {
        switch action {
        case .startDictation: startDictation()
        case .stopDictation: stopDictation()
        case .toggleLatch: toggleLatch()
        case .toggleMute: toggleMute()
        case .copyLastText: copyLastText()
        case .held(let id, let heldAction): performHeld(id: id, action: heldAction)
        case .enableMeetingCapture: onToggleMeetingCapture?()
        case .startMeeting: onStartMeeting?() ?? onToggleMeetingCapture?()
        case .stopMeeting: onStopMeeting?()
        case .openWindow: (onOpenWindow ?? onOpenSettings)?()
        case .openSettings: onOpenSettings?()
        case .quit: quitVoicePlus()
        }
        refreshIcon()
        rebuild()
    }

    /// R3 — through the session owner, so mic arbitration and mute are honoured.
    private func startDictation() {
        if let session { session.start(.menu, mode: .hold) } else { coordinator.start() }
    }

    /// The explicit Stop V3 §9.3 asks for: it stops whoever holds the microphone, not only the menu.
    private func stopDictation() {
        if let session { session.stop(session.activeRequester ?? .menu, reason: .userStopped) }
        else { coordinator.finalize() }
    }

    private func toggleLatch() {
        if let onToggleLatch { onToggleLatch(); return }
        if let session {
            if session.isLatched { session.stop(session.activeRequester ?? .menu, reason: .userStopped) }
            else { session.start(.menu, mode: .latched) }
        } else if coordinator.latched {
            coordinator.endLatch()
        } else {
            coordinator.handle(.enterLatch)
        }
    }

    private func toggleMute() { onToggleMute?() }

    private func copyLastText() {
        guard let text = lastText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.app.info("copied the last \(text.count) dictated characters from the menu")
    }

    private func performHeld(id: UUID, action: HeldAction) {
        if let onHeldAction, let item = heldItems?().first(where: { $0.id == id }) {
            onHeldAction(item, action)
        } else if let focusGuard {
            HeldMenuRouter.perform(action, on: id, in: focusGuard)
        }
    }

    @objc private func quitVoicePlus() {
        switch QuitGuard.decision(heldCount: heldSummaries().count) {
        case .quit:
            NSApp.terminate(nil)
        case .warn(let title, let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: QuitGuard.quitAnyway)
            alert.addButton(withTitle: QuitGuard.keepRunning)
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
    }

    /// The one line that says what a binding costs. Pure and static so the copy is unit-testable
    /// without a status item — and so "no permission" cannot quietly become a lie if the selection
    /// rule changes: it is derived from `HotkeyBackendSelector`, not written by hand per case.
    /// The picker itself is Settings › Keys now (DESIGN §10); this sentence is shown there.
    static func permissionNote(for kind: HotkeyBinding.Kind, forcingEventTap: Bool) -> String {
        let backend = HotkeyBackendSelector.kind(for: HotkeyBinding(kind: kind), forceEventTap: forcingEventTap)
        guard let permission = backend.requiredPermission else {
            switch backend {
            case .globalMonitor: return "Global key monitor — no extra permission"
            case .carbon: return "System hotkey — no extra permission"
            case .eventTap: return "Event tap"
            }
        }
        return "Legacy event tap — needs \(permission.title), and a quit & reopen"
    }
}
