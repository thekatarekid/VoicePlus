import Engine
import Foundation
import Shared

// S7b — the recovery sheet (design §8.1, prototype `case'recovery'`; `DESIGN.md` §9.1): the
// complete payload, the current destination preview, and three explicit ways out — **Insert here**
// (an explicit re-target that revalidates the picked field before writing), **Copy text**
// (acknowledged only when the copy is verified) and **Discard…** (confirmed when it destroys the only
// saved copy). Closing the sheet keeps the draft. Retention is stated in the design's words: "Kept
// until resolved", or "Kept for this session only" when persistence is off or a save failed.
//
// Pure state; the sheet view (`RecoverySheetView`) decides nothing.

@MainActor
public final class RecoverySheetModel: ObservableObject, Identifiable {
    /// Where the sheet's one action stands.
    public enum Phase: Equatable, Sendable {
        case idle
        /// Bringing the picked app forward, revalidating its field, writing once.
        case inserting
        /// Insert here wrote: verified, unconfirmed (D06) or partial (D07). The draft is resolved.
        case inserted(DeliveryOutcome, destination: String)
        /// Copy was verified. The draft is resolved.
        case copied
        case discarded
        /// Nothing was written or copied; the draft is kept. The entry names what and why.
        case problem(RecoveryID)

        /// The draft left the held list through this sheet.
        public var resolvesDraft: Bool {
            switch self {
            case .inserted, .copied, .discarded: return true
            case .idle, .inserting, .problem: return false
            }
        }
    }

    public nonisolated let id = UUID()
    /// content / loading ("Opening saved text…") / empty ("This draft is no longer available").
    @Published public private(set) var state: SectionState
    /// The draft on screen. Kept after it resolves so the acknowledgement still names it.
    @Published public private(set) var draft: TodayDraft?
    /// The current destination preview: the field Insert here would use.
    @Published public private(set) var target: RecoveryTarget?
    @Published public private(set) var phase: Phase = .idle
    /// "Discard…" on the only saved copy waits here for a yes.
    @Published public var confirmingDiscard = false
    /// Bumped by D08's "Select text": the payload view selects all of it.
    @Published public private(set) var selectAllRequest = 0

    private weak var host: TodayDraftHost?
    private let openingTurn: TurnID?

    /// The sheet for a draft Today already has.
    public init(draft: TodayDraft?, host: TodayDraftHost) {
        self.host = host
        self.draft = draft
        self.openingTurn = nil
        self.state = draft == nil ? Self.nothingWaiting(host.hotkeyLabel) : .content
    }

    /// The sheet for a turn, resolved by `load()` ("Opening saved text…" until then).
    public init(turn: TurnID, host: TodayDraftHost) {
        self.host = host
        self.draft = nil
        self.openingTurn = turn
        self.state = .loading(.recovery, headline: TodayCopy.openingSavedText)
    }

    // MARK: Loading and following the draft

    public func load() {
        if let turn = openingTurn, draft == nil {
            if let found = host?.draft(forTurn: turn) {
                draft = found
                state = .content
            } else {
                state = Self.noLongerAvailable
            }
        }
        refreshTarget()
    }

    /// The draft as it is now. One resolved somewhere else (the pill, the menu) while the sheet was
    /// open is "no longer available" — unless this sheet resolved it, which it says instead.
    public func refreshDraft() {
        guard let draft, !phase.resolvesDraft, let host else { return }
        if let current = host.currentDraft(draft) {
            self.draft = current
        } else if phase != .inserting {
            state = Self.noLongerAvailable
        }
    }

    /// Re-reads where Insert here would go (on appear, and whenever VoicePlus comes back to the
    /// front — i.e. after the user picked a field somewhere else).
    public func refreshTarget() {
        guard phase != .inserting else { return }
        target = host?.destinations.pickedTarget()
        if case .problem(let id) = phase, [.D01, .D02, .D03].contains(id) {
            // A new pick clears the old verdict about the old field.
            phase = .idle
        }
    }

    // MARK: What the sheet says

    public static let noLongerAvailableHeadline = "This draft is no longer available"
    public static let noLongerAvailableDetail = "It was inserted, copied or discarded somewhere else, or it was deleted."

    /// Design §9 Turn detail / recovery empty.
    static let noLongerAvailable = SectionState.empty(noLongerAvailableHeadline, detail: noLongerAvailableDetail,
                                                      action: DesignScreen.recovery.empty.action)

    /// The fixture's recovery empty (nothing held at all).
    static func nothingWaiting(_ hotkey: String) -> SectionState { .empty(.recovery, hotkey: hotkey) }

    /// "Your text is still here." (fixture `screens.recovery.title`).
    public var title: String { DesignScreen.recovery.page?.title ?? "" }

    /// "Destination changed · held for Mail" — the fixture's subtitle, from the real draft.
    public var subtitle: String { draft?.sheetSubtitle ?? "" }

    /// The banner over the payload: S03 when the save failed (Copy is primary then), D07 for a
    /// partial, and the prototype's "Nothing was inserted" otherwise.
    public var banner: SectionBanner? {
        guard let draft else { return nil }
        if draft.retention == .saveFailed { return .recovery(RecoveryCatalog.entry(.S03)) }
        if draft.kind == .partial { return .recovery(RecoveryCatalog.entry(.D07)) }
        return SectionBanner(headline: Self.nothingInsertedHeadline, body: Self.nothingInsertedBody)
    }

    /// Prototype recovery banner, verbatim.
    public static let nothingInsertedHeadline = "Nothing was inserted"
    public static let nothingInsertedBody = "Select a text field, then explicitly choose Insert here. A new destination will never receive this text automatically."

    /// Copy is the primary action when the text exists only in this window (design §9: "Keep
    /// in-memory copy if storage fails; Copy is primary").
    public var copyIsPrimary: Bool { draft?.retention == .saveFailed }

    /// The current destination preview.
    public var destinationLine: String {
        guard let host else { return "" }
        guard host.destinations.canReadFields else { return RecoveryCatalog.entry(.P02).headline + ". " + RecoveryCatalog.entry(.P02).consequence }
        guard let target else { return Self.noFieldChosen }
        if target.isSecure { return "\(target.summary). \(RecoveryCatalog.entry(.D03).consequence)" }
        guard target.isEditable else { return "\(target.appName.isEmpty ? TodayCopy.unknownApp : target.appName) has no text field selected. \(Self.pickAField)" }
        return "Insert here goes to \(target.summary)."
    }

    public static let pickAField = "Click into the field you want, then come back and choose Insert here."
    public static let noFieldChosen = "No text field chosen yet. " + pickAField

    /// "Kept until resolved · closing this window keeps the draft." and its follow-up line
    /// (prototype recovery footnote); the session-only wording when that is the truth.
    public var retentionLines: [String] {
        guard let draft else { return [] }
        var lines: [String]
        switch draft.retention {
        case .keptUntilResolved:
            lines = ["\(TurnStore.keptUntilResolvedLabel) · closing this window keeps the draft.",
                     "If saving fails, this changes to “\(TurnStore.sessionOnlyLabel)”."]
        case .sessionOnly, .saveFailed:
            lines = ["\(TurnStore.sessionOnlyLabel) · closing this window keeps the draft until VoicePlus quits."]
        }
        if host?.historyEnabled == false {
            lines.append("Dictation history is off. Held text is kept separately, and only until you resolve it.")
        }
        return lines
    }

    /// The line under the actions once something happened.
    public var outcomeNotice: TodayNotice? {
        switch phase {
        case .idle, .inserting: return nil
        case let .inserted(outcome, destination):
            if let entry = RecoveryCatalog.entry(for: outcome) {
                return TodayNotice(text: entry.headline, detail: entry.consequence, tone: .warn, recoveryID: entry.id)
            }
            return TodayNotice(text: destination.isEmpty ? "Inserted" : "Inserted in \(destination)", tone: .good)
        case .copied: return .copied
        case .discarded: return TodayNotice(text: "Discarded", tone: .good)
        case .problem(let id): return .problem(id)
        }
    }

    /// The problem notice's own recovery action (catalogue `action`), where the sheet can do it.
    public var problemAction: String? {
        guard case .problem(let id) = phase else { return nil }
        switch id {
        case .P02, .D08, .D05, .D02: return RecoveryCatalog.entry(id).action
        default: return nil
        }
    }

    // MARK: Actions

    public var isResolved: Bool { phase.resolvesDraft }
    public var canAct: Bool { state.isContent && draft != nil && !isResolved && phase != .inserting }

    /// Insert here: an explicit re-target. The field the user picked must be a text field, not a
    /// password field; its app is brought forward and the field that has focus then must still be
    /// the one picked — otherwise nothing is written and the text stays held (D01). One write.
    public func insertHere() async {
        guard canAct, let host, let draft else { return }
        let destinations = host.destinations
        guard destinations.canReadFields else { phase = .problem(.P02); return }
        target = destinations.pickedTarget()
        guard let picked = target, picked.isEditable else { phase = .problem(.D02); return }
        guard !picked.isSecure else { phase = .problem(.D03); return }
        phase = .inserting
        let now = await destinations.bringForward(picked)
        guard let now, now.isSameField(as: picked), now.isEditable, !now.isSecure else {
            target = now ?? destinations.pickedTarget()
            phase = .problem(now?.isSecure == true ? .D03 : .D01)
            return
        }
        // The draft may have been resolved elsewhere while its app came forward.
        guard let current = host.currentDraft(draft) else {
            phase = .idle
            state = Self.noLongerAvailable
            return
        }
        self.draft = current
        guard let outcome = host.insert(current, into: now) else {
            phase = .problem(.D05)
            return
        }
        switch outcome {
        case .delivered, .partial:
            phase = .inserted(outcome, destination: now.appName)
        case .held:
            // Focus moved during the write: nothing was typed, the text is held again.
            phase = .problem(.D01)
            self.draft = host.currentDraft(current) ?? current
        case .failed:
            phase = .problem(RecoveryCatalog.entry(for: outcome)?.id ?? .D05)
        }
    }

    /// Copy text: acknowledged only after the pasteboard was read back.
    public func copy() {
        guard canAct, let host, let draft else { return }
        phase = host.copy(draft) ? .copied : .problem(.D08)
    }

    /// Discard…: asks first when this is the only saved copy.
    public func requestDiscard() {
        guard canAct, let host, let draft else { return }
        if host.discardNeedsConfirmation(draft) {
            confirmingDiscard = true
        } else {
            performDiscard()
        }
    }

    public func confirmDiscard() {
        confirmingDiscard = false
        performDiscard()
    }

    public func cancelDiscard() { confirmingDiscard = false }

    private func performDiscard() {
        guard canAct, let host, let draft else { return }
        host.discard(draft)
        phase = .discarded
    }

    /// The problem notice's action: open Accessibility settings (P02), select the text for a manual
    /// copy (D08), or copy it (D05, D02).
    public func performProblemAction() {
        guard case .problem(let id) = phase else { return }
        switch id {
        case .P02: host?.destinations.openAccessibilitySettings()
        case .D08: selectAllRequest += 1
        case .D05, .D02:
            phase = .idle
            copy()
        default: break
        }
    }

    /// Discard confirmation copy (design §5.2: say what goes, name both ways out).
    public static let discardHeadline = "Discard this text?"
    public static let discardDetail = "This is the only saved copy. It can’t be recovered after you discard it."
    public static let discardConfirm = "Discard"
}
