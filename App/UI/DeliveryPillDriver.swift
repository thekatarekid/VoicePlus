import Actions
import Foundation
import Shared

/// R2.4 — the one place a `DeliveryOutcome` becomes something the user can see and act on.
///
/// It owns nothing new: it pushes an existing pill row, appends to the held queue when the text has
/// nowhere safe to go, and routes the row's three actions back into that queue. The status item
/// shows the same three actions off the same store (`onHeldChanged`).
@MainActor
public final class DeliveryPillDriver {
    public let pill: PillViewModel
    public let held: HeldTextStore
    /// Fired whenever the held queue changes, so the menu and the quit guard stay in step.
    public var onHeldChanged: (([HeldItem]) -> Void)?
    /// Logged for the record; never drawn (V3 §6: no raw errors on the surface).
    public var log: (String) -> Void = { Log.app.info("\($0)") }

    public init(pill: PillViewModel, held: HeldTextStore = HeldTextStore()) {
        self.pill = pill
        self.held = held
        self.held.onChange = { [weak self] items in self?.onHeldChanged?(items) }
        pill.onHeldAction = { [weak self] info, action in self?.perform(action, on: info.id) }
    }

    /// The whole surface for one landed utterance.
    ///
    /// `heldID` is the id `Injection`'s own held queue gave this text, when the caller knows it.
    /// Passing it through keeps the row, the menu and `FocusGuard.held` all naming one item; when
    /// it is absent the surface still works, and the sinks fall back to text-level recovery.
    @discardableResult
    public func handle(_ outcome: DeliveryOutcome, text: String, destination: String,
                       heldID: UUID? = nil) -> PillState {
        log("delivery: \(outcome) → pill (\(text.count) chars, destination \(destination.isEmpty ? "unknown" : destination))")
        guard case .held(let reason) = outcome else {
            return pill.present(delivery: outcome, text: text, destination: destination)
        }
        let item = held.hold(text: text, destination: destination, reason: reason, id: heldID ?? UUID())
        return pill.present(delivery: outcome, text: text, destination: destination, heldID: item.id)
    }

    /// Convenience for the composition root: the lander already computed the outcome.
    @discardableResult
    public func handle(_ result: LandingResult, destination: String, heldID: UUID? = nil) -> PillState? {
        guard let outcome = result.delivery else { return nil }
        return handle(outcome, text: result.text, destination: destination, heldID: heldID)
    }

    /// Insert here / Copy / Discard, from the pill row or from the menu. The row comes down as soon
    /// as the item is handled; an action that could not be carried out leaves the text held.
    @discardableResult
    public func perform(_ action: HeldAction, on id: UUID) -> HeldActionResult {
        let result = held.perform(action, on: id)
        log("held action \(action.rawValue) → \(result)")
        switch result {
        case .inserted, .copied, .discarded:
            if case .held(let shown) = pill.state, shown.id == id { pill.retractDelivery(immediately: true) }
        case .unavailable, .unknownItem:
            break
        }
        return result
    }

    /// What the quit guard needs (V3 §6: warn before quitting with pending text).
    public var quitDecision: QuitGuard.Decision { QuitGuard.decision(heldCount: held.count) }
}

/// R2.5 → R2.4. A repair that could not be applied is a **notice**, not a new row: `Actions` already
/// wrote the sentence (`pillLine`), and the existing `.error` row's standing subtitle — "Nothing was
/// typed — press the key again to try that turn" — is what `suggestion.detail` says anyway. So this
/// costs no new mark, colour, motion or state (V3 §12.12, DESIGN §8.4).
///
/// The `actionTitle` / `copyPayload` button R2.5 also offers is deliberately **not** built here: a
/// fourth clickable pill row is outside the three additions DESIGN §8.4 permits for R2.4. The
/// suggestion's `detail` — which names copying — goes to the log with it.
extension DeliveryPillDriver: RepairSuggestionPresenter {
    public nonisolated func present(_ suggestion: RepairSuggestion) {
        let line = suggestion.pillLine
        let detail = suggestion.detail
        // Same hop-if-needed shape as the pill's own timers: a repair command is *already* handled
        // on the main thread, and deferring the row to a later turn of the loop is what let it be
        // raised after the pill had moved on.
        let show = { MainActor.assumeIsolated { self.show(repairLine: line, detail: detail) } }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }

    private func show(repairLine: String, detail: String) {
        log("repair suggestion: \(repairLine) — \(detail)")
        pill.presentNotice(.error(message: repairLine))
    }
}
