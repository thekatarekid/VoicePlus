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

    public init(id: UUID = UUID(), request: InjectionRequest, segmentID: SegmentID? = nil,
                destination: FocusSnapshot?, reason: String, heldAt: Date = Date()) {
        self.id = id
        self.request = request
        self.segmentID = segmentID
        self.destination = destination
        self.reason = reason
        self.heldAt = heldAt
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

    public var hasHeldText: Bool { !held.isEmpty }

    public func heldText(id: HeldText.ID) -> HeldText? { held.first { $0.id == id } }

    // MARK: Holding

    /// Keeps committed text that could not be delivered. Never posts anything.
    @discardableResult
    public func hold(_ request: InjectionRequest, reason: String, segmentID: SegmentID? = nil,
                     destination: FocusSnapshot? = nil) -> HeldText {
        let item = HeldText(request: request, segmentID: segmentID,
                            destination: destination ?? request.expectedFocus, reason: reason)
        held.append(item)
        if held.count > maxHeld {
            let dropped = held.removeFirst()
            Log.injection.notice("held list full; dropped \(dropped.text.count) chars held for \(dropped.destinationName)")
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
        let outcome = inserter(HeldText(id: item.id, request: request, segmentID: item.segmentID,
                                        destination: system.frontmostApp(), reason: item.reason, heldAt: item.heldAt))
        Log.injection.info("insert-here for held text: \(String(describing: outcome.delivery))")
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
        return true
    }

    @discardableResult
    public func discard(_ id: HeldText.ID) -> Bool {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return false }
        let item = held.remove(at: index)
        Log.injection.info("discarded \(item.text.count) held chars")
        onHeldChanged?(held)
        return true
    }

    // MARK: Conveniences on the oldest held item (what the pill's single row acts on)

    @discardableResult public func insertHere() -> InjectionOutcome? { held.first.flatMap { insertHere($0.id) } }
    @discardableResult public func copy() -> Bool { held.first.map { copy($0.id) } ?? false }
    @discardableResult public func discard() -> Bool { held.first.map { discard($0.id) } ?? false }

    public func discardAll() {
        guard !held.isEmpty else { return }
        Log.injection.info("discarded \(held.count) held items")
        held.removeAll()
        onHeldChanged?(held)
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
