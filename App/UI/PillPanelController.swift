import AppKit
import Combine
import Shared
import SwiftUI

/// Borderless, non-activating `NSPanel` that slides out from under the notch (T2).
/// Slide in/out ≤150 ms; every animation is interruptible (each transition cancels the previous).
public final class PillPanelController {
    public let model = PillViewModel()
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var lastState: PillState = .hidden

    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        cancellable = model.$state.receive(on: DispatchQueue.main).sink { [weak self] state in self?.render(state) }
        // Display arrangement can change mid-utterance (external display plugged in, resolution change,
        // clamshell open/close): re-place the pill against the new geometry while it is on screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Self.logPlacementDiagnostics()
            guard self.model.state.isVisible else { return }
            self.reposition(self.model.state)
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
        return ScreenMetrics(frame: screen.frame, topInset: screen.safeAreaInsets.top, notchWidth: notchWidth,
                             menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY),
                             visibleFrame: screen.visibleFrame)
    }

    /// One-shot startup diagnostic: where the pill will land on every attached display, and whether that
    /// rect clears the camera housing. Makes the notch bug verifiable from `log stream` without a screenshot.
    public static func logPlacementDiagnostics() {
        for screen in NSScreen.screens {
            let m = metrics(for: screen)
            let l = NotchGeometry.layout(for: m, size: NotchGeometry.defaultSize)
            let expanded = NotchGeometry.layout(for: m, size: NotchGeometry.expandedSize)
            let clear = m.notchRect.map { !l.shown.intersects($0) && !expanded.shown.intersects($0) } ?? true
            Log.app.info("""
                pill geometry: display=\(screen.localizedName) frame=\(NSStringFromRect(m.frame)) \
                topInset=\(m.topInset) menuBar=\(m.menuBarHeight) topBand=\(m.topBand) \
                notch=\(m.notchRect.map(NSStringFromRect) ?? "none") \
                shown=\(NSStringFromRect(l.shown)) expanded=\(NSStringFromRect(expanded.shown)) \
                retracted=\(NSStringFromRect(l.retracted)) clearsHousing=\(clear)
                """)
        }
    }

    /// Re-place an already visible pill (screen parameters changed) without replaying the slide-in.
    private func reposition(_ state: PillState) {
        guard let metrics = Self.currentMetrics() else { return }
        panel.setFrame(NotchGeometry.layout(for: metrics, size: NotchGeometry.size(for: state)).shown, display: true)
    }

    private func render(_ state: PillState) {
        defer { lastState = state }
        guard let metrics = Self.currentMetrics() else { return }
        let layout = NotchGeometry.layout(for: metrics, size: NotchGeometry.size(for: state))
        if state.isVisible, !lastState.isVisible {
            Log.app.info("""
                pill placement: screen=\(NSStringFromRect(metrics.frame)) topBand=\(metrics.topBand) \
                notch=\(metrics.notchRect.map(NSStringFromRect) ?? "none") \
                shown=\(NSStringFromRect(layout.shown)) retracted=\(NSStringFromRect(layout.retracted))
                """)
        }
        if let host = panel.contentView as? NSHostingView<PillView> {
            host.rootView = PillView(model: model, cornerRadius: layout.cornerRadius)
        }
        // The ghost row ("↩ / try again") is the one clickable thing on the pill.
        if case .transform(let info) = state { panel.ignoresMouseEvents = !info.showsGhost } else { panel.ignoresMouseEvents = true }
        switch (lastState.isVisible, state.isVisible) {
        case (false, true):
            panel.setFrame(layout.retracted, display: false)
            panel.orderFrontRegardless()
            animate(to: layout.shown)
        case (true, false):
            animate(to: layout.retracted) { [weak self] in
                if self?.model.state.isVisible == false { self?.panel.orderOut(nil) }
            }
        case (true, true):
            animate(to: layout.shown)
        case (false, false):
            break
        }
    }

    private func animate(to frame: NSRect, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}
