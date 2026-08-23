import Foundation
import Shared

/// Owns the `TransformPillReducer`, ticks it, and pushes its state into the pill. Ghost actions
/// come back through `onAction` (wired to `TransformLanding.undo/tryAgain`).
@MainActor
public final class TransformPillDriver {
    public let pill: PillViewModel
    public private(set) var reducer: TransformPillReducer
    public var clock: () -> Date = Date.init
    public var onAction: ((TransformGhost.Action) -> Void)?
    private var timer: Timer?

    public init(pill: PillViewModel, warmWindow: TimeInterval = 8) {
        self.pill = pill
        reducer = TransformPillReducer(warmWindow: warmWindow)
        pill.onGhostAction = { [weak self] a in self?.onAction?(a) }
    }

    public func handle(_ event: TransformPillReducer.Event) {
        let state = reducer.reduce(event, now: clock())
        push(state)
        if reducer.isWarm, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if case .hidden = state { stopTimer() }
    }

    func tick() {
        let state = reducer.reduce(.tick, now: clock())
        push(state)
        if !reducer.isWarm { stopTimer() }
    }

    private func push(_ state: PillState) {
        pill.ghost = reducer.ghost
        pill.morph = reducer.morph
        if case .transform = state { pill.present(state) } else if case .transform = pill.state { pill.hide() }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
