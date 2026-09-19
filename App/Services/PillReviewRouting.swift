import AppKit
import Foundation
import Shared
import SwiftUI

// W3H — where the pill's Review and Check buttons go (S7b hand-off: "Review in the pill opens Today,
// not the recovery sheet"), and the transform preview's own buttons (S12's manual-review "Replace
// text" / "Cancel", drawn by PillView's W3H region).
//
//   Review result (partial) · Review text (error) · Check text (unconfirmed) · a held row's Review
//     → the words are a Today draft (held / partial)  → Today + the recovery sheet for that draft
//     → the words are a recorded turn (unconfirmed)   → Today + that turn's detail (delivery evidence)
//     → neither                                       → Today
//
// The decision is a value (`PillReviewRoute.resolve`); `PillReviewWiring` carries it out on whatever
// `PillReviewHost` Today is, so AppTests drive it with a stub and no window.

/// Where one Review / Check press goes.
public enum PillReviewRoute: Equatable {
    /// The recovery sheet (S7b) for a held or partial draft: Insert here · Copy · Discard.
    case recovery(TodayDraft)
    /// The turn detail (S7b) for a turn that was written but not confirmed: text and evidence.
    case turn(TurnID)
    /// Nothing to open directly: Today itself.
    case today

    /// The presses this routing owns: Review / Check on a delivery or error row. Review on the final
    /// preview (the dwell's pause, S3/S5) and Review word on a correction (S5) are not ours.
    public static func owns(_ action: PillActionKind, shown: PillState) -> Bool {
        guard action == .review || action == .check else { return false }
        switch shown {
        case .landedPartial, .error, .held: return true
        case .landed(let info): return !info.verified
        default: return false
        }
    }

    /// The route for the row on screen. `text` is the row's own words (`PillViewModel.actionText`);
    /// `drafts` are Today's held / partial drafts; `turns` the recent turn records, newest first.
    public static func resolve(shown: PillState, text: String, drafts: [TodayDraft], turns: [TurnEntry]) -> PillReviewRoute {
        if case .held(let info) = shown, let draft = drafts.first(where: { $0.heldID == info.id }) {
            return .recovery(draft)
        }
        let key = normalized(text)
        guard !key.isEmpty else { return .today }
        if let draft = drafts.first(where: { normalized($0.text) == key }) { return .recovery(draft) }
        if let entry = turns.first(where: { normalized($0.record.finalText) == key || normalized($0.record.rawText) == key }) {
            // A recoverable turn with no draft (its held copy was resolved meanwhile) still opens its
            // detail, which says what happened; the sheet would only say "no longer available".
            return .turn(entry.id)
        }
        return .today
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// What the pill's Review needs from Today. `TodaySectionViewModel` is the app's.
@MainActor
public protocol PillReviewHost: AnyObject {
    /// Held and partial drafts, rebuilt now (the pill's row may have been raised a moment ago).
    func reviewDrafts() -> [TodayDraft]
    /// Recent turn records, newest first; empty when the turn store cannot be read.
    func reviewTurns() -> [TurnEntry]
    func presentRecovery(_ draft: TodayDraft)
    func openTurn(_ id: TurnID)
}

extension TodaySectionViewModel: PillReviewHost {
    public func reviewDrafts() -> [TodayDraft] {
        rebuildDrafts()
        return drafts
    }

    public func reviewTurns() -> [TurnEntry] {
        (try? turnReader()?.recentTurns(limit: 50)) ?? []
    }
}

/// The transform preview's buttons, when the pill shows them (manual review, S12 R1).
public enum PillTransformButton: Equatable, Sendable {
    /// "Replace text": the dwell is over; revalidate and replace once.
    case confirm
    /// "Cancel": keep the original; nothing is replaced.
    case cancel

    public static func route(_ action: PillActionKind, shown: PillState) -> PillTransformButton? {
        guard case .transform = shown else { return nil }
        switch action {
        case .commit: return .confirm
        case .cancel: return .cancel
        default: return nil
        }
    }
}

@MainActor
public enum PillReviewWiring {
    /// Carries a Review / Check press out on Today (already on screen). Returns what it did.
    @discardableResult
    public static func perform(shown: PillState, text: String, on host: PillReviewHost) -> PillReviewRoute {
        let route = PillReviewRoute.resolve(shown: shown, text: text, drafts: host.reviewDrafts(), turns: host.reviewTurns())
        switch route {
        case .recovery(let draft): host.presentRecovery(draft)
        case .turn(let id): host.openTurn(id)
        case .today: break
        }
        return route
    }

    /// Chains in front of the pill's existing button handler: Review / Check on a delivery row opens
    /// Today and then the recovery sheet or turn detail; a transform preview's Replace text / Cancel
    /// reach the transform landing. Everything else goes where it went before.
    ///
    /// `openToday` opens the window at Today and returns its host (nil when the window cannot open);
    /// `transform` receives the preview buttons.
    public static func install(on pill: PillViewModel,
                               openToday: @escaping @MainActor () -> PillReviewHost?,
                               transform: @escaping (PillTransformButton) -> Void) {
        let previous = pill.onAction
        pill.onAction = { [weak pill] action, shown in
            if let button = PillTransformButton.route(action, shown: shown) {
                transform(button)
                return
            }
            guard PillReviewRoute.owns(action, shown: shown) else {
                previous?(action, shown)
                return
            }
            let text = pill?.actionText ?? ""
            let run: @MainActor () -> Void = {
                guard let host = openToday() else { return }
                perform(shown: shown, text: text, on: host)
            }
            if Thread.isMainThread { MainActor.assumeIsolated(run) } else { Task { @MainActor in run() } }
        }
    }

    /// The live window's Today, found through the window the shell hosts (`MainWindowController`
    /// keeps its model private; the hosting controller's root view carries it).
    public static func liveToday() -> TodaySectionViewModel? {
        guard let app = NSApp else { return nil }
        for window in app.windows where window.frameAutosaveName == MainWindowController.frameAutosaveName {
            if let host = window.contentViewController as? NSHostingController<MainWindowView> {
                return host.rootView.model.today
            }
        }
        return nil
    }
}

// MARK: - The transform's rows, to the pill

/// Publishes S12's `TransformLanding.rows` to the pill with every transform event (the pill draws them
/// through PillView's W3H region). Read inside the event, the rows are the landing's own for that
/// moment: the edited preview at `.previewing`, "Updated" at `.applied`, nothing after a cancel. R1's
/// editing rows only exist once the edit has started running, which is just after `.began`, so a
/// `.began` is followed by a short re-read until they appear.
public struct TransformRowsFeed {
    public var read: () -> TransformPreviewRows?
    public var publish: (TransformPreviewRows?) -> Void
    public var sleep: () async -> Void
    public var attempts: Int

    public init(read: @escaping () -> TransformPreviewRows?, publish: @escaping (TransformPreviewRows?) -> Void,
                sleep: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 40_000_000) },
                attempts: Int = 8) {
        self.read = read
        self.publish = publish
        self.sleep = sleep
        self.attempts = attempts
    }

    public func handle(_ event: TransformPillReducer.Event) {
        publish(read())
        guard case .began = event else { return }
        let feed = self
        Task.detached { await feed.followEditing() }
    }

    /// After `.began`: publishes R1's editing rows (instruction, original unchanged) once the landing
    /// reports them. Anything else it reads is left to the event that owns it.
    public func followEditing() async {
        for _ in 0..<max(0, attempts) {
            await sleep()
            if let rows = read(), rows.designStateKey == "editing", rows.before == nil {
                publish(rows)
                return
            }
        }
    }

    /// Chains onto the landing's events (whoever listened before keeps listening, after the rows).
    /// `pill` gets the rows on the main queue, in event order.
    public static func attach(to landing: TransformLanding, pill: PillViewModel) {
        attach(to: landing) { [weak pill] rows in
            DispatchQueue.main.async { pill?.transformRows = rows }
        }
    }

    /// The same chain with any `publish` (tests record what the pill would get).
    public static func attach(to landing: TransformLanding, publish: @escaping (TransformPreviewRows?) -> Void,
                              sleep: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 40_000_000) }) {
        let feed = TransformRowsFeed(read: { [weak landing] in landing?.rows }, publish: publish, sleep: sleep)
        let previous = landing.onEvent
        landing.onEvent = { event in
            feed.handle(event)
            previous?(event)
        }
    }
}
