import Foundation
import Shared

/// R2.4 — the delivery surface of the pill and the menu: one row per `DeliveryOutcome`, the three
/// canonical error sentences, the held queue the recovery actions act on, and the quit guard.
///
/// Nothing here is a redesign (V3 §9.1, §12.12, DESIGN §8.4). The rows are the existing `Notice` /
/// preview layout, the existing glyph vocabulary and the existing `PillDwell` table; this file only
/// decides *what words* each outcome puts in them.

// MARK: - Copy

/// Every user-facing delivery sentence, as a recovery-catalogue lookup (S11, design §10).
///
/// Before S11 these were four hand-written `Problem — Action` sentences and a keyword matcher of
/// their own. They are now the catalogue's headlines, and a reason maps to its entry through
/// `RecoveryCatalog.entry(forDeliveryReason:)` — the one mapping, so the pill, the menu, Today and
/// the recovery sheet can never disagree about what a reason means. An unrecognised reason is D05
/// "Couldn’t insert your text", never the reason itself; raw reasons go to `Log` only.
public enum DeliveryCopy {
    /// D01 — "Destination changed — text held".
    public static let destinationChanged = RecoveryCatalog.entry(.D01).headline
    /// A02 — "Microphone disconnected".
    public static let microphoneDisconnected = RecoveryCatalog.entry(.A02).headline
    /// A06 — "No speech detected" (a quiet return: it fades).
    public static let noSpeechDetected = RecoveryCatalog.entry(.A06).headline
    /// D05 — "Couldn’t insert your text": any failure reason the catalogue does not name otherwise.
    public static let couldNotType = RecoveryCatalog.entry(.D05).headline
    /// D06 — "Inserted · not confirmed". "Inserted" alone means *verified*, so an unconfirmed
    /// delivery says so in words, not only in colour; it is never retried automatically.
    public static let landedUnverified = RecoveryCatalog.entry(.D06).headline

    /// The catalogue entry for a failed delivery's reason. Never the raw reason.
    public static func entry(forFailure reason: String) -> RecoveryEntry {
        RecoveryCatalog.entry(forDeliveryReason: reason)
    }

    /// Headline for a failed delivery: the entry's headline. Never the raw reason.
    public static func message(forFailure reason: String) -> String {
        entry(forFailure: reason).headline
    }

    /// The catalogue entry for a held delivery. A hold with no reason is the destination moving (D01).
    public static func entry(forHeld reason: String) -> RecoveryEntry {
        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RecoveryCatalog.entry(.D01) : RecoveryCatalog.entry(forDeliveryReason: reason)
    }

    /// Headline for a held delivery: its catalogue entry's headline. The destination is drawn beside
    /// it (the row's trailing name), never folded into the sentence.
    public static func headline(forHeld reason: String, destination: String) -> String {
        entry(forHeld: reason).headline
    }
}

// MARK: - The Spool pill's copy deck (S2)

/// Every sentence and button the Spool pill draws, verbatim from the verified prototype
/// (`Fixtures/design/design_copy.json` › `pill`, generated from `design/design_v1.html` `renderState`),
/// asserted string by string by `DesignCopyParityTests`. Nothing here is retyped from the markdown.
///
/// Three runtime substitutions only (build doc S2): the fixture's sample transcript becomes the real
/// text (so it is not stored here), "Mail" becomes the real destination (the `destination:` functions),
/// "Right Control" becomes the configured key (the `key:` functions, via `PillState.withHotkey`).
/// The timer is the real elapsed time (`PillTimer`).
public enum PillDeck {
    /// The destination name the prototype's copy uses for its sample app.
    public static let prototypeDestination = "Mail"
    public static let warnPrefix = "⚠ "

    // C0 starting
    public static let startingStatus = PillCopy.startingStatus
    public static let startingWords = PillCopy.startingWords
    public static let startingHelper = PillCopy.startingHelper

    // C1 listening
    public static let listeningStatus = "Listening"
    /// Words shown before the first partial arrives (prototype `partial || 'Listening…'`).
    public static let listeningPlaceholder = "Listening…"
    public static let listeningHelperTemplate = "Release Right Control to finish"
    public static func listeningHelper(key: String) -> String { PillState.withHotkey(listeningHelperTemplate, key: key) }
    /// Beside the helper while capture is open (prototype `pillHtml`: listening, quiet, latched).
    public static let escapeHint = "Esc · cancel"

    // C2 quiet
    public static let quietStatus = PillCopy.quietStatus
    public static let quietHelper = PillCopy.quietHelper

    // C3 latched
    public static let latchedStatus = PillCopy.latchedStatus
    public static let latchedHelperTemplate = "Tap Right Control to finish"
    public static func latchedHelper(key: String) -> String { PillState.withHotkey(latchedHelperTemplate, key: key) }
    public static let latchedButtons = [PillButton("Finish", .finish)]

    // F0 finishing (design §5: 2 s "Still finishing your text"; 10 s "Use available text" / "Cancel")
    public static let finishingStatus = PillCopy.finishingStatus
    public static let finishingSlowStatus = PillCopy.finishingSlowStatus
    public static let finishingHelper = PillCopy.finishingHelper
    public static let finishingOfferDelay: TimeInterval = 10
    public static let useAvailableText = "Use available text"
    public static let cancelLabel = "Cancel"

    // F1 preview / F2 uncertain
    public static let readyForTemplate = "Ready for Mail"
    /// "Ready for Mail", "Ready for Mail · 1 word to review"; "Ready" when no destination is known.
    /// "Ready for Mail · 1 word to review"; T05 "Ready for Mail · Review this phrase" when a rewrite
    /// marked a phrase (`phrase`, S5 `MarkMapping.needsPhraseReview`).
    public static func readyStatus(destination: String?, uncertain: Int?, phrase: Bool = false) -> String {
        let ready = destination.map(PillCopy.readyFor) ?? "Ready"
        guard let uncertain else { return ready }
        return ready + PillCopy.statusSeparator + PillCopy.reviewLine(uncertain, phrase: phrase)
    }
    public static func previewHelper(review: Bool, manual: Bool) -> String {
        switch (review, manual) {
        case (false, false): return PillCopy.previewHelperAuto
        case (false, true): return PillCopy.previewHelperManual
        case (true, false): return PillCopy.reviewHelperAuto
        case (true, true): return PillCopy.reviewHelperManual
        }
    }
    public static let manualPreviewButtons = [PillButton("Insert text", .commit, primary: true), PillButton("Cancel", .cancel)]

    // D0 inserting
    public static func insertingStatus(destination: String?) -> String {
        destination.map { "Inserting in \($0)…" } ?? "Inserting…"
    }
    public static let insertingHelper = PillCopy.insertingHelper

    // D1 inserted
    public static func insertedStatus(destination: String?) -> String {
        destination.map { "✓ Inserted in \($0)" } ?? "✓ Inserted"
    }
    /// "1 word to review in the field"; nothing when every word was confident.
    public static func insertedHelper(uncertain: Int, phrase: Bool = false) -> String {
        uncertain > 0 ? PillCopy.reviewLine(uncertain, phrase: phrase) + " in the field" : ""
    }

    // D2 unconfirmed (readback did not confirm, or could not run)
    public static let unconfirmedStatus = "⚠ Inserted · not confirmed"
    public static let unconfirmedHelper = "Check the field before trying again"
    public static let unconfirmedButtons = [PillButton("Check text", .check, primary: true), PillButton("Dismiss", .dismiss)]

    // D3 partial
    public static let partialStatus = PillCopy.partialStatus
    public static let partialHelper = PillCopy.partialHelper
    public static let partialButtons = [PillButton("Review result", .check, primary: true)]

    // H0 held
    public static let heldStatus = "⚠ Destination changed · text held"
    public static let heldHelper = "Nothing was typed into the new field"
    public static let heldButtons = [PillButton("Insert here", .insert, primary: true), PillButton("Copy text", .copy),
                                     PillButton("Discard…", .discard)]

    // C5 warning
    public static let warningStatus = "⚠ Microphone sounds unclear"
    public static let warningHelper = "Keep speaking, or check your microphone"
    public static let warningButtons = [PillButton("Check microphone", .voice)]

    // C4 cancelled
    public static let cancelledStatus = PillCopy.cancelledStatus
    public static let cancelledWords = PillCopy.cancelledWords
    public static let cancelledHelper = PillCopy.cancelledHelper

    // I2 muted
    public static let mutedStatus = PillCopy.mutedStatus
    public static let mutedWords = PillCopy.mutedWords
    public static let mutedHelper = PillCopy.mutedHelper
    public static let mutedButtons = [PillButton("Unmute", .unmute, primary: true)]

    // I3 unavailable
    public static let unavailableStatus = "⚠ Dictation is unavailable"
    public static let unavailableWords = "Install a speech model"
    public static let unavailableHelper = "No usable recognizer is ready"
    public static let unavailableButtons = [PillButton("Open Models", .models, primary: true)]

    // R1 editing ("Editing 18 words…")
    public static func editingStatus(words: Int?) -> String {
        guard let words else { return "Editing…" }
        return "Editing \(words) word\(words == 1 ? "" : "s")…"
    }
    public static let editingHelper = PillCopy.editingHelper

    // R2 undo
    public static func undoStatus(destination: String?) -> String {
        destination.map { "✓ Updated in \($0)" } ?? "✓ Updated"
    }
    public static let undoHelper = PillCopy.undoHelper
    public static let undoButtons = [PillButton("Undo", .undo, primary: true)]

    // Q0 / Q1 / Q2 meeting
    public static let meetingButtons = [PillButton("Pause", .pause), PillButton("Stop", .stop), PillButton("Expand", .meeting)]
    public static let pausedButtons = [PillButton("Resume", .resume, primary: true), PillButton("Stop", .stop)]
    public static let notesButtons = [PillButton("Open meeting", .meeting, primary: true)]

    // R0 correcting
    public static let correctingStatus = PillCopy.correctingStatus
    public static let correctingHelper = PillCopy.correctingHelper
    public static let correctingButtons = [PillButton("Review word", .review, primary: true)]

    // E1 blocked
    public static let blockedStatus = "Microphone access is off"
    public static let blockedWords = "Recording cannot start"
    public static let blockedHelper = "Nothing was recorded or typed"
    public static let blockedButtons = [PillButton("Review permissions", .permissions, primary: true)]

    // E0 error
    public static let errorStatus = "⚠ Couldn’t finish this dictation"
    public static let errorHelper = "These words were recovered. Nothing inserted."
    public static let errorButtons = [PillButton("Review text", .review, primary: true), PillButton("Copy text", .copy)]
    /// The prototype's non-committal close (D2's "Dismiss"), offered on every sticky notice with no
    /// recovery material, so "stays until the user acts" always has an action to take.
    public static let dismissLabel = "Dismiss"
}

// MARK: - Rows

/// The landed row (DESIGN §8.4 (1)–(2)). `text` is the **committed** text — what the field
/// received — never the streaming preview: closing that gap is the whole point of R2.4 (V3 §14.1).
public struct LandedPillInfo: Equatable, Sendable {
    public var text: String
    public var verified: Bool

    public init(text: String, verified: Bool) {
        self.text = text
        self.verified = verified
    }

    /// Verified: the committed text itself, in the `preview` row's style. Unverified: the fixed
    /// D06 "Inserted · not confirmed" headline (S11), with the committed text in the subtitle slot.
    public var headline: String { verified ? text : DeliveryCopy.landedUnverified }
    public var subtitle: String? { verified ? nil : text }
}

/// The held row (DESIGN §8.4 (3)): destination in the headline, the first words of the held text in
/// the subtitle, and Insert here · Copy · Discard in the ghost row's existing style and position.
public struct HeldPillInfo: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var destination: String
    public var reason: String

    public init(id: UUID = UUID(), text: String, destination: String, reason: String) {
        self.id = id
        self.text = text
        self.destination = destination
        self.reason = reason
    }

    public init(item: HeldItem) {
        self.init(id: item.id, text: item.text, destination: item.destination, reason: item.reason)
    }

    public var headline: String { DeliveryCopy.headline(forHeld: reason, destination: destination) }
    public var subtitle: String { HeldPillInfo.excerpt(of: text) }

    /// Measured, never drawn: the actions row's width, so `NotchGeometry` sizes the panel to the
    /// three buttons and they can never be clipped.
    public static let actionsLine = HeldAction.allCases.map(\.label).joined(separator: "     ")

    /// First words of the held text, so the user can tell which dictation this is without the pill
    /// growing to a paragraph.
    public static func excerpt(of text: String, words: Int = 8) -> String {
        let parts = text.split(whereSeparator: \.isWhitespace)
        let head = parts.prefix(words).joined(separator: " ")
        return parts.count > words ? "“\(head)…”" : "“\(head)”"
    }
}

/// The three recovery actions, in the order they are drawn and listed (V3 §6, DESIGN §8.4, §10).
public enum HeldAction: String, CaseIterable, Equatable, Sendable {
    case insertHere, copy, discard

    /// Pill row label.
    public var label: String {
        switch self {
        case .insertHere: return "Insert here"
        case .copy: return "Copy"
        case .discard: return "Discard"
        }
    }

    /// Accessibility identifier on the pill (DESIGN §8.4 (3)).
    public var identifier: String { "pill.held.\(rawValue)" }

    /// Menu title; the same three actions live in the status item's Recover text submenu.
    public var menuTitle: String { label }
}

// MARK: - Held queue

/// One piece of committed text with no safe destination. Held in memory until it is handled or the
/// app quits (V3 §6); persisted nowhere by this type.
public struct HeldItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var destination: String
    public var reason: String
    public var heldAt: Date

    public init(id: UUID = UUID(), text: String, destination: String, reason: String, heldAt: Date = Date()) {
        self.id = id
        self.text = text
        self.destination = destination
        self.reason = reason
        self.heldAt = heldAt
    }
}

public enum HeldActionResult: Equatable, Sendable {
    case inserted
    case copied
    case discarded
    /// The action exists but could not be carried out (no sink wired, or the insertion refused).
    /// The item stays held — never silently dropped.
    case unavailable
    case unknownItem
}

/// The app-side held queue. Deliberately decoupled from Injection's `FocusGuard` (R2.3): the two
/// sinks are closures, so the composition root can point them at the real injector and the real
/// pasteboard while tests drive them with recorders.
///
/// The queue is **bounded** (V3 §4.5). Overflow drops the oldest item, which is the only case in
/// which held text is discarded without the user asking.
public final class HeldTextStore: @unchecked Sendable {
    public private(set) var items: [HeldItem] = []
    /// Returns true when the text actually landed at the current focus.
    public var insertSink: ((HeldItem) -> Bool)?
    /// Puts the text on the pasteboard.
    public var copySink: ((HeldItem) -> Void)?
    /// Lets the owner drop its own copy of the text. Discard is the one action with nothing to
    /// show for it, so without this hook a "Discard" would clear the row and leave the words alive
    /// in `FocusGuard.held` — the opposite of what the user asked for.
    public var discardSink: ((HeldItem) -> Void)?
    public var onChange: (([HeldItem]) -> Void)?
    public var clock: () -> Date = Date.init
    public let limit: Int

    public init(limit: Int = 20) { self.limit = max(1, limit) }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var latest: HeldItem? { items.last }

    /// `id` exists so the surface can share `Injection.HeldText.id`: `FocusGuard` is the queue that
    /// actually owns the words, this one is what the pill row and the menu draw, and the two must
    /// name the same item or an action would act on the wrong one.
    @discardableResult
    public func hold(text: String, destination: String, reason: String, id: UUID = UUID()) -> HeldItem {
        let item = HeldItem(id: id, text: text, destination: destination, reason: reason, heldAt: clock())
        items.append(item)
        if items.count > limit {
            let dropped = items.removeFirst()
            Log.app.error("held queue overflow: dropped \(dropped.text.count) chars held for \(dropped.destination)")
        }
        onChange?(items)
        return item
    }

    public func item(id: UUID) -> HeldItem? { items.first { $0.id == id } }

    @discardableResult
    public func perform(_ action: HeldAction, on id: UUID) -> HeldActionResult {
        guard let item = self.item(id: id) else { return .unknownItem }
        switch action {
        case .insertHere:
            guard let insertSink else { return .unavailable }
            guard insertSink(item) else { return .unavailable }
            remove(id)
            return .inserted
        case .copy:
            guard let copySink else { return .unavailable }
            copySink(item)
            remove(id)
            return .copied
        case .discard:
            discardSink?(item)
            remove(id)
            return .discarded
        }
    }

    public func discardAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        onChange?(items)
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        onChange?(items)
    }
}

// MARK: - Outcome → row

/// One `DeliveryOutcome` → one pill row. Total by construction: every outcome has a row, which is
/// R2.4's acceptance criterion.
public enum PillDeliveryRouter {
    public static func state(for outcome: DeliveryOutcome, text: String, destination: String = "",
                             heldID: UUID = UUID()) -> PillState {
        switch outcome {
        case .delivered(let verified, _):
            return .landed(LandedPillInfo(text: text, verified: verified))
        case .partial:
            // G0.1 — some of the text may be in the destination: never a success claim, never
            // "nothing was typed". The design's partial row (G0.4, D3).
            return .landed(text: text, outcome: .partial)
        case .held(let reason):
            return .held(HeldPillInfo(id: heldID, text: text, destination: destination, reason: reason))
        case .failed(let reason):
            // S11 — the reason's catalogue entry (D05 when unrecognised); the reason itself is logged
            // by the driver, never drawn.
            return .recovery(DeliveryCopy.entry(forFailure: reason))
        }
    }
}

// MARK: - Menu

/// The status item's Recover text section (DESIGN §10). Pure so the copy is testable without a
/// status item.
public enum HeldMenu {
    public static func isVisible(count: Int) -> Bool { count > 0 }

    public static func title(count: Int) -> String {
        count > 1 ? "Recover text (\(count))" : "Recover text"
    }

    /// Disabled header above one item's three actions.
    public static func header(for item: HeldItem) -> String {
        let name = item.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = HeldPillInfo.excerpt(of: item.text, words: 6)
        return name.isEmpty ? excerpt : "\(excerpt) — \(name)"
    }

    public static let actions = HeldAction.allCases
}

// MARK: - Quit guard

/// Quitting with held text loses it, so it warns first and names how much would be lost
/// (V3 §6, DESIGN §10). Pure decision; the caller runs the alert.
public enum QuitGuard {
    public enum Decision: Equatable, Sendable {
        case quit
        case warn(title: String, message: String)

        public var warns: Bool { if case .warn = self { return true }; return false }
    }

    public static let title = "Held text has not been typed"
    public static let quitAnyway = "Quit anyway"
    public static let keepRunning = "Keep VoicePlus running"

    public static func decision(heldCount: Int) -> Decision {
        guard heldCount > 0 else { return .quit }
        return .warn(title: title, message: message(heldCount: heldCount))
    }

    public static func message(heldCount: Int) -> String {
        heldCount == 1
            ? "One piece of dictated text is still waiting for a destination. Quitting discards it."
            : "\(heldCount) pieces of dictated text are still waiting for a destination. Quitting discards them."
    }
}
