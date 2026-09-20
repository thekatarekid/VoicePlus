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
        pill.onHeldDraftApplied = { [weak self] id, text in _ = self?.held.revise(id, text: text) }
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

/// R2.5 → R2.4, routed through the recovery catalogue (S11). A repair that found the text changed
/// under it ("scratch that", "replace … with …" after the field moved on) is the catalogue's D10:
/// "The text has changed" · "Your correction has not replaced anything." · Copy correction — an
/// attentive-review notice that stays until the user acts. The informational refusals (nothing to
/// scratch, too late to repair) are not failures (`RecoveryCatalog.entry(for: Reason)` is nil for
/// them): they are a transient line that fades on its own.
///
/// `Actions`' own sentence (`pillLine`) and `detail` go to the log with the entry id; the surface
/// draws only catalogue copy for a failure (design §10).
extension DeliveryPillDriver: RepairSuggestionPresenter {
    public nonisolated func present(_ suggestion: RepairSuggestion) {
        let line = suggestion.pillLine
        let detail = suggestion.detail
        let entry = RecoveryCatalog.entry(for: suggestion.reason)
        // Same hop-if-needed shape as the pill's own timers: a repair command is *already* handled
        // on the main thread, and deferring the row to a later turn of the loop is what let it be
        // raised after the pill had moved on.
        let show = { MainActor.assumeIsolated { self.show(repairLine: line, detail: detail, entry: entry) } }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }

    /// The state a repair suggestion puts on the pill: D10 for a region mismatch, else a transient line.
    nonisolated static func state(for line: String, entry: RecoveryEntry?) -> PillState {
        entry.map(PillState.recovery) ?? .preview(text: line)
    }

    private func show(repairLine: String, detail: String, entry: RecoveryEntry?) {
        log("repair suggestion \(entry?.id.rawValue ?? "info"): \(repairLine) — \(detail)")
        let state = Self.state(for: repairLine, entry: entry)
        if case .preview = state { pill.present(state) } else { pill.presentNotice(state) }
    }
}
