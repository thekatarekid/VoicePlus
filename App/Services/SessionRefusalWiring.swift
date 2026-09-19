import Foundation
import Shared

/// R3 / S9 — a refused dictation start is never silent.
///
/// `SessionCoordinator.start` runs on every dictation key press (`handle(.startCapture)`) and on the
/// menu's latch toggle. It refuses while hard-muted, or when a higher-ranked requester holds the
/// microphone, and reports it through `onRefusal`. Unassigned, the press did nothing visible unless
/// the persistent muted row happened to still be up.
///
/// Only dictating requesters (hotkey, menu) get a pill row: the mic check, a meeting or diagnostics
/// answer a refusal on their own surface. The row is the catalogue entry — K05 muted, K04 a dictation
/// already holds the microphone, K02 awaiting an explicit start — never `Refusal.message`.
public enum SessionRefusalWiring {
    /// Runs `work` after `delay` seconds on the main queue. Injected by tests.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    /// The catalogue entry the pill shows for a refused start; nil for requesters that do not dictate.
    public static func entry(for requester: SessionCoordinator.Requester,
                             _ refusal: SessionCoordinator.Refusal) -> RecoveryEntry? {
        guard requester.dictates else { return nil }
        return RecoveryCatalog.entry(for: refusal)
    }

    /// Points `session.onRefusal` at the pill, on the main queue.
    public static func attach(_ session: SessionCoordinator, pill: PillViewModel,
                              schedule: @escaping Schedule = { delay, work in
                                  DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                              }) {
        session.onRefusal = { [weak pill] requester, refusal in
            guard let entry = entry(for: requester, refusal) else { return }
            Log.app.notice("session: \(requester.rawValue) start refused — \(entry.id.rawValue)")
            let show = {
                guard let pill else { return }
                present(entry, on: pill, schedule: schedule)
            }
            if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
        }
    }

    /// Shows `entry` as the pill's recovery row. A mute row already on screen stays (mute outranks
    /// every row). K04 keeps the running turn's pose (design §10 `keepCurrentTurn`): it has no
    /// Dismiss of its own, so after the acknowledgment the row that was showing comes back — unless
    /// something newer replaced the notice in the meantime.
    static func present(_ entry: RecoveryEntry, on pill: PillViewModel, schedule: Schedule) {
        let before = pill.state
        let shown = PillState.recovery(entry)
        pill.presentNotice(shown)
        guard entry.dismissal == .whileConditionHolds, pill.state == shown else { return }
        schedule(RecoveryCatalog.fadeWindow.upperBound) { [weak pill] in
            guard let pill, pill.state == shown else { return }
            if before.isVisible { pill.present(before) } else { pill.dismissNotice() }
        }
    }
}
