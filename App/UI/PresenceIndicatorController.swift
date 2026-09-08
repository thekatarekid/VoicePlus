import AppKit
import Combine
import Shared
import SwiftUI

/// P5 — the persistent presence indicator ("the notch chin").
///
/// The problem it solves: on a notched MacBook with a crowded menu bar, macOS culls status items,
/// and ours has no persisted position — so the app's only always-on affordance is the first thing
/// to disappear. Everything else VoicePlus draws (pill, meeting prompt, consent panels, ink
/// overlay) is show-on-demand. This is the one surface that is simply always there.
///
/// Guarantees, each of them a unit test in `NotchPresenceTests` rather than a comment:
/// * never drawn under the camera housing — one placement rule, shared with the pill;
/// * never steals focus or swallows a click — non-activating panel, `ignoresMouseEvents` at all
///   times except while the pointer is genuinely on it;
/// * survives display changes and Spaces — re-placed on screen-parameter, Space and wake changes,
///   and joins every Space including full-screen ones;
/// * can be switched off in Settings;
/// * `listening`, `processing` and `muted` are never suppressed, in full screen or anywhere else.
///
/// Main-thread only, like `PillPanelController`.
public final class PresenceIndicatorController {
    /// Pops the same menu the status item shows — on every click, primary or secondary
    /// (`PresenceClickRouter`). This is the whole point of the indicator: when macOS has culled the
    /// status item from a crowded menu bar, the chin under the notch is the way back into
    /// Settings, permissions and Quit.
    public var onClick: (() -> Void)?
    /// Where the hotkey hint in the hover row comes from ("hold Right ⌥").
    public var hotkeyHint: () -> String = { "" }
    /// Read on every refresh so a Settings toggle takes effect without re-wiring anything.
    public var settings: SettingsStore? { didSet { refresh() } }
    /// Polled rather than pushed: `paused` is flipped from the status menu, the mute latch and the
    /// coordinator itself, and none of those owners has an observer to hang off.
    public var pausedProvider: (() -> Bool)?

    private let panel: NSPanel
    private let container = PresenceContainerView()
    private var hosting: NSHostingView<PresenceIndicatorView>
    private var inputs = PresenceInputs()
    private var state: PresenceState = .off
    private var hovered = false
    private var hoverTimer: Timer?
    /// When the indicator last started announcing itself (see `PresenceIntroduction`).
    private var introducedAt: Date?
    /// The width the expanded row currently needs; drives both the panel frame and the hover rect.
    private var rowWidth: CGFloat?
    /// Pre-suppression state, so an announcement-worthy transition is not lost behind the pill.
    private var lastSubstance: PresenceState?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var settledLogged = false
    /// Tallest menu bar ever seen per display — see `PresenceInteraction.menuBarPresent`.
    private var menuBarSeen: [String: CGFloat] = [:]

    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        // ORDER MATTERS: `isFloatingPanel = true` sets the level to `.floating` (3) as a side
        // effect, so it has to come first or it silently demotes the panel below the menu bar and
        // every other status-level overlay. Caught by `presence settled: … level=` in the log.
        panel.isFloatingPanel = true
        // Deliberately one level BELOW the pill (`.statusBar + 1`): when both want the same anchor,
        // the pill wins — and the reducer hides this one anyway.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        hosting = NSHostingView(rootView: PresenceIndicatorView(state: .off, hovered: false, cornerRadius: 0, hint: ""))
        // Same opt-out as the pill: the panel's frame comes from `PresenceGeometry`, and a hosting
        // view that publishes its content's minimum size can only fight that (see PillPanelController).
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onClick = { [weak self] secondary in self?.handleClick(secondary: secondary) }
        panel.contentView = container
    }

    deinit {
        hoverTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    // MARK: - Lifecycle

    /// Orders the indicator in (if the current state is visible) and starts watching the world.
    public func start() {
        guard !started else { return }
        started = true
        Self.logPlacementDiagnostics()
        for name in [NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Self.logPlacementDiagnostics()
                self?.refresh(force: true)
            })
        }
        // Entering a full-screen Space arrives here too, which is how the quiet states learn to
        // stand down (and how `listening` / `muted` learn that they must not).
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(force: true)
            })
        }
        // Settings writes land in UserDefaults; re-read rather than plumbing a callback per toggle.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        startHoverPolling()
        refresh(force: true)
    }

    /// Mutate the inputs and re-render. Every setter below funnels through here.
    public func update(_ mutate: (inout PresenceInputs) -> Void) {
        mutate(&inputs)
        refresh()
    }

    public func setEngine(_ engine: EngineState) { onMain { self.update { $0.engine = engine } } }
    public func setPillVisible(_ visible: Bool) { onMain { self.update { $0.pillVisible = visible } } }
    public func setPaused(_ paused: Bool) { onMain { self.update { $0.paused = paused } } }
    public func setMuted(_ muted: Bool) { onMain { self.update { $0.muted = muted } } }
    public func setCapabilities(_ caps: PermissionPlanner.Capabilities) { onMain { self.update { $0.capabilities = caps } } }
    public func setTapProvenDead(_ dead: Bool = true) { onMain { self.update { $0.tapProvenDead = dead } } }
    public func setDownloadProgress(_ progress: Double?) { onMain { self.update { $0.downloadProgress = progress } } }

    /// One-call wiring for the composition root: pill visibility + the engine feed the pill already
    /// receives, plus the hard-mute latch. Keeps `AppDelegate`'s footprint to a couple of lines.
    public func bind(pill: PillViewModel, mute: MuteController?) {
        pill.$state.receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update { $0.pillVisible = state.isVisible } }
            .store(in: &cancellables)
        let previous = pill.onEngineState
        pill.onEngineState = { [weak self] engine in
            previous?(engine)
            self?.setEngine(engine)
        }
        mute?.observe { [weak self] model in
            self?.onMain { self?.update { $0.muted = model.muted; $0.ambientProcessing = model.processing } }
        }
    }

    // MARK: - Clicks

    /// The routing decision is `PresenceClickRouter.action(for:secondary:)` (pure, unit-tested);
    /// this only performs it. Nothing here calls `NSApp.activate` — popping a menu does not move
    /// focus, so the app the user is typing into keeps it.
    func handleClick(secondary: Bool) {
        let action = PresenceClickRouter.action(for: state, secondary: secondary)
        Log.app.notice("presence click: state=\(self.state.caseName) secondary=\(secondary) action=\(String(describing: action))")
        switch action {
        case .menu: onClick?()
        }
    }

    // MARK: - Rendering

    private func refresh(force: Bool = false) {
        guard started else { return }
        inputs.enabled = PresenceSettings.isEnabled(settings)
        inputs.hideInFullScreen = PresenceSettings.hidesInFullScreen(settings)
        if let pausedProvider { inputs.paused = pausedProvider() }
        guard let metrics = Self.hostMetrics() else { return }
        inputs.menuBarPresent = menuBarPresent(on: metrics)

        let next = PresenceStateReducer.reduce(inputs)
        // Announce on the transitions that carry news (launch, and recovery out of a blocked state —
        // e.g. a speech model finishing its download and the engine being swapped in). `substance`
        // rather than the reduced state so a pill or a full-screen Space cannot eat the transition.
        let substance = PresenceStateReducer.substance(inputs)
        if PresenceIntroduction.announces(from: lastSubstance, to: substance) { introducedAt = Date() }
        lastSubstance = substance
        let introducing = next == .ready && PresenceIntroduction.isShowing(since: introducedAt)

        let pointerOn = next.isVisible
            && PresenceInteraction.isHovering(mouse: NSEvent.mouseLocation, on: metrics, rowWidth: rowWidth)
        let expanded = pointerOn || introducing

        // Fit the message to the display *before* placing the panel: the row is sized to its text,
        // which is the whole of the "…— hold R…" fix.
        let width = expanded ? Self.fittedRow(state: next, hint: hotkeyHint(), on: metrics) : nil
        guard force || next != state || expanded != hovered || width?.width != rowWidth else { return }
        let changed = next != state || expanded != hovered
        state = next
        hovered = expanded
        rowWidth = width?.width

        guard next.isVisible else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            if changed { Log.app.notice("presence state: off (enabled=\(self.inputs.enabled) pill=\(self.inputs.pillVisible) menuBar=\(self.inputs.menuBarPresent))") }
            return
        }

        let layout = PresenceGeometry.layout(for: metrics, state: next, hovered: expanded, rowWidth: width?.width)
        hosting.rootView = PresenceIndicatorView(state: next, hovered: expanded,
                                                 cornerRadius: layout.cornerRadius, hint: hotkeyHint(),
                                                 rowText: width?.text)
        // The panel can never swallow a click meant for the app underneath: it only takes the mouse
        // while the pointer is provably on it.
        // Note `pointerOn`, not `expanded`: while the row is announcing itself unprompted it must
        // still be click-through, or a launch-time announcement would eat the user's first click.
        panel.ignoresMouseEvents = PresenceInteraction.ignoresMouse(hovering: pointerOn)
        panel.setFrame(layout.frame, display: true)
        // Belt and braces on top of `PresenceContainerView.layout()`: the chin is 4 pt tall at rest
        // and an off-by-one hosting frame is the difference between a hairline and nothing at all.
        hosting.frame = container.bounds
        // `orderFrontRegardless`, never `makeKeyAndOrderFront` and never `NSApp.activate`: the
        // indicator must never take focus from whatever the user is typing into.
        panel.orderFrontRegardless()
        if changed {
            Log.app.notice("""
                presence state: \(next.caseName) frame=\(NSStringFromRect(layout.frame)) \
                expanded=\(expanded) pointerOn=\(pointerOn) row="\(width?.text ?? "")" \
                ignoresMouse=\(self.panel.ignoresMouseEvents) \
                clearsHousing=\(PresenceGeometry.clearsHousing(layout.frame, on: metrics)) \
                menuBar=\(self.inputs.menuBarPresent) visible=\(self.panel.isVisible) \
                screen=\(self.panel.screen?.localizedName ?? "none")
                """)
            logSettled()
        }
    }

    /// `occlusionState` only means anything once the window server has composited the panel, so the
    /// "is it actually on screen?" half of the diagnostic has to come a beat later — the same trick
    /// `WindowPlacement.place` uses. This is the line that proves the chin is really visible.
    private func logSettled() {
        guard !settledLogged else { return }
        settledLogged = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            Log.app.notice("""
                presence settled: frame=\(NSStringFromRect(self.panel.frame)) \
                visible=\(self.panel.isVisible) onscreen=\(self.panel.occlusionState.contains(.visible)) \
                key=\(self.panel.isKeyWindow) level=\(self.panel.level.rawValue) \
                screen=\(self.panel.screen?.localizedName ?? "none")
                """)
        }
    }

    /// The row's text and the panel width it needs, measured in the real font. `PresenceRow` does
    /// the choosing; this only supplies the ruler.
    static func fittedRow(state: PresenceState, hint: String, on metrics: ScreenMetrics) -> PresenceRow.Fit {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return PresenceRow.fit(detail: state.detail,
                               hint: PresenceRow.hint(hint, for: state),
                               maxWidth: PresenceGeometry.maxRowWidth(on: metrics)) { text in
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        }
    }

    private func startHoverPolling() {
        hoverTimer?.invalidate()
        // Polling `NSEvent.mouseLocation` rather than installing a global mouse monitor: a monitor
        // is a new Input-Monitoring-shaped surface for a decoration, and this costs nothing.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func menuBarPresent(on metrics: ScreenMetrics) -> Bool {
        let key = NSStringFromRect(metrics.frame)
        let seen = max(menuBarSeen[key] ?? 0, metrics.menuBarHeight)
        menuBarSeen[key] = seen
        return PresenceInteraction.menuBarPresent(current: metrics.menuBarHeight, everObserved: seen)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Placement

    /// The display that hosts the indicator: the notched built-in first, then the display at the
    /// global origin. Pinned, not mouse-following — a persistent thing that hops displays with the
    /// pointer is noise, and `WindowPlacement.hostScreen` is already unit-tested for this choice.
    public static func hostMetrics() -> ScreenMetrics? {
        let screens = NSScreen.screens.map(PillPanelController.metrics(for:))
        let main = NSScreen.main.map(PillPanelController.metrics(for:))
        return WindowPlacement.hostScreen(screens: screens, main: main)
    }

    /// Startup diagnostic, deliberately shaped like `pill geometry:` — every frame the indicator can
    /// occupy on every attached display, and whether each one clears the camera housing. Placement
    /// is verifiable from `log show` without a screenshot.
    public static func logPlacementDiagnostics() {
        let host = hostMetrics()
        for screen in NSScreen.screens {
            let m = PillPanelController.metrics(for: screen)
            let frames = PresenceGeometry.allFrames(on: m)
            let clears = frames.allSatisfy { PresenceGeometry.clearsHousing($0.rect, on: m) }
            let list = frames.map { "\($0.name)=\(NSStringFromRect($0.rect))" }.joined(separator: " ")
            Log.app.notice("""
                presence geometry: display=\(screen.localizedName) host=\(m == host) \
                frame=\(NSStringFromRect(m.frame)) topInset=\(m.topInset) menuBar=\(m.menuBarHeight) \
                topBand=\(m.topBand) notch=\(m.notchRect.map(NSStringFromRect) ?? "none") \
                \(list) hoverRect=\(NSStringFromRect(PresenceGeometry.hoverRect(on: m))) \
                pillShown=\(NSStringFromRect(NotchGeometry.layout(for: m).shown)) clearsHousing=\(clears)
                """)
        }
    }
}

/// Content view that catches the click without ever becoming key. `acceptsFirstMouse` matters: the
/// panel is non-activating, so without it the first click would be swallowed activating nothing.
final class PresenceContainerView: NSView {
    /// `true` = a secondary click (right-click, or ⌃-click). Both pop the status menu; the flag is
    /// kept only so the routing decision stays in one pure, testable place.
    var onClick: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.control))
    }
    override func rightMouseDown(with event: NSEvent) { onClick?(true) }
    /// The hosting view is 0x0 until the panel is first sized; pin it to the bounds explicitly
    /// rather than trusting autoresizing to grow it out of nothing.
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
