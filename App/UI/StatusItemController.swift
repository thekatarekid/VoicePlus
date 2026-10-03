import AppKit
import Engine
import Injection
import Shared

/// The menu-bar item and **the one menu** (design §4 "menu-bar identity", §8.8; `DESIGN.md` §8.4, §10).
///
/// **The glyph.** The status item shows `MenuBarGlyph` — the prototype's black-and-white cassette
/// outline, a template image at 18 × 16 pt. It is never tinted, never dimmed, never swapped for an SF
/// symbol or the detailed Spool, and it does not change with state: the state is the menu's first
/// line ("VoicePlus · Ready" / "Muted" / "Blocked"), and the item's accessibility label says the same.
///
/// **One menu, four ways in:** left and right click on the glyph, left and ⌃/right click on the notch
/// presence chin (`PresenceClickRouter` answers `.menu` for every state and button, and `AppDelegate`
/// routes the chin's click to `popUpMenu(from:)`). The rows are decided by `StatusMenuSpec` — pure
/// data, so the menu is tested without an `NSStatusItem`, an XCTest or a UI test.
///
/// **Opening the menu never records, and closing it never changes recording.** Building the rows
/// reads plain properties; nothing on the open or close path calls the session, the engine, the
/// focus guard or the held queue. Only choosing Start dictation opens the microphone — as explicit
/// click-to-stop capture through `SessionCoordinator` — and only Stop, Mute or the quit guard close it.
///
/// **Focus.** Opening the menu never activates the app: the status item pops the menu itself, the
/// chin behind it is a non-activating panel. Dictation still has somewhere to land afterwards.
public final class StatusItemController: NSObject, NSMenuDelegate {
    /// Nil when built headless (tests), where no status bar is touched.
    private let statusItem: NSStatusItem?
    let menu = NSMenu()
    private let flags: FeatureFlagService
    private let database: AppDatabase?
    private let coordinator: DictationCoordinator
    private let hotkey: HotkeyService
    private let updater: UpdaterProtocol
    /// Drawn once; the same template image for the life of the item.
    private lazy var glyph = MenuBarGlyph.image()

    /// The one window, at Today. Falls back to `onOpenSettings` until the window exists.
    public var onOpenWindow: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// "Review" on the held-dictations row. Nil opens the one window at Today, where held drafts are.
    public var onReviewHeld: (() -> Void)?
    /// V5 N1 — the "N new notes" row; and how many there are. Nil opens the window (its Notes section
    /// is one click away).
    public var onOpenNotes: (() -> Void)?
    public var notesUnread: (() -> Int)?
    /// Kept for the composition root; not menu rows (`DESIGN.md` §10 — they live in the window).
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
    /// Kept for the composition root: latch is Settings › Shortcuts, not a menu row (`DESIGN.md` §10).
    public var onToggleLatch: (() -> Void)?
    /// Kept for the composition root: the glyph no longer changes with the ambient state (S6).
    public var ambientSymbol: (() -> String?)?
    /// P5.4 — hard mute (`MuteController`).
    public var ambientMuted: (() -> Bool)?
    /// Nil toggles `session.mute` directly.
    public var onToggleMute: (() -> Void)?
    /// V5 L1 — the ambient mode row (segmented Off · Listen & note · Listen & act). Nil: no row.
    public var ambientModeController: AmbientModeController?
    /// The presence reducer's state, when wired: the source of blockers the menu cannot derive
    /// (hotkey permission, relaunch, a model download).
    public var presenceState: (() -> PresenceState)?
    /// Kept for the composition root: Copy last text is a Today action, not a menu row.
    public var lastCommittedText: (() -> String?)?
    /// H32 — the Recent rows' source (`TurnStore.recentDictations`, wired by `AppDelegate`). Nil →
    /// no Recent group (headless tests that do not opt in).
    public var recentDictations: (() -> [RecentDictation])?
    /// H32 — the verified copy for one row (`TurnStore.copyRecent`): true only on read-back.
    public var copyRecent: ((TurnID) -> Bool)?
    /// H32 — told after a Recent copy, with whether the read-back verified it.
    public var onRecentCopied: ((TurnID, Bool) -> Void)?
    /// H32 — the row most recently copied (verified) and when; it reads "Copied" for `copiedDwell`.
    public private(set) var lastCopied: (id: TurnID, at: Date)?
    public var copiedDwell: TimeInterval = 2
    public var now: () -> Date = Date.init
    /// Kept for the composition root: meeting start is the Meetings section, not a menu row.
    public var meetingCaptureEnabled: (() -> Bool)?
    public var onToggleMeetingCapture: (() -> Void)?
    public var onStartMeeting: (() -> Void)?
    /// A meeting recording is open: the status line says so, and the quit guard stops it.
    public var meetingRunning: (() -> Bool)?
    public var onStopMeeting: (() -> Void)?
    public var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// R2.4 — committed text with no safe destination (V3 §6). Counted in the menu; saved to history
    /// before quitting.
    public var heldItems: (() -> [HeldItem])?
    /// Kept for the composition root: held actions are the pill's and the recovery surface's.
    public var onHeldAction: ((HeldItem, HeldAction) -> Void)?
    /// `Injection`'s own queue, used when the app-side mirror is not wired.
    public var focusGuard: FocusGuard?
    public var capabilities: PermissionPlanner.Capabilities = .init(canCapture: false, canUseGlobalHotkey: false, canInjectText: false)
    /// Asks the user about a guarded quit; true means confirm. Injectable for tests.
    public var confirmQuit: (MenuQuit.Prompt) -> Bool = StatusItemController.runQuitAlert
    /// Ends the process. Injectable for tests.
    public var terminateApp: () -> Void = { NSApp.terminate(nil) }
    /// Which gesture opened the menu last. Logged, never branched on (V3 §9.3).
    public private(set) var lastEntryPoint: MenuEntryPoint = .glyph
    /// Set by `popUpMenu(from:)` so AppKit's own `menuNeedsUpdate` does not relabel a chin click.
    private var pendingEntryPoint: MenuEntryPoint?

    public convenience init(flags: FeatureFlagService, database: AppDatabase?, coordinator: DictationCoordinator,
                            hotkey: HotkeyService, updater: UpdaterProtocol) {
        self.init(flags: flags, database: database, coordinator: coordinator, hotkey: hotkey, updater: updater,
                  statusBar: .system)
    }

    /// `statusBar: nil` builds the controller headless — no status item — for tests.
    init(flags: FeatureFlagService, database: AppDatabase?, coordinator: DictationCoordinator,
         hotkey: HotkeyService, updater: UpdaterProtocol, statusBar: NSStatusBar?) {
        self.flags = flags
        self.database = database
        self.coordinator = coordinator
        self.hotkey = hotkey
        self.updater = updater
        statusItem = statusBar?.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        // Enablement is the spec's answer, not AppKit's guess: an unavailable action stays visible
        // and disabled with the reason in its title (`DESIGN.md` §10).
        menu.autoenablesItems = false
        // A status item with a menu pops it on **both** buttons, which is half of "one menu".
        statusItem?.menu = menu
        statusItem?.button?.toolTip = "VoicePlus"
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

    /// The glyph is fixed; only the accessibility label follows the state, so VoiceOver hears what
    /// the menu's first line says without the icon ever changing colour or shape.
    public func refreshIcon() {
        guard let button = statusItem?.button else { return }
        if button.image !== glyph {
            button.image = glyph
            button.imagePosition = .imageOnly
        }
        button.contentTintColor = nil
        button.appearsDisabled = false
        button.setAccessibilityLabel(accessibilityLabel())
    }

    /// "VoicePlus · Ready", "VoicePlus · Muted", "VoicePlus · Blocked" — the status line's title.
    public func accessibilityLabel() -> String { StatusMenuSpec.status(menuState()).title }

    // MARK: - Opening and closing

    public func menuNeedsUpdate(_ menu: NSMenu) {
        lastEntryPoint = pendingEntryPoint ?? .glyph
        pendingEntryPoint = nil
        rebuild()
    }

    /// Opening is a read: the rows were built in `menuNeedsUpdate`; nothing here starts anything.
    public func menuWillOpen(_ menu: NSMenu) {
        Log.app.debug("menu open from \(self.lastEntryPoint.rawValue)")
    }

    /// Closing changes nothing: a capture started from the menu keeps recording until Stop.
    public func menuDidClose(_ menu: NSMenu) {
        Log.app.debug("menu closed")
    }

    /// The presence chin pops this same menu — that is the point of the chin: when macOS has culled
    /// the status item from a crowded menu bar, it is the remaining way into Stop, Mute and Quit.
    /// Popping a menu takes no focus from the app being typed into.
    public func popUpMenu(at point: NSPoint = NSEvent.mouseLocation, from entryPoint: MenuEntryPoint = .notch) {
        lastEntryPoint = entryPoint
        pendingEntryPoint = entryPoint
        rebuild()
        Log.app.notice("menu opened from \(entryPoint.rawValue)")
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// H33 — the menu's natural size (no minimum width), rebuilt as it is about to be shown. The
    /// hover pill uses it to pick the shared width W.
    public func naturalMenuSize() -> NSSize {
        pendingEntryPoint = .notch
        rebuild()
        menu.minimumWidth = 0
        return menu.size
    }

    /// H33 — hover: the real menu, centred under the expanded pill at the shared width W
    /// (`PresenceMenuHover.Placement`). Blocks while the menu tracks, like any `popUp`.
    ///
    /// `positioning: nil` — no item is pre-selected, so keyboard focus landing in the menu can never
    /// leave Quit (or anything else) as the default choice.
    public func popUpMenuCentred(_ placement: PresenceMenuHover.Placement) {
        lastEntryPoint = .notch
        pendingEntryPoint = .notch
        rebuild()
        menu.minimumWidth = placement.width
        hoverMenuOpen = true
        Log.app.notice("menu opened from hover: width=\(placement.width) origin=\(NSStringFromPoint(placement.menuOrigin))")
        menu.popUp(positioning: nil, at: placement.menuOrigin, in: nil)
        hoverMenuOpen = false
        menu.minimumWidth = 0
    }

    /// H33 — the hover menu is up (between `popUpMenuCentred` and its return).
    public private(set) var hoverMenuOpen = false

    /// H33 — close the menu if it is tracking (Option key-down, pointer left, a turn went live).
    public func cancelMenuTracking() {
        menu.cancelTracking()
    }

    // MARK: - The state the menu is a function of

    /// Pure with respect to focus and capture: nothing here reads the frontmost app, dequeues held
    /// text or asks for the microphone.
    public func menuState() -> StatusMenuState {
        let muted = ambientMuted?() ?? session?.isMuted ?? false
        let meeting = meetingRunning?() ?? false
        let inputs = MenuStatusInputs(muted: muted, paused: coordinator.paused, canCapture: capabilities.canCapture,
                                      canUseHotkey: capabilities.canUseGlobalHotkey,
                                      engine: coordinator.engine.state, holder: session?.activeRequester,
                                      latched: session?.isLatched ?? coordinator.latched,
                                      meetingRunning: meeting, presence: presenceState?())
        var state = StatusMenuState(status: MenuStatus.derive(inputs), micName: micName(),
                                    micStatus: coordinator.lastMicQuality?.verdict, micAvailable: capabilities.canCapture,
                                    isCapturing: inputs.dictationCaptureOpen, isMuted: muted, held: heldDrafts(),
                                    meetingRunning: meeting, notesUnread: notesUnread?() ?? 0)
        state.recent = recentRows()
        state.extras = menuExtras
        return state
    }

    /// H32 — the Recent rows, with the just-copied row marked "Copied" for a moment.
    private func recentRows() -> [RecentMenu.Row] {
        guard let recentDictations else { return [] }
        let at = now()
        let copiedID = lastCopied.flatMap { at.timeIntervalSince($0.at) < copiedDwell ? $0.id : nil }
        return recentDictations().prefix(RecentMenu.limit).map {
            RecentMenu.Row($0, now: at, copied: $0.id == copiedID)
        }
    }

    public func menuEntries(from entryPoint: MenuEntryPoint? = nil) -> [MenuEntry] {
        StatusMenuSpec.entries(menuState(), from: entryPoint ?? lastEntryPoint)
    }

    private func heldDrafts() -> [StatusMenuState.Held] {
        if let heldItems { return heldItems().map(StatusMenuState.Held.init) }
        if let focusGuard { return HeldMenuRouter.held(in: focusGuard) }
        return []
    }

    // MARK: - Rendering

    func rebuild() {
        menu.removeAllItems()
        for entry in menuEntries() {
            if entry.id == StatusMenuSpec.ID.recentHeader {
                // H32 — the native section header ("Recent"), macOS 14+.
                let header = NSMenuItem.sectionHeader(title: entry.title)
                header.identifier = NSUserInterfaceItemIdentifier(entry.id)
                menu.addItem(header)
                continue
            }
            // H33 — the custom-view rows are spec slots; a slot with nothing to show yet is dropped.
            if StatusMenuSpec.ID.customSlots.contains(entry.id) {
                if let item = customItem(for: entry.id) { menu.addItem(item) }
                continue
            }
            menu.addItem(entry.isSeparator ? .separator() : menuItem(for: entry))
        }
    }

    /// H33 — which custom rows this controller can draw (`MenuExtras` in the spec's state).
    var menuExtras: MenuExtras {
        MenuExtras(zeroEdit: showsZeroEditCounter && database != nil,
                   whyItWroteThat: showsWhyItWroteThat,
                   ambient: ambientModeController != nil)
    }

    private func customItem(for id: String) -> NSMenuItem? {
        switch id {
        case StatusMenuSpec.ID.zeroEdit: return zeroEditItem()
        case StatusMenuSpec.ID.whyItWroteThat: return whyItWroteThatItem()
        case StatusMenuSpec.ID.ambient: return ambientModeItem()
        default: return nil
        }
    }

    /// V5 L1 — the ambient mode control, in its own group above Quit.
    private func ambientModeItem() -> NSMenuItem? {
        guard let controller = ambientModeController else { return nil }
        return MainActor.assumeIsolated {
            AmbientModeMenu.item(controller: controller) { [weak self] in self?.refreshIcon() }
        }
    }

    /// V5 I3 — "Why did it write that?" (live status item only, once a turn was traced).
    public lazy var showsWhyItWroteThat: Bool = statusItem != nil

    private func whyItWroteThatItem() -> NSMenuItem? {
        guard showsWhyItWroteThat else { return nil }
        return MainActor.assumeIsolated { WhyItWroteThatMenu.item() }
    }

    /// I2 — on for the live status item, off headless (tests opt in), so the spec's rows stay the
    /// rows a headless menu renders.
    public lazy var showsZeroEditCounter: Bool = statusItem != nil
    private var zeroEditModel: ZeroEditSurfaceModel?

    /// Menus are built on the main thread (AppKit's `menuNeedsUpdate`, the shell's tests).
    private func zeroEditItem() -> NSMenuItem? {
        guard showsZeroEditCounter, let database else { return nil }
        return MainActor.assumeIsolated {
            let model = zeroEditModel ?? ZeroEditSurfaceModel(database: database)
            zeroEditModel = model
            return ZeroEditMenuItem.make(model: model)
        }
    }

    /// One row as AppKit draws it. The helper line is the item's subtitle; the status line carries
    /// the glyph and, only when ready, the green dot.
    func menuItem(for entry: MenuEntry) -> NSMenuItem {
        let hasAction = entry.action != nil && entry.isEnabled
        let item = NSMenuItem(title: entry.title,
                              action: hasAction ? #selector(performEntry(_:)) : nil,
                              keyEquivalent: entry.keyEquivalent)
        item.target = hasAction ? self : nil
        item.isEnabled = entry.isEnabled
        item.state = entry.isOn ? .on : .off
        item.representedObject = entry.id
        item.identifier = NSUserInterfaceItemIdentifier(entry.id)
        if entry.showsGlyph { item.image = MenuBarGlyph.image(size: MenuBarGlyph.menuHeadingSize) }
        MenuItemText.apply(title: entry.title, detail: entry.detail, readyDot: entry.showsReadyDot, to: item)
        if entry.action.map(Self.isRecent) == true { RecentMenuItemStyle.apply(entry, to: item) }
        return item
    }

    private static func isRecent(_ action: MenuAction) -> Bool {
        if case .copyRecent = action { return true }
        return false
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
        case .toggleMute: toggleMute()
        case .reviewHeld: (onReviewHeld ?? onOpenWindow ?? onOpenSettings)?()
        case .openWindow: (onOpenWindow ?? onOpenSettings)?()
        case .openSettings: onOpenSettings?()
        case .openNotes: (onOpenNotes ?? onOpenWindow ?? onOpenSettings)?()
        case .quit: quitVoicePlus()
        case .copyRecent(let id): copyRecentRow(id)
        }
        refreshIcon()
        rebuild()
    }

    /// Explicit click-to-stop capture: the `.menu` requester through the session owner, so mic
    /// arbitration and mute are honoured. There is no key to release; only Stop (or Escape, mute,
    /// lock) ends it, and a hotkey release cannot stop a session the menu holds.
    /// H32 — Copy through the verified path; "Copied" only when the pasteboard read back the words.
    private func copyRecentRow(_ id: TurnID) {
        let verified = copyRecent?(id) ?? false
        lastCopied = verified ? (id, now()) : nil
        Log.app.notice("menu: recent copy \(verified ? "verified" : "not verified")")
        onRecentCopied?(id, verified)
    }

    private func startDictation() {
        if let session { session.start(.menu, mode: .hold) } else { coordinator.start() }
    }

    /// The explicit Stop: it stops whoever holds the microphone, not only the menu.
    private func stopDictation() {
        if let session { session.stop(session.activeRequester ?? .menu, reason: .userStopped) }
        else { coordinator.finalize() }
    }

    private func toggleMute() {
        if let onToggleMute { onToggleMute() } else { session?.mute.toggleMute() }
    }

    // MARK: - Quit

    /// Held drafts are saved to history first; then open capture asks Stop and quit / Cancel, and a
    /// draft that could not be saved gets the unsaved-data warning. Otherwise it simply quits.
    func quitVoicePlus() {
        let state = menuState()
        let held = HeldDrafts.save(state.held, into: database)
        switch MenuQuit.plan(dictating: state.isCapturing, meeting: state.meetingRunning, held: held) {
        case .quit:
            Log.app.notice("quit from the menu (\(held.count) held dictation(s), all saved)")
            terminateApp()
        case .ask(let prompt):
            guard confirmQuit(prompt) else {
                Log.app.notice("quit cancelled; capture and held text unchanged")
                return
            }
            if prompt.stopsCapture { stopCaptureForQuit(state) }
            terminateApp()
        }
    }

    /// Stop and quit. Dictation is cancelled rather than finalized: the process is about to end, and
    /// a final pass racing termination could type half a sentence. The prompt said so.
    private func stopCaptureForQuit(_ state: StatusMenuState) {
        if state.isCapturing {
            if let session { session.cancel(session.activeRequester ?? .menu, reason: .userStopped) }
            else { coordinator.cancel() }
        }
        if state.meetingRunning { onStopMeeting?() }
        Log.app.notice("quit: stopped open capture before quitting")
    }

    static func runQuitAlert(_ prompt: MenuQuit.Prompt) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: prompt.cancel)
        return alert.runModal() == .alertFirstButtonReturn
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

/// Title, helper line and ready dot for one `NSMenuItem`.
///
/// The helper is the native subtitle (always available on the macOS 15 floor); the ready dot is an
/// attributed title that leaves the subtitle intact.
enum MenuItemText {
    static let dot = "●"

    static func apply(title: String, detail: String?, readyDot: Bool, to item: NSMenuItem) {
        // macOS 15 is the floor (V5 J7): the native subtitle always works alongside the dot.
        item.subtitle = detail
        if readyDot { item.attributedTitle = attributed(title: title, detail: nil, readyDot: true) }
        // The dot is decoration; VoiceOver reads the words, never "black circle".
        if item.attributedTitle != nil {
            item.setAccessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        }
    }

    static func attributed(title: String, detail: String?, readyDot: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if readyDot {
            // Prototype `.dot`: 6 pt, the ready green; never shown for any other state.
            out.append(NSAttributedString(string: "  \(dot)", attributes: [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: Tokens.Colors.ready,
                .baselineOffset: 1.5,
            ]))
        }
        if let detail {
            out.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return out
    }
}

/// H32 — how a Recent row is drawn: the destination app's 16 pt icon, the one-line words (already
/// tail-truncated by `RecentMenu`), the relative time (or "Copied") right-aligned in secondary
/// text, and the full words as the tooltip.
enum RecentMenuItemStyle {
    static let iconSize = NSSize(width: 16, height: 16)
    /// Where the trailing time sits; the menu is at least this wide (H33 sets `minimumWidth`).
    static let trailingTab: CGFloat = 300

    static func apply(_ entry: MenuEntry, to item: NSMenuItem) {
        item.toolTip = entry.toolTip
        item.image = icon(for: entry.iconBundleID)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: trailingTab)]
        paragraph.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString(string: entry.title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph,
        ])
        if let trailing = entry.trailing {
            out.append(NSAttributedString(string: "\t\(trailing)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }
        item.attributedTitle = out
        let time = entry.trailing.map { ", \($0)" } ?? ""
        item.setAccessibilityLabel("Copy: \(entry.toolTip ?? entry.title)\(time)")
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = iconSize
        return image
    }
}
