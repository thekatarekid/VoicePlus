import AppKit
import Engine
import Shared

/// Menu-bar item + dropdown dashboard (T1/T4). Rebuilt on every open so counters are live.
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let flags: FeatureFlagService
    private let database: AppDatabase?
    private let coordinator: DictationCoordinator
    private let hotkey: HotkeyService
    private let updater: UpdaterProtocol
    public var onOpenLab: (() -> Void)?
    public var onOpenDataPanel: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onRecheckPermissions: (() -> Void)?
    /// Live labels supplied by the composition root (P1.12); defaults keep shell tests unchanged.
    public var activeModelName: () -> String = { "Mock engine (fixture)" }
    public var micName: () -> String = { "Default microphone" }
    /// P1.5.2 — "show what changed" list + per-app off switch (nil keeps the Phase 1 menu).
    public var corrections: CorrectionLedger?
    public var correctionSettings: SettingsStore?
    public var correctionRevertSink: (() -> ReplaceRangeSink?)?
    /// P5.4 — ambient state glyph + one-gesture hard mute (nil until hands-free is wired).
    public var ambientSymbol: (() -> String?)?
    public var ambientMuted: (() -> Bool)?
    public var onToggleMute: (() -> Void)?
    /// P5.3 — voice enrollment window.
    public var onEnrollVoice: (() -> Void)?
    /// P5 — mirror of the presence-indicator switch, so the thing that replaces a culled status
    /// item can also be turned off from the status item while it is still reachable.
    public var presenceIndicatorEnabled: (() -> Bool)?
    public var onTogglePresenceIndicator: (() -> Void)?
    /// P5.5 — meeting capture opt-in. Toggling it on is what asks for Calendar access; nothing
    /// about meetings runs (or prompts) until the user does. nil hides the item entirely.
    public var meetingCaptureEnabled: (() -> Bool)?
    public var onToggleMeetingCapture: (() -> Void)?
    /// P4.2 — the act key (Bet 5's second key). Supplied by the composition root together with the
    /// store that holds its on/off switch; with either nil the "Actions key" item is not shown at
    /// all, which keeps every existing shell test's menu unchanged.
    public var actHotkey: HotkeyService?
    public var actKeyStore: SettingsStore?
    public var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    public var capabilities: PermissionPlanner.Capabilities = .init(canCapture: false, canUseGlobalHotkey: false, canInjectText: false)

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
        statusItem.menu = menu
        statusItem.button?.toolTip = "VoicePlus"
        refreshIcon()
    }

    public func model() -> MenuModel {
        let stats = database.map { MenuModel.load(from: $0) } ?? (zeroEdit: 0, total: 0, wordsToday: 0)
        return MenuModel(zeroEditCount: stats.zeroEdit, totalCount: stats.total, wordsToday: stats.wordsToday,
                         activeModel: activeModelName(), micName: micName(),
                         micStatus: coordinator.lastMicQuality?.verdict, paused: coordinator.paused,
                         handsFree: coordinator.handsFree, hotkeyName: hotkey.binding.kind.displayName,
                         launchAtLogin: LaunchAtLogin.isEnabled)
    }

    public func refreshIcon() {
        let m = model()
        // P5.4 — ambient three-state glyph (listening/muted/processing) wins when hands-free is wired.
        let symbol = ambientSymbol?() ?? m.statusSymbol
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoicePlus")
        statusItem.button?.appearsDisabled = m.paused || ambientMuted?() == true
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    /// P5 — the presence indicator pops this same menu. That is the point of it: when macOS has
    /// culled the status item from a crowded menu bar, the chin under the notch is the only
    /// remaining way into Settings, mute and Quit.
    public func popUpMenu(at point: NSPoint = NSEvent.mouseLocation) {
        rebuild()
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func rebuild() {
        let m = model()
        menu.removeAllItems()
        menu.addItem(info(m.zeroEditLine))
        menu.addItem(info(m.wordsLine))
        menu.addItem(info(m.modelLine))
        menu.addItem(info(m.micLine))
        menu.addItem(.separator())
        let pause = NSMenuItem(title: m.pauseTitle, action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)
        if let ambientMuted, onToggleMute != nil {
            let muted = ambientMuted()
            let mute = NSMenuItem(title: muted ? "Unmute microphone" : "Mute microphone (hard)",
                                  action: #selector(toggleMute), keyEquivalent: "m")
            mute.target = self
            mute.state = muted ? .on : .off
            menu.addItem(mute)
        }
        if capabilities.needsMenuFallback || !hotkey.isRunning {
            let start = NSMenuItem(title: coordinator.engine.state.isActive ? "Stop dictation" : "Start dictation (no hotkey)",
                                   action: #selector(toggleDictation), keyEquivalent: "d")
            start.target = self
            menu.addItem(start)
        }
        menu.addItem(.separator())
        // The submenu is grouped by *style*, because style is what decides the mechanism and the
        // mechanism is what used to decide the permission bill. Both groups are free now; the
        // footer says so rather than leaving the user to wonder which one costs something.
        let hotkeyMenu = NSMenu()
        for (heading, style) in [("Hold a modifier", HotkeyBinding.Style.bareModifier),
                                 ("Hold a chord", HotkeyBinding.Style.chord)] {
            let header = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            header.isEnabled = false
            hotkeyMenu.addItem(header)
            for kind in HotkeyBinding.Kind.allCases where kind.style == style {
                let item = NSMenuItem(title: kind.displayName, action: #selector(pickHotkey(_:)), keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = kind.rawValue
                item.state = kind == hotkey.binding.kind ? .on : .off
                item.toolTip = Self.permissionNote(for: kind, forcingEventTap: hotkey.forcesEventTap)
                hotkeyMenu.addItem(item)
            }
        }
        hotkeyMenu.addItem(.separator())
        let note = NSMenuItem(title: Self.permissionNote(for: hotkey.binding.kind,
                                                         forcingEventTap: hotkey.forcesEventTap),
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        hotkeyMenu.addItem(note)
        let hotkeyItem = NSMenuItem(title: "Dictation key: \(m.hotkeyName)", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        if let actItem = actKeyItem() { menu.addItem(actItem) }

        let flagMenu = NSMenu()
        for flag in flags.knownFlags {
            let item = NSMenuItem(title: flag.id, action: #selector(toggleFlag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = flag.id
            item.state = flags.isEnabled(flag) ? .on : .off
            item.toolTip = flag.description
            flagMenu.addItem(item)
        }
        let flagsItem = NSMenuItem(title: "Feature flags", action: nil, keyEquivalent: "")
        flagsItem.submenu = flagMenu
        menu.addItem(flagsItem)

        if let corrections {
            menu.addItem(CorrectionMenuBuilder.item(ledger: corrections, settings: correctionSettings, bundleID: frontmostBundleID(), target: self,
                                                    revert: #selector(revertCorrection(_:)), toggleApp: #selector(toggleCorrectionsForApp(_:))))
        }
        let lab = NSMenuItem(title: "Open the Lab…", action: #selector(openLab), keyEquivalent: "l")
        lab.target = self
        menu.addItem(lab)
        let data = NSMenuItem(title: "Data Panel…", action: #selector(openDataPanel), keyEquivalent: "")
        data.target = self
        menu.addItem(data)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let perms = NSMenuItem(title: "Check permissions…", action: #selector(recheckPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        if onEnrollVoice != nil {
            let enroll = NSMenuItem(title: "Enroll voice…", action: #selector(enrollVoice), keyEquivalent: "")
            enroll.target = self
            menu.addItem(enroll)
        }
        menu.addItem(.separator())
        if let meetingCaptureEnabled, onToggleMeetingCapture != nil {
            let on = meetingCaptureEnabled()
            let meetings = NSMenuItem(title: on ? "Capture meetings" : "Capture meetings (asks for Calendar access)",
                                      action: #selector(toggleMeetingCapture), keyEquivalent: "")
            meetings.target = self
            meetings.state = on ? .on : .off
            menu.addItem(meetings)
        }
        if let presenceIndicatorEnabled, onTogglePresenceIndicator != nil {
            let on = presenceIndicatorEnabled()
            let indicator = NSMenuItem(title: "Show indicator under the notch",
                                       action: #selector(togglePresenceIndicator), keyEquivalent: "")
            indicator.target = self
            indicator.state = on ? .on : .off
            menu.addItem(indicator)
        }
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = m.launchAtLogin ? .on : .off
        login.isEnabled = LaunchAtLogin.isAvailable
        menu.addItem(login)
        let update = NSMenuItem(title: "Check for updates…", action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = updater.canCheckForUpdates
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoicePlus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleMute() {
        onToggleMute?()
        refreshIcon()
        rebuild()
    }

    @objc private func enrollVoice() { onEnrollVoice?() }

    @objc private func togglePresenceIndicator() {
        onTogglePresenceIndicator?()
        rebuild()
    }

    @objc private func togglePause() {
        coordinator.setPaused(!coordinator.paused)
        hotkey.isPaused = coordinator.paused
        refreshIcon()
    }

    @objc private func toggleDictation() {
        if coordinator.engine.state.isActive { coordinator.finalize() } else { coordinator.start() }
    }

    /// The one line that says what a binding costs. Pure and static so the copy is unit-testable
    /// without a status item — and so "no permission" cannot quietly become a lie if the selection
    /// rule changes: it is derived from `HotkeyBackendSelector`, not written by hand per case.
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

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = HotkeyBinding.Kind(rawValue: raw) else { return }
        hotkey.setBinding(kind)
    }

    /// The act key gets the same treatment as the dictation key — one submenu, grouped by style —
    /// plus the entry the dictation key must never have: **Off**. Until 1.7.11 this key was live on
    /// Right ⌘ on every install and appeared in no menu and no settings pane, so the only way to
    /// stop it swallowing a keypress was `defaults write`.
    func actKeyItem() -> NSMenuItem? {
        guard let actHotkey, let actKeyStore else { return nil }
        let enabled = ActKeySettings.isEnabled(actKeyStore)
        let submenu = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(pickActKey(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = ActKeyChoice.off.rawValue
        off.state = enabled ? .off : .on
        off.toolTip = "Actions does nothing and no second key is armed."
        submenu.addItem(off)
        for (heading, style) in [("Hold a modifier", HotkeyBinding.Style.bareModifier),
                                 ("Hold a chord", HotkeyBinding.Style.chord)] {
            let header = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for kind in HotkeyBinding.Kind.allCases where kind.style == style {
                let collides = kind == hotkey.binding.kind
                let item = NSMenuItem(title: collides ? "\(kind.displayName) — your dictation key" : kind.displayName,
                                      action: #selector(pickActKey(_:)), keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = kind.rawValue
                item.state = (enabled && kind == actHotkey.binding.kind) ? .on : .off
                // Offered, not hidden — a user swapping both keys passes through this state — but
                // never silently: dictation wins the collision and the act key would stay inert.
                item.toolTip = collides
                    ? "Dictation already uses this key. Pick a different one or the Actions key stays inert."
                    : Self.permissionNote(for: kind, forcingEventTap: actHotkey.forcesEventTap)
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        let note = NSMenuItem(title: "Actions needs a provider pinned for “Actions (voice commands)” in Settings › Models.",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        let item = NSMenuItem(title: "Actions key: \(enabled ? actHotkey.binding.kind.displayName : "Off")",
                              action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func pickActKey(_ sender: NSMenuItem) {
        guard let actHotkey, let actKeyStore, let raw = sender.representedObject as? String else { return }
        guard let kind = HotkeyBinding.Kind(rawValue: raw) else {
            ActKeySettings.setEnabled(false, store: actKeyStore)   // "Off"
            return
        }
        actHotkey.setBinding(kind)
        ActKeySettings.setEnabled(true, store: actKeyStore)
    }

    @objc private func toggleFlag(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let flag = flags.knownFlags.first(where: { $0.id == id }) else { return }
        try? flags.setOverride(!flags.isEnabled(flag), for: flag)
    }

    @objc private func revertCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
              let entry = corrections?.entry(id: id), let sink = correctionRevertSink?() else { return }
        corrections?.revert(entry, via: sink)
    }

    @objc private func toggleCorrectionsForApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String, let store = correctionSettings else { return }
        CorrectionSettings.setEnabled(!CorrectionSettings.isEnabled(for: bundle, store: store), for: bundle, store: store)
    }

    @objc private func openLab() {
        onOpenLab?() ?? Log.app.info("Lab not wired yet (P1.11)")
    }

    @objc private func openDataPanel() { onOpenDataPanel?() }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func recheckPermissions() { onRecheckPermissions?() }

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.set(enabled: !LaunchAtLogin.isEnabled) }

    @objc private func toggleMeetingCapture() { onToggleMeetingCapture?() }

    @objc private func checkUpdates() { updater.checkForUpdates() }
}
