import AppKit
import Combine
import Shared
import SwiftUI

/// Borderless, non-activating `NSPanel` that hangs the Spool pill below the notch (design §4).
/// Geometry transitions are 180 ms ease-out and interruptible (each transition cancels the previous).
public final class PillPanelController {
    public let model: PillViewModel
    /// `var`, not `let`: fix notch — a panel that macOS left on no Space is rebuilt (`rebuildPanels`).
    private var panel: NSPanel
    /// Read-only ownership seam for isolated native diagnostics; never discover a shadow by window order.
    var diagnosticPanel: NSPanel { panel }
    private var shadowPanel: NSPanel
    private var attached = true
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var lastSurface: NotchGeometry.Surface = .hidden
    /// The display chosen when the turn became visible; pinned for the turn (design §4).
    private var pinnedMetrics: ScreenMetrics?
    /// The state of the previous render, so a transition into `.starting` re-chooses the display (Q6).
    private var lastRenderedState: PillState?
    /// Where the panel is animating to. The hit test below must accept the pointer against both the
    /// live and the target frame: mid-animation `panel.frame` is an intermediate rectangle that may
    /// not yet contain a pointer which is genuinely on the pill, and treating that as "not hovering"
    /// would resume a dwell the user is deliberately holding open.
    private var targetFrame: NSRect?
    /// H36 — one placement attempt (and at most one log line) per press.
    private var placementGate = PillPlacementGate()
    /// A real removal is a delivery-safety event: the turn must retain its text and require an
    /// explicit retarget instead of following a window that macOS moved to another display.
    public var onPinnedDisplayLost: (() -> Void)?
    /// Fix notch (RC4) — the presence chin's frame on a display (`PresenceIndicatorController.handoffFrame`):
    /// the pill opens out of it and closes back into it, so the chin and the pill read as one notch
    /// growing and shrinking, never a chin, a gap and a pill. Nil (no chin there): the centred line.
    public var chinFrame: ((ScreenMetrics) -> CGRect?)?
    /// Fix notch (RC3/RC4) — a retraction is animating; a show that arrives before it finishes
    /// grows the pill back from where it is (no snap to the line, no second order-in).
    private var retracting = false
    /// The retraction reached the chin; the pill is ordered out on the next main-queue turn.
    private var retractArrived = false
    private var retractGeneration = 0

    /// BUG B — is the pill's panel *genuinely* ordered in right now?
    ///
    /// The presence chin stands down while "the pill is showing" (`PresenceStateReducer`), and until
    /// now that was decided by `PillViewModel.state.isVisible` — an *intent* to show a pill. Every
    /// path below that returns from `render` without ordering the panel in (no display to place it
    /// on, the pinned display gone) therefore produced the reported symptom: the chin suppressed by a
    /// pill that is not on screen, and so no surface at all. This is the truth the chin binds to.
    public var surfaceOnScreen: AnyPublisher<Bool, Never> { onScreen.map(\.onScreen).removeDuplicates().eraseToAnyPublisher() }
    /// V5 Q7 — the same truth plus the display it is on, so the chin stands down only for a pill on
    /// *its* display.
    public var surfaceReport: AnyPublisher<PillSurfaceReport, Never> { onScreen.removeDuplicates().eraseToAnyPublisher() }
    private let onScreen = CurrentValueSubject<PillSurfaceReport, Never>(.offScreen)
    private var occlusionObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// Reports what the window server has been told, from the one place that can know it.
    /// V5 Q7: ordered in ∧ on the active Space ∧ occlusion-visible ∧ frame on the chosen display ∧
    /// frame > 1 pt. The frame is the one the panel is animating to, so a pill rolling up already
    /// counts as gone.
    private func noteSurfaceOnScreen() {
        // Fix notch (RC4) — a pill that has shrunk into the chin is gone, even for the one main-queue
        // turn before it is ordered out (the chin is ordered in first, at the same frame).
        if retracting, retractArrived { onScreen.send(.offScreen); return }
        let report = PillSurfaceReport.evaluate(orderedIn: panel.isVisible,
                                                occlusionVisible: panel.occlusionState.contains(.visible),
                                                frame: targetFrame ?? panel.frame, chosenScreen: pinnedMetrics,
                                                onActiveSpace: panel.isOnActiveSpace)
        onScreen.send(report)
    }

    public init() {
        let model = PillViewModel()
        self.model = model
        (panel, shadowPanel) = Self.makePanels(model: model, size: NotchGeometry.activeSize,
                                               shadowSize: NotchGeometry.activeSize, attached: true)
        // State, turn (latched timer, chips, live words) and the clock can each change the surface
        // (e.g. the finishing offer's buttons appear at 10 s); render when the surface or state does.
        cancellable = model.$state
            .combineLatest(model.$turn, model.$clockTick, model.$laneNote)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, _, _, _ in self?.render(state) }
        // Display arrangement can change mid-turn. Refresh the same display's geometry while it is
        // present; only a real removal moves the recovery surface and invalidates delivery.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Self.logPlacementDiagnostics()
            guard self.model.state.isVisible else { self.noteSurfaceOnScreen(); return }
            let screens = NSScreen.screens.map(Self.metrics(for:))
            let main = NSScreen.main.map(Self.metrics(for:))
            let resolution = NotchGeometry.resolveDisplayPin(
                self.pinnedMetrics, screens: screens, mouse: NSEvent.mouseLocation, main: main)
            self.pinnedMetrics = resolution.metrics
            if resolution.pinnedDisplayLost {
                Log.app.notice("pill display removed during active turn — moving recovery and invalidating destination")
                self.onPinnedDisplayLost?()
            }
            guard resolution.metrics != nil else {
                self.panel.orderOut(nil)
                self.shadowPanel.orderOut(nil)
                PillDiagnostics.record(.orderOut(window: "pill", reason: "displayRemoved")) // K19
                // BUG B — ORDER MATTERS with `lastSurface`: the panel is out, so the next render has
                // to take the `(false, true)` branch and order it back in. Leaving `lastSurface` at a
                // visible value made `render` believe the panel was still up, so it only ever
                // animated a window that was never ordered front again — the pill went missing for
                // the rest of the process while the chin stayed suppressed by it.
                self.lastSurface = .hidden
                self.retracting = false
                self.retractArrived = false
                self.noteSurfaceOnScreen()
                return
            }
            self.render(self.model.state, force: true)
        }
        observeOcclusion()
        // Fix notch — a Space change can take a shown pill off the active Space; re-evaluate.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.noteSurfaceOnScreen() }
        Self.logPlacementDiagnostics()
        // V5 Q13 — dwell pause/resume diagnostics carry the pill frame at that moment (main thread
        // only; an off-main read records no frame rather than touching AppKit).
        // A pill that is gone or not on screen defers to whatever reader was installed before it
        // (none in the app; a test's fixed frame under parallel tests).
        let previous = TurnEventDiagnostics.frame
        TurnEventDiagnostics.frame = { [weak self] in
            guard Thread.isMainThread, let panel = self?.panel, panel.isVisible else { return previous() }
            return DiagnosticsRect(panel.frame)
        }
    }

    /// The pill panel and its click-through shadow sibling, configured but not ordered in.
    private static func makePanels(model: PillViewModel, size: CGSize, shadowSize: CGSize,
                                   attached: Bool) -> (panel: NSPanel, shadow: NSPanel) {
        let shadowPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let panel = PillInteractionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // V5 Q9 — "Hide Others" (or ⌘H on VoicePlus) must not hide a pill whose dwell is running.
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // ROOT CAUSE OF THE 1.7.9 "BLACK SLAB": `NSHostingView.sizingOptions` defaults to
        // `.standardBounds`, which publishes the SwiftUI content's *minimum* size as the window's
        // `contentMinSize`; a wrapping notice's minimum is the fully wrapped paragraph, and AppKit grew
        // the panel to it. The pill's frame is placement math (`NotchGeometry`), never content.
        let host = NSHostingView(rootView: PillPanelSurface(model: model, size: size, attached: attached))
        host.sizingOptions = []
        host.focusRingType = .none
        panel.contentView = host
        panel.contentMinSize = .zero
        panel.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        shadowPanel.level = panel.level
        shadowPanel.isOpaque = false
        shadowPanel.backgroundColor = .clear
        shadowPanel.hasShadow = false
        shadowPanel.hidesOnDeactivate = false
        shadowPanel.canHide = false
        shadowPanel.ignoresMouseEvents = true
        shadowPanel.collectionBehavior = panel.collectionBehavior
        shadowPanel.isReleasedWhenClosed = false
        shadowPanel.animationBehavior = .none
        let shadowHost = NSHostingView(rootView: PillShadowSurface(size: shadowSize, attached: attached))
        shadowHost.sizingOptions = []
        shadowHost.focusRingType = .none
        shadowPanel.contentView = shadowHost
        return (panel, shadowPanel)
    }

    private func observeOcclusion() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.noteSurfaceOnScreen() }
    }

    /// Fix notch — orders the pill in at `layout.retracted` and makes sure it is on the active Space.
    /// If reasserting the all-Spaces tag does not bring it back, the panels are rebuilt: a new window
    /// joins every Space when it is first ordered in. Runs once per press (the `(false, true)` render).
    private func orderInPill(layout: NotchGeometry.Layout, acceptsMouse: Bool) {
        placeRetracted(layout)
        var outcome = SpaceMembership.orderIn([shadowPanel, panel])
        if outcome == .offActiveSpace {
            Log.app.warning("pill: ordered in but not on the active Space — rebuilding its windows")
            rebuildPanels(layout: layout)
            syncPointerTracking(acceptsMouse: acceptsMouse)
            placeRetracted(layout)
            outcome = SpaceMembership.orderIn([shadowPanel, panel])
        }
        if outcome != .onActiveSpace {
            Log.app.notice("pill space membership: \(outcome.rawValue) (onActiveSpace=\(self.panel.isOnActiveSpace))")
        }
    }

    private func placeRetracted(_ layout: NotchGeometry.Layout) {
        panel.setFrame(layout.retracted, display: false)
        shadowPanel.setFrame(Self.shadowFrame(layout.retracted, attached: layout.attached), display: false)
    }

    /// Replaces both panels with new ones (new window ids). The old ones are ordered out and their
    /// SwiftUI hosts detached first, for the same reason as in `deinit`.
    private func rebuildPanels(layout: NotchGeometry.Layout) {
        let old = (panel, shadowPanel)
        old.0.orderOut(nil)
        old.1.orderOut(nil)
        old.0.contentView = nil
        old.1.contentView = nil
        (panel, shadowPanel) = Self.makePanels(model: model, size: layout.contentFrame.size,
                                               shadowSize: layout.shown.size, attached: layout.attached)
        observeOcclusion()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        // Gate (H-fixes): detach the SwiftUI hosts while the panels are still alive. Left attached, the
        // host leaves its window inside NSWindow's own dealloc, and SwiftUI's window observation can
        // try to form a weak reference to the deallocating (KVO-observed) panel — an objc fatal error
        // ("Cannot form weak reference to … PillInteractionPanel") seen once in the full suite.
        panel.orderOut(nil)
        shadowPanel.orderOut(nil)
        panel.contentView = nil
        shadowPanel.contentView = nil
    }

    /// Screen metrics for the screen under the mouse (falls back to main).
    public static func currentMetrics() -> ScreenMetrics? {
        let all = NSScreen.screens.map(metrics(for:))
        let main = NSScreen.main.map(metrics(for:))
        return NotchGeometry.hostScreen(screens: all, mouse: NSEvent.mouseLocation, main: main)
    }

    /// V5 Q6 — the display the work is on: caret → focused window → active screen → mouse.
    static func workMetrics() -> ScreenMetrics? {
        let all = NSScreen.screens.map(metrics(for:))
        let main = NSScreen.main.map(metrics(for:))
        // H36 — no display at all (mid-reconfiguration, display asleep): skip the AX probe; the
        // screen-parameters notification re-renders once a display is back.
        guard !all.isEmpty || main != nil else { return nil }
        let rects = PillWorkLocator.workRects()
        let chosen = PillDisplayChooser.choose(caretRect: rects.caret, focusedWindowFrame: rects.window,
                                               activeScreen: main, mouse: NSEvent.mouseLocation,
                                               screens: all, main: main)
        return PillPlacementGate.resolve(chosen: chosen, screens: all, main: main)
    }

    /// V5 Q6 — re-choose the display on every transition *into* `.starting` (a new turn), including
    /// from unconfirmed / held / error surfaces that were still visible, and whenever the pill
    /// becomes visible without a pin.
    static func shouldRechooseDisplay(previous: PillState?, next: PillState, wasVisible: Bool, hasPin: Bool) -> Bool {
        if !wasVisible || !hasPin { return true }
        return next == .starting && previous != .starting
    }

    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        var notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Width difference, not a coordinate difference: the aux areas are not guaranteed to be in
            // the same space as `screen.frame` for a display that is not at the global origin.
            notchWidth = max(0, screen.frame.width - (left.width + right.width))
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return ScreenMetrics(frame: screen.frame, topInset: screen.safeAreaInsets.top, notchWidth: notchWidth,
                             menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY),
                             visibleFrame: screen.visibleFrame, displayID: displayID)
    }

    /// One-shot startup diagnostic: where the pill lands on every display, attached or floating, and
    /// whether both turn sizes clear the camera housing — verifiable from `log stream`.
    public static func logPlacementDiagnostics() {
        for screen in NSScreen.screens {
            let m = metrics(for: screen)
            let active = NotchGeometry.pillLayout(for: m, size: NotchGeometry.size(for: .active, on: m))
            let actionable = NotchGeometry.pillLayout(for: m, size: NotchGeometry.size(for: .actionable, on: m))
            let clear = NotchGeometry.clearsHousing(active.contentFrame, on: m) && NotchGeometry.clearsHousing(actionable.contentFrame, on: m)
            Log.app.info("""
                pill geometry: display=\(screen.localizedName) frame=\(NSStringFromRect(m.frame)) \
                topInset=\(m.topInset) menuBar=\(m.menuBarHeight) topBand=\(m.topBand) attached=\(m.isAttached) \
                notch=\(m.notchRect.map(NSStringFromRect) ?? "none") ceiling=\(NSStringFromSize(NotchGeometry.ceiling(on: m))) \
                active=\(NSStringFromRect(active.shown)) actionable=\(NSStringFromRect(actionable.shown)) \
                clearsHousing=\(clear)
                """)
        }
    }

    /// The surface a content occupies, with the hint measured in its real font.
    static func surface(for content: PillContent) -> NotchGeometry.Surface {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return content.surface { text in ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1 }
    }

    /// V3: readable transcripts accept scrolling and selection throughout the turn. Fixed startup
    /// hints remain click-through; capture text separately rejects keyboard focus in DraftTextView.
    static func acceptsMouse(_ state: PillState, content: PillContent) -> Bool {
        if content.hasActions { return true }
        switch content.words {
        case .live(let text), .final(let text): if !text.isEmpty { return true }
        case .none, .fixed: break
        }
        switch state {
        case .finalPreview, .held: return true
        case .transform(let info):
            if case .notice = info.stage { return true }
            return false
        default: return false
        }
    }

    private func render(_ state: PillState, force: Bool = false) {
        let content = model.content()
        let surface = Self.surface(for: content)
        let wasVisible = lastSurface != .hidden
        let previousState = lastRenderedState
        lastRenderedState = state
        if panel.isKeyWindow, !Self.keepsKeyboardFocus(state) { panel.makeFirstResponder(nil) }
        var displayChanged = false
        if !state.isVisible { placementGate.reset() }
        if state.isVisible,
           placementGate.mayAttempt(force: force, previous: previousState, next: state),
           Self.shouldRechooseDisplay(previous: previousState, next: state, wasVisible: wasVisible, hasPin: pinnedMetrics != nil) {
            let chosen = Self.workMetrics()
            displayChanged = wasVisible && pinnedMetrics != nil && chosen != nil && chosen != pinnedMetrics
            if chosen != nil || pinnedMetrics == nil { pinnedMetrics = chosen }
        }
        guard force || displayChanged || surface != lastSurface || state.isVisible != wasVisible else {
            syncPointerTracking(acceptsMouse: Self.acceptsMouse(state, content: content))
            noteSurfaceOnScreen()
            return
        }
        guard let metrics = pinnedMetrics else {
            // BUG B — nothing was placed and nothing was ordered in, so `lastSurface` must not claim
            // a visible surface (it did, through a `defer` that ran on this very return): one render
            // with no host display left the controller believing the panel was up forever after.
            // `.hidden` is the honest record, and the chin is told so it keeps the user a surface.
            // H36 — logged once per press; later renders of the same press wait for a display
            // (screen-parameters notification → forced render) instead of re-probing every tick.
            if state.isVisible, placementGate.noteNoDisplay() {
                Log.app.warning("pill: no display to place the pill on — leaving it retracted (wanted \(String(describing: surface)))")
            }
            lastSurface = .hidden
            noteSurfaceOnScreen()
            return
        }
        lastSurface = surface
        placementGate.notePlaced()
        let size = NotchGeometry.size(for: surface, on: metrics)
        let layout = NotchHandoff.layout(NotchGeometry.pillLayout(for: metrics, size: size == .zero ? NotchGeometry.activeSize : size),
                                         chin: chinFrame?(metrics))
        if surface != .hidden, !wasVisible {
            Log.app.info("""
                pill placement: screen=\(NSStringFromRect(metrics.frame)) topBand=\(metrics.topBand) \
                attached=\(layout.attached) notch=\(metrics.notchRect.map(NSStringFromRect) ?? "none") \
                shown=\(NSStringFromRect(layout.shown)) retracted=\(NSStringFromRect(layout.retracted))
                """)
        }
        if let host = panel.contentView as? NSHostingView<PillPanelSurface> {
            host.rootView = PillPanelSurface(model: model, size: layout.contentFrame.size, attached: layout.attached)
        }
        attached = layout.attached
        if let host = shadowPanel.contentView as? NSHostingView<PillShadowSurface> {
            host.rootView = PillShadowSurface(size: layout.shown.size, attached: layout.attached)
        }
        syncPointerTracking(acceptsMouse: Self.acceptsMouse(state, content: content))
        switch (wasVisible, surface != .hidden) {
        case (false, true):
            if NotchHandoff.resumesRetraction(retracting: retracting, panelOrderedIn: panel.isVisible) {
                // Fix notch (RC3) — shown again while still rolling up: grow back from where it is.
                // Snapping the visible panel to the line and ordering it in again was the
                // "closes, then opens again" jank of a hide and a show inside one animation.
                retracting = false
                retractArrived = false
                retractGeneration &+= 1
                Log.app.info("pill: shown again mid-retraction — growing back (\(state.designStateKey))")
                animate(to: layout.shown)
                break
            }
            retracting = false
            retractArrived = false
            orderInPill(layout: layout, acceptsMouse: Self.acceptsMouse(state, content: content))
            PillDiagnostics.record(.orderFront(window: "pill", reason: state.designStateKey)) // K19
            animate(to: layout.shown)
        case (true, false):
            retracting = true
            retractArrived = false
            retractGeneration &+= 1
            let generation = retractGeneration
            // Fix notch (RC4) — the pill shrinks into the chin's frame and stays reported on screen
            // until it gets there (`targetFrame` is the chin, > 1 pt), so the chin does not come back
            // under a pill that is still collapsing. At the end the chin is told first (its own
            // main-queue hop orders it in at this same frame), then the pill goes on the next turn:
            // the notch is never empty for a frame between the two windows.
            animate(to: layout.retracted) { [weak self] in
                guard let self, self.retracting, self.retractGeneration == generation,
                      !self.model.state.isVisible else { return }
                self.retractArrived = true
                self.onScreen.send(.offScreen)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.retracting, self.retractGeneration == generation,
                          !self.model.state.isVisible else { return }
                    self.retracting = false
                    self.retractArrived = false
                    self.panel.orderOut(nil)
                    self.shadowPanel.orderOut(nil)
                    PillDiagnostics.record(.orderOut(window: "pill", reason: "retracted")) // K19
                    self.pinnedMetrics = nil
                    self.noteSurfaceOnScreen()
                }
            }
        case (true, true):
            retracting = false
            retractArrived = false
            if displayChanged {
                // A new turn on another display: start from that display's retracted edge rather
                // than sliding across the desktop from the previous one.
                panel.setFrame(layout.retracted, display: false)
                shadowPanel.setFrame(Self.shadowFrame(layout.retracted, attached: layout.attached), display: false)
            }
            animate(to: layout.shown)
        case (false, false):
            break
        }
        noteSurfaceOnScreen()
    }

    /// V4.41 — mouse acceptance, and the truth about hover.
    ///
    /// A panel that stops accepting the mouse (`ignoresMouseEvents`), is ordered out, or moves out
    /// from under the pointer never delivers SwiftUI's `onHover(false)`. The model's cached
    /// `pointerInside` then stays true, and `TurnWiring` pauses every later final preview's dwell
    /// for a hover that is not happening — the payload sits at "Ready for <app> · Insert now" and is
    /// never inserted automatically. So: hover is re-derived from the real pointer on every render,
    /// and the model is told the truth immediately.
    private func syncPointerTracking(acceptsMouse: Bool) {
        panel.ignoresMouseEvents = !acceptsMouse
        model.pointerHitTest = { [weak self, weak panel] in
            guard let panel, !panel.ignoresMouseEvents, panel.isVisible else { return false }
            let mouse = NSEvent.mouseLocation
            if panel.frame.contains(mouse) { return true }
            // Mid-animation the live frame is an intermediate rectangle; a pointer on the surface the
            // pill is growing into is still a genuine hover, and must not resume the dwell.
            return self?.targetFrame?.contains(mouse) ?? false
        }
        if model.pointerInside, !model.isPointerReallyInside { model.setPointerInside(false) }
        model.keyFocusProbe = { [weak panel] in
            guard let panel, panel.isKeyWindow, let responder = panel.firstResponder as? NSView,
                  let content = panel.contentView else { return false }
            return responder.isDescendant(of: content)
        }
    }

    /// V5 Q8 — a pill that keeps keyboard focus after its turn left the preview would pause the next
    /// turn's dwell. States that host an editor or actions keep it; everything else gives it up.
    static func keepsKeyboardFocus(_ state: PillState) -> Bool {
        switch state {
        case .finalPreview, .held, .error, .correcting, .editing, .transform: return true
        default: return false
        }
    }

    /// Extra transparent room for the two neutral shadows; the silhouette/content anchor is unchanged.
    static func shadowFrame(_ frame: CGRect, attached: Bool) -> CGRect {
        CGRect(x: frame.minX - 40, y: frame.minY - 60, width: frame.width + 80,
               height: frame.height + 60 + (attached ? 0 : 40))
    }

    private func animate(to frame: NSRect, completion: (() -> Void)? = nil) {
        targetFrame = frame
        NSAnimationContext.runAnimationGroup({ ctx in
            // design §11: 160–220 ms ease-out geometry transitions; Reduce Motion (macOS or Settings ›
            // Appearance, S10) expands instantly.
            ctx.duration = MotionPreference.shared.policy.transitionDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            shadowPanel.animator().setFrame(Self.shadowFrame(frame, attached: attached), display: true)
        }, completionHandler: { [weak self] in
            completion?()
            self?.noteSurfaceOnScreen()
        })
    }
}

/// H36 — "pill: no display to place the pill on" was logged ~8× per press: a press whose first
/// placement found no display left `lastSurface` hidden while the state stayed visible, so every
/// later render of that press (turn, clock tick, lane note) re-ran the Accessibility probe and logged
/// again. The gate makes it one placement attempt and at most one log line per press; a forced render
/// (display arrangement changed) or a new turn (`.starting`) tries again. The chooser's nil is backed
/// by any present display, so a missing caret/window/mouse rung can never mean "no display".
struct PillPlacementGate: Equatable {
    private(set) var failedThisPress = false

    /// Whether this render may (re)run display placement.
    func mayAttempt(force: Bool, previous: PillState?, next: PillState) -> Bool {
        guard failedThisPress else { return true }
        return force || (next == .starting && previous != .starting)
    }

    /// Records a failed placement; true only for the first failure of the press (log it).
    mutating func noteNoDisplay() -> Bool {
        defer { failedThisPress = true }
        return !failedThisPress
    }

    mutating func notePlaced() { failedThisPress = false }
    mutating func reset() { failedThisPress = false }

    /// The chooser's pick, else the main display, else the first display; nil only with no display.
    static func resolve(chosen: ScreenMetrics?, screens: [ScreenMetrics], main: ScreenMetrics?) -> ScreenMetrics? {
        chosen ?? main ?? screens.first
    }
}

/// V5 Q7 — whether the pill is genuinely on screen, and on which display.
public struct PillSurfaceReport: Equatable, Sendable {
    public var onScreen: Bool
    /// The pill's chosen display while on screen; nil otherwise.
    public var display: ScreenMetrics?
    public static let offScreen = PillSurfaceReport(onScreen: false, display: nil)

    public init(onScreen: Bool, display: ScreenMetrics?) {
        self.onScreen = onScreen
        self.display = onScreen ? display : nil
    }

    /// Pure rule: ordered in ∧ on the active Space ∧ occlusion-visible ∧ frame on the chosen screen ∧
    /// frame > 1 pt. Fix notch: a panel ordered into no Space (WindowServer "none→hidden") is off screen.
    public static func evaluate(orderedIn: Bool, occlusionVisible: Bool, frame: CGRect,
                                chosenScreen: ScreenMetrics?, onActiveSpace: Bool = true) -> PillSurfaceReport {
        guard orderedIn, onActiveSpace, occlusionVisible, frame.width > 1, frame.height > 1,
              let chosenScreen, chosenScreen.frame.intersects(frame) else { return .offScreen }
        return PillSurfaceReport(onScreen: true, display: chosenScreen)
    }
}

/// S2 — the destination the pill names ("Ready for Mail", "✓ Inserted in Mail"): the frontmost app at
/// key-down, by its localized name. Never VoicePlus itself, never a bundle identifier.
public enum PillDestination {
    public static func frontmostName(workspace: NSWorkspace = .shared,
                                     ownBundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let app = workspace.frontmostApplication else { return nil }
        return name(localizedName: app.localizedName, bundleID: app.bundleIdentifier, ownBundleID: ownBundleID)
    }

    /// Pure half: nil for our own app and for an app with no display name.
    public static func name(localizedName: String?, bundleID: String?, ownBundleID: String?) -> String? {
        if let bundleID, let ownBundleID, bundleID == ownBundleID { return nil }
        guard let name = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}


/// This panel accepts a first responder only after an explicit editor interaction.
private final class PillInteractionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PillPanelSurface: View {
    @ObservedObject var model: PillViewModel
    let size: CGSize
    let attached: Bool
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(cornerRadii: Tokens.Radius.pillCorners(attached: attached))
                .fill(Tokens.Pill.Token.background.color)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            PillView(model: model, size: size, attached: attached)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // H35 — pinned top-centre and clipped by the (smaller) window while it opens from the centred
        // line: the content is revealed outward from the centre and never slides vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onHover { model.setPointerInside($0) }
        .preferredColorScheme(.dark)
    }
}


/// Shadows live in a click-through sibling, so no transparent margin can consume an app click.
private struct PillShadowSurface: View {
    let size: CGSize
    let attached: Bool
    var body: some View {
        UnevenRoundedRectangle(cornerRadii: Tokens.Radius.pillCorners(attached: attached))
            .fill(Tokens.Pill.Token.background.color)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.28), radius: 40, x: 0, y: 18)
            .padding(.horizontal, 40)
            .padding(.top, attached ? 0 : 40)
            .padding(.bottom, 60)
            // H35 — follows the pill as it opens from the centred line (top-pinned, never sliding).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .preferredColorScheme(.dark)
    }
}
