import Combine
import Foundation
import Shared

/// Owns the `TransformPillReducer`, ticks it, and pushes its state into the pill. Ghost actions
/// come back through `onAction` (wired to `TransformLanding.undo/tryAgain`).
///
/// S12 — while an edit is running or previewed (R1) nothing has been written, so the driver borrows
/// Escape for exactly that stretch (`escape`, → `onCancel`: keep the original), and the pointer on
/// the pill freezes the preview's dwell (`onPause`). Both end with the first outcome.
@MainActor
public final class TransformPillDriver {
    public let pill: PillViewModel
    public private(set) var reducer: TransformPillReducer
    public var clock: () -> Date = Date.init
    public var onAction: ((TransformGhost.Action) -> Void)?
    /// S12 — Escape during R1: wired to `TransformLanding.cancelPreview()`.
    public var onCancel: (() -> Void)?
    /// S12 — hover on the pill during the preview: wired to `TransformLanding.pausePreview(_:)`.
    public var onPause: ((Bool) -> Void)?
    /// H8 / X5 — the one-time "Download" on the needs-model row: wired (AppDelegate) to the model
    /// manager's download of the recommended model. Never called on its own.
    public var onDownloadModel: (() -> Void)?

    /// Actions on the transform row that are not ghost actions.
    public enum Action: Equatable, Sendable {
        /// H8 / X5 — "Download" on "Needs the on-device model · Saved to Notes".
        case downloadModel
    }

    /// The row's Download button is showing (the pill draws it while this is true).
    public var offersDownload: Bool { reducer.offersDownload }
    /// S12 — the Escape hot key, registered only while `reducer.awaitsDecision`. nil: no Escape.
    public var escape: EscapeHotkey? {
        didSet {
            oldValue?.update(phase: .none)
            escape?.onEscape = { [weak self] resolution in
                // Only `.cancel` can arrive: the phase is never `.writing` here.
                guard resolution == .cancel else { return }
                self?.onCancel?()
            }
            syncEscape()
        }
    }
    private var timer: Timer?
    private var hover: AnyCancellable?
    private var paused = false

    public init(pill: PillViewModel, warmWindow: TimeInterval = 8) {
        self.pill = pill
        reducer = TransformPillReducer(warmWindow: warmWindow)
        pill.onGhostAction = { [weak self] a in self?.onAction?(a) }
        hover = pill.$pointerInside.removeDuplicates().sink { [weak self] inside in
            // SwiftUI hover arrives on the main thread; anything else hops there.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.syncPause(pointerInside: inside) }
            } else {
                Task { @MainActor in self?.syncPause(pointerInside: inside) }
            }
        }
    }

    public func handle(_ event: TransformPillReducer.Event) {
        let state = reducer.reduce(event, now: clock())
        push(state)
        if reducer.needsTicks, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if case .hidden = state { stopTimer() }
        syncEscape()
        syncPause(pointerInside: pill.pointerInside)
    }

    /// A row action. `.downloadModel` only acts while the offer is on the row; the row then closes.
    public func perform(_ action: Action) {
        switch action {
        case .downloadModel:
            guard reducer.offersDownload else { return }
            onDownloadModel?()
            handle(.ended)
        }
    }

    func tick() {
        let state = reducer.reduce(.tick, now: clock())
        push(state)
        if !reducer.needsTicks { stopTimer() }
    }

    private func push(_ state: PillState) {
        pill.ghost = reducer.ghost
        pill.morph = reducer.morph
        if case .transform = state { pill.present(state) } else if case .transform = pill.state { pill.hide() }
    }

    /// Escape belongs to the frontmost app except while an edit awaits its outcome.
    private func syncEscape() {
        escape?.update(phase: reducer.awaitsDecision ? .beforeWrite : .none)
    }

    /// Hover freezes the dwell only while the preview is showing; leaving it (or the preview ending)
    /// lets it run again.
    private func syncPause(pointerInside: Bool) {
        let want = reducer.isPreviewing && pointerInside
        guard want != paused else { return }
        paused = want
        onPause?(want)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
