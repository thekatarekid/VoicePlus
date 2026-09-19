import AppKit
import Engine
import Shared
import SwiftUI

// S7c — the expanded capture panel's window, and the one call that wires meeting capture into the app.
//
// The panel is an explicit expansion of the pill (design §4: "Meeting expanded panel · 560 × 360 pt
// preferred · explicit expansion"): it opens from the pill's Expand button or the Meetings page, hangs
// from the same top edge as the pill (never behind the camera housing), and collapses back. Capture
// state lives in `MeetingCaptureController`, not here: collapsing never stops or pauses a meeting.

@MainActor
public final class MeetingPanelController {
    public static let shared = MeetingPanelController()

    /// Design §4's preferred size; a smaller display clamps it.
    nonisolated public static let preferredSize = CGSize(width: 560, height: 360)

    public var capture: MeetingCaptureController
    /// Where the notice's "Review permissions" goes. Default: the window's Privacy section.
    public var onReviewPermissions: () -> Void = { MainWindowController.show(section: .privacy) }
    /// Ask's "Open Providers". Default: Settings › Providers.
    public var onOpenProviders: () -> Void = { MainWindowController.show(route: .settings(.providers)) }
    /// "Open Meetings" once a meeting has closed. Default: the window's Meetings section.
    public var onOpenMeetings: () -> Void = { MainWindowController.show(section: .meetings) }
    /// Ask's route, when a service is configured (none today).
    public var askRoute: () -> MeetingAskRoute? = { nil }

    private var panel: NSPanel?

    public init(capture: MeetingCaptureController? = nil) {
        self.capture = capture ?? .shared
    }

    public var isShown: Bool { panel?.isVisible ?? false }

    /// The panel's frame on a display: 560 × 360 clamped to the display, top edge at the bottom of the
    /// forbidden band (the pill's own anchor), centred.
    nonisolated public static func frame(on metrics: ScreenMetrics) -> CGRect {
        let width = min(preferredSize.width, max(64, metrics.frame.width - 2 * NotchGeometry.edgeMargin))
        let top = metrics.frame.maxY - metrics.topBand - (metrics.isAttached ? 0 : NotchGeometry.floatingGap)
        let room = max(1, top - metrics.frame.minY - NotchGeometry.edgeMargin)
        let height = min(preferredSize.height, room)
        let x = NotchGeometry.centredX(width: width, on: metrics)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// Expands: shows the panel on the display under the pointer.
    public func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let rect = PillPanelController.currentMetrics().map(Self.frame(on:))
            ?? CGRect(origin: .zero, size: Self.preferredSize)
        let view = MeetingPanelView(capture: capture,
                                    askRoute: askRoute(),
                                    onCollapse: { [weak self] in self?.collapse() },
                                    onReviewPermissions: { [weak self] in self?.onReviewPermissions() },
                                    onOpenProviders: { [weak self] in self?.onOpenProviders() },
                                    onOpenMeetings: { [weak self] in
                                        self?.collapse()
                                        self?.onOpenMeetings()
                                    })
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: rect.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: view.frame(width: rect.width, height: rect.height))
        panel.setFrame(rect, display: true)
        Log.app.info("meeting panel placement: frame=\(NSStringFromRect(rect))")
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Collapses back to the pill. Capture carries on.
    public func collapse() {
        panel?.orderOut(nil)
        panel = nil
    }

    public func toggle() { isShown ? collapse() : show() }
}

// MARK: - The pill mirror

/// Q0 / Q1 / Q2 on the pill, from the capture controller. The meeting row never takes the pill from a
/// dictation turn: it shows only over an idle pill or its own row, and a turn in progress keeps the
/// pill until it ends (the next tick puts the meeting back).
@MainActor
public enum MeetingPillMirror {
    /// True when a meeting row may replace what the pill shows now.
    public static func mayPresent(over shown: PillState) -> Bool {
        switch shown {
        case .hidden, .ready, .meeting: return true
        default: return false
        }
    }

    /// The state the pill should move to, or `nil` to leave it alone.
    public static func next(for info: MeetingPillInfo?, shown: PillState) -> PillState? {
        if let info {
            guard mayPresent(over: shown) else { return nil }
            let next = PillState.meeting(info)
            return next == shown ? nil : next
        }
        if case .meeting = shown { return .hidden }
        return nil
    }

    public static func apply(_ info: MeetingPillInfo?, to pill: PillViewModel) {
        guard let next = next(for: info, shown: pill.state) else { return }
        if next == .hidden { pill.hide() } else { pill.present(next) }
    }
}

// MARK: - Wiring

/// The composition root's one call for meeting capture: the live driver over its meeting factories,
/// the pill mirror, and the panel. Until it is called, "Start recording" says capture is unavailable
/// instead of pretending to record.
@MainActor
public enum MeetingCaptureWiring {
    @discardableResult
    public static func install(coordinator: MeetingCoordinator, pill: PillViewModel,
                               capture: MeetingCaptureController? = nil,
                               panel: MeetingPanelController? = nil) -> MeetingCaptureController {
        let capture = capture ?? .shared
        let panel = panel ?? .shared
        capture.driver = MeetingSessionCaptureDriver(coordinator: coordinator)
        capture.onPillInfo = { [weak pill] info in
            guard let pill else { return }
            MeetingPillMirror.apply(info, to: pill)
        }
        panel.capture = capture
        return capture
    }

    /// The pill's meeting buttons, for the composition root's `pill.onAction`: Pause / Resume act on the
    /// capture, Stop closes it, Expand / Open meeting open the panel (or Meetings once it has closed).
    /// Returns false for anything that is not a manual meeting's, so the caller's own routing runs.
    @discardableResult
    public static func handle(_ action: PillActionKind, capture: MeetingCaptureController? = nil,
                              panel: MeetingPanelController? = nil) -> Bool {
        let capture = capture ?? .shared
        let panel = panel ?? .shared
        guard capture.state.isActive else { return false }
        switch action {
        case .pause: Task { await capture.pause() }
        case .resume: Task { await capture.resume() }
        case .stop: Task { await capture.stop() }
        case .meeting: panel.show()
        default: return false
        }
        return true
    }
}
