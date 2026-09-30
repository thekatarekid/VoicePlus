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
    /// Where the panel is animating to. The hit test below must accept the pointer against both the
    /// live and the target frame: mid-animation `panel.frame` is an intermediate rectangle that may
    /// not yet contain a pointer which is genuinely on the pill, and treating that as "not hovering"
    /// would resume a dwell the user is deliberately holding open.
    private var targetFrame: NSRect?
    /// A real removal is a delivery-safety event: the turn must retain its text and require an
    /// explicit retarget instead of following a window that macOS moved to another display.
    public var onPinnedDisplayLost: (() -> Void)?

    public init() {
        shadowPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel = PillInteractionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
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
            guard self.model.state.isVisible else { return }
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
                return
            }
            self.render(self.model.state, force: true)
        }
        Self.logPlacementDiagnostics()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Screen metrics for the screen under the mouse (falls back to main).
    public static func currentMetrics() -> ScreenMetrics? {
        let all = NSScreen.screens.map(metrics(for:))
        let main = NSScreen.main.map(metrics(for:))
        return NotchGeometry.hostScreen(screens: all, mouse: NSEvent.mouseLocation, main: main)
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
        guard force || surface != lastSurface || state.isVisible != wasVisible else {
            syncPointerTracking(acceptsMouse: Self.acceptsMouse(state, content: content))
            return
        }
        defer { lastSurface = surface }
        if !wasVisible || pinnedMetrics == nil { pinnedMetrics = Self.currentMetrics() }
        guard let metrics = pinnedMetrics else { return }
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
            animate(to: layout.shown)
        case (true, false):
            animate(to: layout.retracted) { [weak self] in
                guard let self, !self.model.state.isVisible else { return }
                self.panel.orderOut(nil)
                self.shadowPanel.orderOut(nil)
                self.pinnedMetrics = nil
            }
        case (true, true):
            animate(to: layout.shown)
        case (false, false):
            break
        }
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
        }, completionHandler: completion)
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
