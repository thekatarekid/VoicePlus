import Foundation
import Shared

/// Committed text with no safe destination (Build doc §2, V3 §6).
///
/// It exists because the text is *final* — recognised, formatted, never to be retracted — and the
/// place it was meant to go is gone, refused, or unknown. It waits for the user: **Insert here**,
/// **Copy**, **Discard**. Nothing else may deliver it, and nothing delivers it on a timer.
public struct HeldText: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The original request, so `insertHere()` re-runs the full stack (focus check included).
    public var request: InjectionRequest
    /// The segment this text came from, when it came from one (R2.2/R2.3 ordered commit).
    public var segmentID: SegmentID?
    /// Where it was meant to go — used to name the destination in the pill.
    public var destination: FocusSnapshot?
    /// Why it is held: `"destination changed"`, `"never-inject list"`, … (see `DeliveryReason`).
    public var reason: String
    public var heldAt: Date
    /// S3 — the turn this text is the final payload of, when it came through the turn gate. Lets
    /// the turn record follow the held text to Insert here / Copy / Discard.
    public var turnID: TurnID?

    public init(id: UUID = UUID(), request: InjectionRequest, segmentID: SegmentID? = nil,
                destination: FocusSnapshot?, reason: String, heldAt: Date = Date(), turnID: TurnID? = nil) {
        self.id = id
        self.request = request
        self.segmentID = segmentID
        self.destination = destination
        self.reason = reason
        self.heldAt = heldAt
        self.turnID = turnID
    }

    public var text: String { request.text }

    /// The name to show the user: the app's localized name, its bundle ID as a fallback.
    public var destinationName: String {
        guard let destination else { return "" }
        return destination.appName.isEmpty ? destination.bundleID : destination.appName
    }

    /// `held(reason:)` — held is deliberately *not* terminal.
    public var outcome: DeliveryOutcome { .held(reason: reason) }
}

/// S3 — how held text left the list, for whoever keeps the turn's record.
public enum HeldResolution: Equatable, Sendable {
    /// Insert here ran the stack against the focus of the moment; this is what it came to. A
    /// `.abortedFocusChanged` means it is held again (as a new item carrying the same turn).
    case inserted(InjectionOutcome)
    case copied
    case discarded
}

// MARK: - S3 — the destination a turn is aimed at, and whether it still is

/// The destination as one read saw it: app and element, selection, and the field's text version.
/// Taken at a turn's key-down snapshot (design §5 step 1) and read again at the end of dwell
/// (step 5); `FocusGuard.revalidate` compares the two.
public struct TargetRevision: Equatable, Sendable {
    /// App, process and element identity (`FocusSnapshot.elementToken`).
    public var focus: FocusSnapshot?
    /// AX role of the focused element.
    public var role: String?
    /// Selection in UTF-16 units, when the element exposes one.
    public var selection: Range<Int>?
    /// `TargetRevision.version(of:)` of the field's `kAXValue`; `nil` when AX exposes no value.
    public var textVersion: Int?
    /// A password field. Never written.
    public var isSecure: Bool
    /// rq — the element's value or selected text is settable (`nil`: not read). With the role and
    /// `textVersion` this answers `DeliveryLadder.fieldPresence` for web content.
    public var isTextSettable: Bool?

    public init(focus: FocusSnapshot?, role: String? = nil, selection: Range<Int>? = nil,
                textVersion: Int? = nil, isSecure: Bool = false, isTextSettable: Bool? = nil) {
        self.focus = focus
        self.role = role
        self.selection = selection
        self.textVersion = textVersion
        self.isSecure = isSecure
        self.isTextSettable = isTextSettable
    }

    /// rq (2026-10-04) — is a text field focused? `DeliveryLadder.fieldPresence` over this read:
    /// the value is blank when AX exposed none or exposed exactly "" (`textVersion`).
    public func fieldPresence(runtime: SurfaceRuntime?) -> DeliveryLadder.FieldPresence {
        let blank = textVersion == nil || textVersion == Self.version(of: "")
        return DeliveryLadder.fieldPresence(role: role, valueBlank: blank, textSettable: isTextSettable,
                                            runtime: runtime, isSecure: isSecure)
    }

    /// The element identity as a number (`TurnRecord.Destination.elementHash`): the token itself
    /// when it is numeric (a `CFHash`), its stable hash otherwise.
    public var elementHash: Int? {
        guard let token = focus?.elementToken, !token.isEmpty else { return nil }
        return Int(token) ?? Self.version(of: token)
    }

    /// A stable 64-bit FNV-1a over UTF-8, so a version read at key down and one read at the end of
    /// dwell compare equal exactly when the text does (Swift's `hashValue` is seeded per process,
    /// which would do within a session but not in a persisted record).
    public static func version(of text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(bitPattern: UInt(hash))
    }
}

/// What the end-of-dwell read found (design §5 step 5). Anything but `.unchanged` holds the text:
/// a changed cursor is never followed automatically.
public enum TargetRevalidation: String, Equatable, Sendable {
    case unchanged
    /// Another app, process, or (with `strictElementIdentity`) element has focus.
    case focusChanged
    /// The field's text changed, and not by our own landing.
    case textChanged
    /// The caret or selection moved, and not by our own landing.
    case selectionChanged
    /// The focused element is now a password field.
    case secureField

    public var isSafe: Bool { self == .unchanged }
}

/// T4 + R2.3: snapshot the frontmost app at hotkey release, refuse to inject if focus moved, and
/// **hold** the text instead.
///
/// R2.3 reverses the old behaviour. This class used to queue the request and deliver it the moment
/// the original app came back, which meant text could appear in a field the user was no longer
/// looking at, minutes later (V3 §6). Now returning focus does nothing on its own: held text is
/// listed, named, and waits for `insertHere()` / `copy()` / `discard()`.
public final class FocusGuard {
    public struct Queued: Equatable, Sendable {
        public var request: InjectionRequest
        public var queuedAt: Date
    }

    private let system: SystemAccess
    /// Committed text waiting for the user, oldest first.
    public private(set) var held: [HeldText] = []
    /// Called whenever text becomes held (App shows the held row).
    public var onHeld: ((HeldText) -> Void)?
    /// Called after any change to `held` — hold, insert, copy, discard.
    public var onHeldChanged: (([HeldText]) -> Void)?
    /// S3 — one held item was handled by the user (Insert here / Copy / Discard). The turn gate
    /// updates the item's `TurnRecord` from it.
    public var onResolved: ((HeldText, HeldResolution) -> Void)?
    /// H23 — where a former hold goes instead of the held queue: saves the item to Notes and
    /// returns `true` when it was stored. `nil` (tests, headless) keeps the legacy held list.
    public var notesSink: ((HeldText) -> Bool)?
    /// H23 — an item went to Notes (instead of `onHeld`).
    public var onSavedToNotes: ((HeldText) -> Void)?
    /// H23 — the reasons that mean a password field: nothing is kept for them.
    public static func isSecureReason(_ reason: String) -> Bool {
        reason == DeliveryReason.secureField || reason == DeliveryLadder.Reason.passwordField.rawValue
    }
    /// Installed by `TextInjector` so `insertHere()` can run the real stack.
    public var inserter: ((HeldText) -> InjectionOutcome)?
    /// Bound on how much unhandled text we keep. Beyond it the oldest is dropped — memory is not a
    /// substitute for a decision, and an unbounded list is an unbounded leak of what was dictated.
    public var maxHeld = 20
    /// Compare element identity as well as app. Off by default: many apps re-create their focused
    /// AX element between key-release and readback, which would cause false aborts.
    public var strictElementIdentity = false

    public init(system: SystemAccess) { self.system = system }

    /// Call at hotkey release.
    public func snapshot() -> FocusSnapshot? { system.frontmostApp() }

    /// `true` when the current focus still matches the snapshot.
    public func matches(_ expected: FocusSnapshot?) -> Bool {
        guard let expected else { return true }   // caller opted out of focus safety
        guard let actual = system.frontmostApp() else { return false }
        guard actual.pid == expected.pid, actual.bundleID == expected.bundleID else { return false }
        if strictElementIdentity, let e = expected.elementToken, let a = actual.elementToken, e != a { return false }
        return true
    }

    // MARK: S3 — target revision and revalidation

    /// The destination right now: focus, the focused element's role, selection and text version.
    /// One `focusedElement()` read. Never throws: an unreadable element yields `nil` fields.
    public func targetRevision() -> TargetRevision {
        let focus = system.frontmostApp()
        // Q2 — key-down: ask Electron / Chromium for their AX tree *before* the caret read.
        if let focus, !OwnProcess.owns(focus) { (system as? AppAccessibilityEnabling)?.enableAppAccessibility(pid: focus.pid) }
        guard let info = try? system.focusedElement() else { return TargetRevision(focus: focus) }
        // A password field's value is never read into a version, not even as a hash.
        return TargetRevision(focus: focus, role: info.role, selection: info.selectedRange,
                              textVersion: info.isSecure ? nil : info.value.map(TargetRevision.version(of:)),
                              isSecure: info.isSecure,
                              isTextSettable: info.isValueSettable || info.isSelectedTextSettable)
    }

    /// Design §5 step 5: at the end of dwell, is the destination still the one the turn snapshot?
    ///
    /// Identity uses `matches(_:)` (app and process; element too under `strictElementIdentity`).
    /// Then the text version and the selection must be unchanged — unless `ownLandingSinceSnapshot`
    /// says the only thing that touched the field since the snapshot is our own previous landing
    /// with the caret still after it (the turn controller asks `LandingMemory`; in a latch the
    /// previous segment's insertion is exactly that). A side that could not be read on either
    /// read is not compared: an app that exposes no value cannot be held against it.
    public func revalidate(_ expected: TargetRevision, ownLandingSinceSnapshot: Bool = false) -> TargetRevalidation {
        guard matches(expected.focus) else { return .focusChanged }
        let now = targetRevision()
        if now.isSecure { return .secureField }
        if ownLandingSinceSnapshot { return .unchanged }
        if let before = expected.textVersion, let after = now.textVersion, before != after { return .textChanged }
        if let before = expected.selection, let after = now.selection, before != after { return .selectionChanged }
        return .unchanged
    }

    public var hasHeldText: Bool { !held.isEmpty }

    public func heldText(id: HeldText.ID) -> HeldText? { held.first { $0.id == id } }

    /// S3 — the held item carrying `turn`'s payload, if it is still held.
    public func heldText(turn: TurnID) -> HeldText? { held.last { $0.turnID == turn } }

    /// Revise retained words without delivering them. Insert here still runs the normal focus guard.
    @discardableResult
    public func reviseHeld(_ id: HeldText.ID, expected: String, text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = held.firstIndex(where: { $0.id == id && $0.text == expected }) else { return false }
        held[index].request.text = text
        onHeldChanged?(held)
        return true
    }

    // MARK: Holding

    /// Keeps committed text that could not be delivered. Never posts anything.
    @discardableResult
    public func hold(_ request: InjectionRequest, reason: String, segmentID: SegmentID? = nil,
                     destination: FocusSnapshot? = nil, turnID: TurnID? = nil) -> HeldText {
        let item = HeldText(request: request, segmentID: segmentID,
                            destination: destination ?? request.expectedFocus, reason: reason, turnID: turnID)
        // H23 — a password field keeps nothing: not held, not in Notes, not in memory.
        if Self.isSecureReason(reason) {
            Log.injection.notice("secure field: \(item.text.count) chars dropped, nothing kept")
            return item
        }
        // H23 — the held queue is retired: with a Notes sink installed every former hold is saved
        // there (the intended app and the reason travel with it). A failed save keeps the item here,
        // so the words stay in history with Copy.
        if let notesSink {
            if notesSink(item) {
                Log.injection.notice("saved \(item.text.count) chars to Notes for \(item.destinationName): \(reason)")
                onSavedToNotes?(item)
                return item
            }
            Log.injection.error("Notes save failed for \(item.text.count) chars; kept with Copy")
        }
        held.append(item)
        if held.count > maxHeld {
            let dropped = held.removeFirst()
            Log.injection.notice("held list full; dropped \(dropped.text.count) chars held for \(dropped.destinationName)")
            onResolved?(dropped, .discarded)
        }
        Log.injection.notice("held \(item.text.count) chars for \(item.destinationName): \(reason)")
        onHeld?(item)
        onHeldChanged?(held)
        return item
    }

    // MARK: The three actions

    /// Insert held text into whatever has focus **now**. The only path that turns held into
    /// delivered, and it only ever runs because the user asked.
    ///
    /// Returns `nil` if the id is unknown or no inserter is installed. On any outcome other than a
    /// fresh hold, the item leaves the list: a posted method may have landed, so re-offering it
    /// would be exactly the double-fire R2.3 exists to stop.
    @discardableResult
    public func insertHere(_ id: HeldText.ID) -> InjectionOutcome? {
        guard let index = held.firstIndex(where: { $0.id == id }), let inserter else { return nil }
        let item = held.remove(at: index)
        onHeldChanged?(held)
        // Insert *here*: the destination is wherever the user is now, so drop the old focus check.
        var request = item.request
        request.expectedFocus = nil
        let heldBefore = held.count
        let outcome = inserter(HeldText(id: item.id, request: request, segmentID: item.segmentID,
                                        destination: system.frontmostApp(), reason: item.reason, heldAt: item.heldAt,
                                        turnID: item.turnID))
        // Held again (focus moved during the insert): the new item carries the same turn.
        if let turn = item.turnID, held.count > heldBefore, held[held.count - 1].turnID == nil {
            held[held.count - 1].turnID = turn
        }
        Log.injection.info("insert-here for held text: \(String(describing: outcome.delivery))")
        onResolved?(item, .inserted(outcome))
        return outcome
    }

    /// Put held text on the pasteboard, for the user to paste themselves. Removes it from the list;
    /// the clipboard is now the copy of record.
    @discardableResult
    public func copy(_ id: HeldText.ID) -> Bool {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return false }
        let item = held.remove(at: index)
        system.writePasteboard(string: item.text)
        Log.injection.info("copied \(item.text.count) held chars to the pasteboard")
        onHeldChanged?(held)
        onResolved?(item, .copied)
        return true
    }

    @discardableResult
    public func discard(_ id: HeldText.ID) -> Bool {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return false }
        let item = held.remove(at: index)
        Log.injection.info("discarded \(item.text.count) held chars")
        onHeldChanged?(held)
        onResolved?(item, .discarded)
        return true
    }

    // MARK: Conveniences on the oldest held item (what the pill's single row acts on)

    @discardableResult public func insertHere() -> InjectionOutcome? { held.first.flatMap { insertHere($0.id) } }
    @discardableResult public func copy() -> Bool { held.first.map { copy($0.id) } ?? false }
    @discardableResult public func discard() -> Bool { held.first.map { discard($0.id) } ?? false }

    public func discardAll() {
        guard !held.isEmpty else { return }
        Log.injection.info("discarded \(held.count) held items")
        let dropped = held
        held.removeAll()
        onHeldChanged?(held)
        dropped.forEach { onResolved?($0, .discarded) }
    }

    // MARK: Compatibility

    /// The pre-R2.3 name for `held`, kept so existing call sites still read. Read-only: nothing
    /// dequeues, and nothing is delivered by coming back.
    @available(*, deprecated, renamed: "held")
    public var queue: [Queued] { held.map { Queued(request: $0.request, queuedAt: $0.heldAt) } }

    @available(*, deprecated, renamed: "hold(_:reason:segmentID:destination:)")
    public func enqueue(_ request: InjectionRequest) {
        hold(request, reason: DeliveryReason.destinationChanged)
    }
}
