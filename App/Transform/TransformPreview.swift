import Engine
import Foundation
import Injection
import Pipeline
import Shared

// S12 — selected-text transforms: before / after preview, replace only after target revalidation,
// range-safe Undo (design_v1 §6 R1 "Editing selection", R2 "Undo available"; §8.8).
//
//   editing (R1, model running, original unchanged)
//     → previewing (R1, edited final preview; original still unchanged; dwell, pause, cancel)
//     → revalidate the target (same app, same field, the selected text still reads as it did)
//     → replacing (one replace attempt) → updated (R2, Undo for 5 s while the range still matches)
//   A target that changed is never written: the edited text is held for recovery (D10).

// MARK: - The preview

/// What the user sees before anything is replaced: the original selection, the edited text, the
/// word diff between them, and where it will land. Immutable: a different edit is a new preview.
public struct TransformPreview: Equatable, Sendable {
    public let instruction: String
    public let before: String
    public let after: String
    public let diff: Pipeline.WordDiff
    /// The app's display name ("Mail"), when the focus snapshot knew it.
    public let destination: String?

    public init(instruction: String, before: String, after: String, destination: String? = nil) {
        self.instruction = instruction
        self.before = before
        self.after = after
        self.diff = Pipeline.WordDiff.compute(old: before, new: after)
        let name = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.destination = name.isEmpty ? nil : name
    }

    /// Words in the original selection ("Editing 18 words…").
    public var wordCount: Int { before.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    /// Words removed plus words added.
    public var changedCount: Int { diff.deleted + diff.inserted }

    /// The removed words and the added words, in order (newlines dropped).
    public var removedText: String { Self.words(diff, deleted: true) }
    public var addedText: String { Self.words(diff, deleted: false) }

    private static func words(_ diff: Pipeline.WordDiff, deleted: Bool) -> String {
        diff.ops.compactMap { op -> String? in
            switch op {
            case .delete(let w) where deleted && w != "\n": return w
            case .insert(let w) where !deleted && w != "\n": return w
            default: return nil
            }
        }.joined(separator: " ")
    }
}

// MARK: - Copy

/// The transform pill's sentences. R1 and R2 are verbatim from the verified prototype
/// (`Fixtures/design/design_copy.json` › `pill.editing` / `pill.undo`, with the sample count and
/// "Mail" replaced by the real ones); the stale-range recovery is the catalogue's D10.
public enum TransformPreviewCopy {
    /// R1 status: "Editing 18 words…".
    public static func editingStatus(words: Int) -> String {
        "Editing \(words) word\(words == 1 ? "" : "s")…"
    }
    /// R1 helper — true for the whole of R1, preview included: nothing has been replaced yet.
    public static let editingHelper = PillCopy.editingHelper

    /// The edited final preview's status, in F1's words ("Ready for Mail"). Without a destination
    /// name R1's own status stays ("Editing 18 words…"): the design has no destination-less
    /// "Ready for" line and none is invented.
    public static func previewStatus(destination: String?, words: Int) -> String {
        destination.map(PillCopy.readyFor) ?? editingStatus(words: words)
    }
    /// Manual review only: nothing is replaced until "Replace text".
    public static let replaceButton = "Replace text"
    public static let cancelButton = "Cancel"

    /// R2 status: "✓ Updated in Mail".
    public static func updatedStatus(destination: String?) -> String {
        destination.map { "✓ Updated in \($0)" } ?? "✓ Updated"
    }
    public static let undoHelper = PillCopy.undoHelper
    public static let undoButton = "Undo"

    /// One line for the transform row: the removed words → the added words.
    public static func compactLine(_ preview: TransformPreview, limit: Int = 28) -> String {
        let removed = excerpt(preview.removedText, limit: limit)
        let added = excerpt(preview.addedText, limit: limit)
        switch (removed.isEmpty, added.isEmpty) {
        case (true, true): return previewStatus(destination: preview.destination, words: preview.wordCount)
        case (true, false): return "Preview · + \(added)"
        case (false, true): return "Preview · − \(removed)"
        case (false, false): return "Preview · \(removed) → \(added)"
        }
    }
    /// Cancelled before the replacement: the original stays.
    public static let cancelledLine = "Original text kept · nothing replaced"
    /// Undo asked for after its 5 s window.
    public static let undoExpiredLine = "Undo is no longer available"

    /// D10 — "The text has changed" / "Your correction has not replaced anything." / "Copy correction".
    public static var stale: RecoveryEntry { RecoveryCatalog.entry(.D10) }

    static func excerpt(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit, limit > 1 else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

/// The rows the pill draws for one phase: status line, the text lane (before struck through, after
/// in full), helper line and buttons — the same anatomy as every other pill state.
public struct TransformPreviewRows: Equatable, Sendable {
    public struct Button: Equatable, Sendable {
        public let label: String
        /// The action id, in the copy fixture's vocabulary ("commit", "cancel", "undo").
        public let action: String
        public let primary: Bool
    }
    public let designStateKey: String
    public let status: String
    /// The original selection, drawn struck through. `nil` when the phase shows only one text.
    public let before: String?
    /// The text the phase is about: the instruction while editing, the edited text afterwards.
    public let text: String
    public let helper: String
    public let buttons: [Button]

    /// R1 while the model runs: the instruction, original unchanged.
    public static func editing(words: Int, instruction: String) -> TransformPreviewRows {
        TransformPreviewRows(designStateKey: "editing", status: TransformPreviewCopy.editingStatus(words: words),
                             before: nil, text: instruction, helper: TransformPreviewCopy.editingHelper, buttons: [])
    }

    /// R1's edited final preview: before and after, still nothing replaced. Buttons only in manual
    /// review — an automatic preview replaces when its dwell ends, after revalidation.
    public static func preview(_ p: TransformPreview, manual: Bool) -> TransformPreviewRows {
        TransformPreviewRows(designStateKey: "editing", status: TransformPreviewCopy.previewStatus(destination: p.destination, words: p.wordCount),
                             before: p.before, text: p.after, helper: TransformPreviewCopy.editingHelper,
                             buttons: manual ? [Button(label: TransformPreviewCopy.replaceButton, action: "commit", primary: true),
                                                Button(label: TransformPreviewCopy.cancelButton, action: "cancel", primary: false)] : [])
    }

    /// R2: replaced; Undo while the edited range still matches.
    public static func updated(_ p: TransformPreview) -> TransformPreviewRows {
        TransformPreviewRows(designStateKey: "undo", status: TransformPreviewCopy.updatedStatus(destination: p.destination),
                             before: nil, text: p.after, helper: TransformPreviewCopy.undoHelper,
                             buttons: [Button(label: TransformPreviewCopy.undoButton, action: "undo", primary: true)])
    }
}

// MARK: - Target revalidation

/// Re-reads the destination right before a replacement or an undo. Replace only when the same app
/// and the same field still hold exactly the text the preview was made from; anything unreadable
/// counts as changed — a write is never made blind.
public enum TransformTargetCheck {
    public enum Failure: String, Equatable, Sendable {
        /// Another app is frontmost.
        case appChanged
        /// Same app, another field.
        case fieldChanged
        /// The range no longer reads as the expected text (edited, or the range moved).
        case textChanged
        /// The field's text or focus could not be read.
        case unreadable

        /// The held-text reason (`DeliveryOutcome.held`): focus changes read as "destination
        /// changed" (D01); an edited or unreadable range as a changed target.
        public var heldReason: String {
            switch self {
            case .appChanged, .fieldChanged: return DeliveryReason.destinationChanged
            case .textChanged, .unreadable: return "target text changed"
            }
        }
    }

    public enum Result: Equatable, Sendable {
        case valid
        case changed(Failure)
        public var isValid: Bool { self == .valid }
    }

    /// `range` / `expected` are the region to be replaced; `bundleID` / `elementToken` the focus
    /// snapshot the selection was read from (nil = not known, not compared).
    public static func verify(range: Range<Int>, expected: String, bundleID: String?, elementToken: String?,
                              system: SystemAccess) -> Result {
        let front = system.frontmostApp()
        if let bundleID, front?.bundleID != bundleID { return .changed(.appChanged) }
        if let elementToken, let now = front?.elementToken, now != elementToken { return .changed(.fieldChanged) }
        guard let info = try? system.focusedElement(), let value = info.value else { return .changed(.unreadable) }
        let units = Array(value.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return .changed(.textChanged) }
        return String(decoding: units[range], as: UTF16.self) == expected ? .valid : .changed(.textChanged)
    }

    /// The region a staged replacement would overwrite, against the snapshot it came from.
    public static func verify(_ request: TransformReplaceRequest, selection: SelectionSnapshot, system: SystemAccess) -> Result {
        verify(range: request.range, expected: request.expected, bundleID: selection.bundleID,
               elementToken: request.elementToken ?? selection.elementToken, system: system)
    }
}

// MARK: - The gate

/// How long the edited preview stays before the replacement is attempted. Same values as the final
/// preview's dwell (build doc §2): 900 ms by default; `manual` waits for "Replace text".
public struct TransformPreviewDwell: Equatable, Sendable {
    public var seconds: TimeInterval
    public var manual: Bool
    public init(seconds: TimeInterval, manual: Bool = false) { self.seconds = max(0, seconds); self.manual = manual }
    public static let standard = TransformPreviewDwell(seconds: 0.9)
    public static let manualReview = TransformPreviewDwell(seconds: 0, manual: true)
    /// The longest timed choice in Settings (build doc §2: 600 / 900 / 1500 ms / manual).
    public static let longestTimed = TransformPreviewDwell(seconds: 1.5)

    /// The Settings dwell (`preview.dwell`) in seconds; `nil` is the manual choice ("Until I
    /// insert"), which waits for the pill's "Replace text" (or Cancel / Escape) and replaces nothing
    /// on its own: the rows are `TransformPreviewRows.preview(_:manual: true)`.
    public static func fromSetting(seconds: TimeInterval?) -> TransformPreviewDwell {
        seconds.map { TransformPreviewDwell(seconds: $0) } ?? .manualReview
    }
}

/// The pure R1 → R2 state machine for one transform. The only way to `replacing` is through
/// `previewing` → dwell over (or an explicit confirm) → a valid revalidation. The only way to
/// `undone` is inside the undo window with the edited range still matching.
public struct TransformPreviewGate: Equatable, Sendable {
    public static let undoWindow: TimeInterval = TransformGhost.lifetime
    /// Pause and manual review poll in slices this long.
    public static let slice: TimeInterval = 0.05

    public enum Phase: Equatable, Sendable {
        case idle
        /// R1: the rewrite is running. Original unchanged.
        case editing
        /// R1: the edited preview is showing. Original unchanged.
        case previewing
        /// Revalidated; the single replace attempt is in flight.
        case replacing
        /// R2: replaced. Undo is open until `undoWindow` has passed.
        case updated(at: Date)
        /// The user kept the original. Nothing was replaced.
        case cancelled
        /// The target changed before the replacement. Nothing was replaced; the edit is held.
        case held(TransformTargetCheck.Failure)
        /// The replace attempt itself failed. Nothing is claimed.
        case failed
        /// Undo put the original back.
        case undone
    }

    /// What the waiting loop does next while `previewing`.
    public enum Decision: Equatable, Sendable {
        case wait(TimeInterval)
        case commit
        case cancel
    }

    public enum UndoVerdict: Equatable, Sendable {
        case allowed
        /// Nothing replaced, or already undone.
        case nothingToUndo
        /// The 5 s window has passed.
        case expired
        /// The edited range no longer matches; the original is offered for recovery instead.
        case stale(TransformTargetCheck.Failure)
    }

    public private(set) var phase: Phase = .idle
    public let dwell: TransformPreviewDwell
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var paused = false
    public private(set) var confirmed = false

    public init(dwell: TransformPreviewDwell = .standard) { self.dwell = dwell }

    public mutating func begin() {
        phase = .editing
        elapsed = 0; paused = false; confirmed = false
    }

    /// The edit is ready: show it. Only from `editing`.
    public mutating func showPreview() {
        guard phase == .editing else { return }
        phase = .previewing
        elapsed = 0
    }

    /// Hover, focus or selection on the pill freezes the dwell (design §2 "Dwell").
    public mutating func setPaused(_ on: Bool) {
        guard phase == .previewing else { return }
        paused = on
    }

    /// "Replace text" — the explicit confirm manual review waits for.
    public mutating func confirm() {
        guard phase == .previewing else { return }
        confirmed = true
    }

    /// Escape / Cancel / a new turn: keep the original. Only before the write.
    public mutating func cancel() {
        guard phase == .editing || phase == .previewing else { return }
        phase = .cancelled
    }

    /// Dwell time passed on the waiting loop's own clock (never the wall clock, so a frozen or
    /// test clock can neither skip nor stall the preview). Paused time does not count.
    public mutating func advance(by dt: TimeInterval) {
        guard phase == .previewing, !paused, dt > 0 else { return }
        elapsed += dt
    }

    public var isDue: Bool {
        guard phase == .previewing else { return false }
        if confirmed { return true }
        return !dwell.manual && !paused && elapsed >= dwell.seconds
    }

    public var decision: Decision {
        switch phase {
        case .cancelled: return .cancel
        case .previewing:
            if isDue { return .commit }
            if paused || dwell.manual { return .wait(Self.slice) }
            return .wait(max(0, min(Self.slice, dwell.seconds - elapsed)))
        default:
            return .cancel
        }
    }

    /// The last check before writing. `true` = the one replace attempt may be made now.
    public mutating func revalidate(_ check: TransformTargetCheck.Result) -> Bool {
        guard isDue else { return false }
        switch check {
        case .valid:
            phase = .replacing
            return true
        case .changed(let why):
            phase = .held(why)
            return false
        }
    }

    public mutating func replaced(_ outcome: TransformReplaceOutcome, at now: Date) {
        guard phase == .replacing else { return }
        switch outcome {
        case .replaced: phase = .updated(at: now)
        case .mismatch: phase = .held(.textChanged)
        case .unavailable: phase = .failed
        }
    }

    public func undoVerdict(at now: Date, check: TransformTargetCheck.Result) -> UndoVerdict {
        guard case .updated(let at) = phase else { return .nothingToUndo }
        guard now.timeIntervalSince(at) < Self.undoWindow else { return .expired }
        if case .changed(let why) = check { return .stale(why) }
        return .allowed
    }

    public mutating func undone() {
        guard case .updated = phase else { return }
        phase = .undone
    }

    public var isWaiting: Bool { phase == .editing || phase == .previewing }
}

// MARK: - Recovery

/// Text the transform could not safely write or put back, handed to the held-text surface.
public struct TransformRecovery: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The target changed before the replacement: the *edited* text is held.
        case editNotApplied
        /// Undo found the range changed: the *original* text is held.
        case undoNotApplied
    }
    public let kind: Kind
    public let text: String
    public let destination: String
    public let failure: TransformTargetCheck.Failure

    /// The catalogue entry for both kinds (D10: "The text has changed").
    public var entry: RecoveryEntry { TransformPreviewCopy.stale }
    /// The reason `DeliveryPillDriver.handle(.held(reason:) …)` files it under.
    public var heldReason: String { failure.heldReason }
}
