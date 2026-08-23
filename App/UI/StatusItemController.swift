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
        let hotkeyMenu = NSMenu()
        for kind in HotkeyBinding.Kind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == hotkey.binding.kind ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Dictation key: \(m.hotkeyName)", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

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

    @objc private func togglePause() {
        coordinator.setPaused(!coordinator.paused)
        hotkey.isPaused = coordinator.paused
        refreshIcon()
    }

    @objc private func toggleDictation() {
        if coordinator.engine.state.isActive { coordinator.finalize() } else { coordinator.start() }
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = HotkeyBinding.Kind(rawValue: raw) else { return }
        hotkey.setBinding(kind)
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

    @objc private func checkUpdates() { updater.checkForUpdates() }
}
