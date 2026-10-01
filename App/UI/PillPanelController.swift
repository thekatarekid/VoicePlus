import AppKit
import Combine
import Shared
import SwiftUI

/// Borderless, non-activating `NSPanel` that hangs the Spool pill below the notch (design §4).
/// Geometry transitions are 180 ms ease-out and interruptible (each transition cancels the previous).
public final class PillPanelController {
    public let model = PillViewModel()
    private let panel: NSPanel
    /// Read-only ownership seam for isolated native diagnostics; never discover a shadow by window order.
    var diagnosticPanel: NSPanel { panel }
    private let shadowPanel: NSPanel
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
    /// A real removal is a delivery-safety event: the turn must retain its text and require an
    /// explicit retarget instead of following a window that macOS moved to another display.
    public var onPinnedDisplayLost: (() -> Void)?

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
    /// Reports what the window server has been told, from the one place that can know it.
    /// V5 Q7: ordered in ∧ occlusion-visible ∧ frame on the chosen display ∧ frame > 1 pt. The frame
    /// is the one the panel is animating to, so a pill rolling up already counts as gone.
    private func noteSurfaceOnScreen() {
        let report = PillSurfaceReport.evaluate(orderedIn: panel.isVisible,
                                                occlusionVisible: panel.occlusionState.contains(.visible),
                                                frame: targetFrame ?? panel.frame, chosenScreen: pinnedMetrics)
        onScreen.send(report)
    }

    public init() {
        shadowPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel = PillInteractionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        let host = NSHostingView(rootView: PillPanelSurface(model: model, size: NotchGeometry.activeSize, attached: true, cap: 0))
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
        let shadowHost = NSHostingView(rootView: PillShadowSurface(size: NotchGeometry.activeSize, attached: true))
        shadowHost.sizingOptions = []
        shadowHost.focusRingType = .none
        shadowPanel.contentView = shadowHost
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
                self.noteSurfaceOnScreen()
                return
            }
            self.render(self.model.state, force: true)
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.noteSurfaceOnScreen() }
        Self.logPlacementDiagnostics()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
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
        let rects = PillWorkLocator.workRects()
        return PillDisplayChooser.choose(caretRect: rects.caret, focusedWindowFrame: rects.window,
                                         activeScreen: main, mouse: NSEvent.mouseLocation,
                                         screens: all, main: main)
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
        if state.isVisible,
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
            Log.app.warning("pill: no display to place the pill on — leaving it retracted (wanted \(String(describing: surface)))")
            lastSurface = .hidden
            noteSurfaceOnScreen()
            return
        }
        lastSurface = surface
        let size = NotchGeometry.size(for: surface, on: metrics)
        let layout = NotchGeometry.pillLayout(for: metrics, size: size == .zero ? NotchGeometry.activeSize : size)
        if surface != .hidden, !wasVisible {
            Log.app.info("""
                pill placement: screen=\(NSStringFromRect(metrics.frame)) topBand=\(metrics.topBand) \
                attached=\(layout.attached) notch=\(metrics.notchRect.map(NSStringFromRect) ?? "none") \
                shown=\(NSStringFromRect(layout.shown)) retracted=\(NSStringFromRect(layout.retracted))
                """)
        }
        if let host = panel.contentView as? NSHostingView<PillPanelSurface> {
            host.rootView = PillPanelSurface(model: model, size: layout.contentFrame.size, attached: layout.attached, cap: layout.backgroundCap)
        }
        attached = layout.attached
        if let host = shadowPanel.contentView as? NSHostingView<PillShadowSurface> {
            host.rootView = PillShadowSurface(size: layout.shown.size, attached: layout.attached)
        }
        syncPointerTracking(acceptsMouse: Self.acceptsMouse(state, content: content))
        switch (wasVisible, surface != .hidden) {
        case (false, true):
            panel.setFrame(layout.retracted, display: false)
            shadowPanel.setFrame(Self.shadowFrame(layout.retracted, attached: layout.attached), display: false)
            shadowPanel.orderFrontRegardless()
            panel.orderFrontRegardless()
            PillDiagnostics.record(.orderFront(window: "pill", reason: state.designStateKey)) // K19
            animate(to: layout.shown)
        case (true, false):
            animate(to: layout.retracted) { [weak self] in
                guard let self, !self.model.state.isVisible else { return }
                self.panel.orderOut(nil)
                self.shadowPanel.orderOut(nil)
                PillDiagnostics.record(.orderOut(window: "pill", reason: "retracted")) // K19
                self.pinnedMetrics = nil
                self.noteSurfaceOnScreen()
            }
        case (true, true):
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

    /// Pure rule: ordered in ∧ occlusion-visible ∧ frame on the chosen screen ∧ frame > 1 pt.
    public static func evaluate(orderedIn: Bool, occlusionVisible: Bool, frame: CGRect,
                                chosenScreen: ScreenMetrics?) -> PillSurfaceReport {
        guard orderedIn, occlusionVisible, frame.width > 1, frame.height > 1,
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
    let cap: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(cornerRadii: Tokens.Radius.pillCorners(attached: attached))
                .fill(Tokens.Pill.Token.background.color)
                .frame(width: size.width, height: size.height + cap)
                .allowsHitTesting(false)
            PillView(model: model, size: size, attached: attached)
                .padding(.top, cap)
        }
        .frame(width: size.width, height: size.height + cap, alignment: .topLeading)
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
            .allowsHitTesting(false)
            .preferredColorScheme(.dark)
    }
}
