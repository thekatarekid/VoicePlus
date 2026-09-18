import Foundation
import Shared

/// R2.4 — the delivery surface of the pill and the menu: one row per `DeliveryOutcome`, the three
/// canonical error sentences, the held queue the recovery actions act on, and the quit guard.
///
/// Nothing here is a redesign (V3 §9.1, §12.12, DESIGN §8.4). The rows are the existing `Notice` /
/// preview layout, the existing glyph vocabulary and the existing `PillDwell` table; this file only
/// decides *what words* each outcome puts in them.

// MARK: - Copy

/// Every user-facing delivery sentence, in one place, in the `Problem — Action` voice (DESIGN §7.1).
///
/// The three strings V3 §6 fixes verbatim are stored as constants and asserted by
/// `DeliveryCopyTests`; the fallback exists so that a reason we do not recognise still reads as a
/// sentence with an action instead of leaking `localizedDescription`, an OSStatus or an AX code.
/// Raw reasons go to `Log` only.
public enum DeliveryCopy {
    public static let destinationChanged = "Destination changed — Copy text"
    public static let microphoneDisconnected = "Microphone disconnected — Choose microphone"
    public static let noSpeechDetected = "No speech detected — Try again"
    /// Same shape, used for any failure reason that is not one of the three above.
    ///
    /// The action is "Try again", not "Copy text": a *failed* delivery holds nothing (only
    /// `.held` outcomes reach `HeldTextStore`), so offering Copy would name an action the user
    /// cannot take. Pressing the key again is the one that exists, and it is what the pill's
    /// existing `errorSubtitle` already tells them.
    public static let couldNotType = "Text was not typed — Try again"

    /// The unverified landed headline (DESIGN §8.4 (2)). "Landed" alone means *verified*, so an
    /// unconfirmed delivery has to say so in words, not only in colour.
    public static let landedUnverified = "Landed · not confirmed"

    /// Headline for a failed delivery. Never the raw reason.
    public static func message(forFailure reason: String) -> String {
        switch category(of: reason) {
        case .destination: return destinationChanged
        case .microphone: return microphoneDisconnected
        case .noSpeech: return noSpeechDetected
        case .other: return couldNotType
        }
    }

    /// Headline for a held delivery: name the destination when we know it, otherwise fall back to
    /// the canonical "Destination changed — Copy text".
    ///
    /// The name is suppressed for exactly one reason — the destination *changed*, which makes the
    /// snapshotted name stale, and V3 §6 fixes the sentence for that case. Every other hold (an
    /// app on the never-inject list, a target whose safety could not be established) still knows
    /// where the text was going, so it says so.
    public static func headline(forHeld reason: String, destination: String) -> String {
        let name = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || isDestinationChange(reason) { return destinationChanged }
        return "Held for \(name)"
    }

    /// "The destination moved out from under us", as opposed to "we chose not to type here".
    /// Narrower than `category(of:)` on purpose: "no safe destination" contains the word
    /// *destination* but the destination never changed.
    static func isDestinationChange(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("destination changed") || r.contains("focus")
    }

    enum Category: Equatable { case destination, microphone, noSpeech, other }

    /// Keyword match on the *internal* reason string. Deliberately conservative: anything it does
    /// not recognise becomes `couldNotType`, so no unknown reason can reach a user-facing string.
    static func category(of reason: String) -> Category {
        let r = reason.lowercased()
        // Reasons that mean "nothing was typed and there is nothing to copy" are checked first,
        // because two of them contain the word "destination" without the destination having
        // *changed*. `Injection.DeliveryReason` is the producer; matched as text, not imported, so
        // this file stays a copy deck with no policy dependency.
        if r == "no destination" || r == "every method threw" || r.contains("secure field")
            || r.contains("password") {
            return .other
        }
        if r.contains("destination") || r.contains("focus") || r.contains("target")
            || r.contains("never-inject") || r.contains("never inject") {
            return .destination
        }
        if r.contains("microphone") || r.contains("mic ") || r == "mic" || r.contains("input device")
            || r.contains("device disconnected") || r.contains("no input") {
            return .microphone
        }
        if r.contains("no speech") || r.contains("silence") || r.contains("silent")
            || r.contains("empty") || r.contains("nothing heard") {
            return .noSpeech
        }
        return .other
    }
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
    /// "Landed · not confirmed" headline, with the committed text in the subtitle slot.
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
            return .error(message: DeliveryCopy.message(forFailure: reason))
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
