import Foundation
import Shared

/// Identity of the app/element that had focus when the user released the hotkey.
/// Used by `FocusGuard` to refuse to inject if focus moved (never spray text).
public struct FocusSnapshot: Equatable, Sendable, Codable {
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    /// Opaque identity of the focused AX element (pointer hash, or a mock token). `nil` if unknown.
    public var elementToken: String?

    public init(pid: Int32, bundleID: String, appName: String = "", elementToken: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.elementToken = elementToken
    }
}

/// What we can learn about the focused AX element in one round-trip.
public struct FocusedElementInfo: Equatable, Sendable {
    public var role: String
    /// `kAXSubroleAttribute`. `nil` when the element does not expose one. A password field in a
    /// web view often reports `AXTextField` with the `AXSecureTextField` *subrole*.
    public var subrole: String?
    /// `nil` when the element does not expose `kAXValueAttribute` as a string.
    public var value: String?
    /// Location/length in UTF-16 units (AX convention). `nil` when unavailable.
    public var selectedRange: Range<Int>?
    /// `kAXSelectedTextAttribute` as read back. Empty string for a bare caret, `nil` when the
    /// element does not expose it. Chromium readback uses this and the caret (R2.3).
    public var selectedText: String?
    /// Whether `kAXValueAttribute` / `kAXSelectedTextAttribute` are settable.
    public var isValueSettable: Bool
    public var isSelectedTextSettable: Bool
    /// R4.2 — every descriptive string the element exposes, in this order: `AXIdentifier`,
    /// `AXDescription`, `AXTitle`, `AXRoleDescription` (the last also carries a web view's ARIA
    /// label). Empty and duplicate values are dropped, so an element that exposes none yields `[]`.
    ///
    /// This is what tells a VS Code integrated terminal ("Terminal input") from its editor
    /// ("Monaco editor"): both are `AXTextArea` in the same bundle ID, so role and app class
    /// cannot separate them. `Pipeline`'s `FieldRole.classify` reads these as `FieldContext.hints`.
    public var hints: [String]
    /// Q1 — the URL of the web document the element sits in (`AXURL` of its `AXWebArea`), when
    /// the injector asked for it (`FocusedDocumentURLReading`). `nil` for native fields and by
    /// default: it costs a parent walk, so only a multi-line write into a browser reads it.
    public var documentURL: String?

    public init(role: String, value: String?, selectedRange: Range<Int>?, isValueSettable: Bool,
                isSelectedTextSettable: Bool, subrole: String? = nil, selectedText: String? = nil,
                hints: [String] = [], documentURL: String? = nil) {
        self.documentURL = documentURL
        self.role = role
        self.subrole = subrole
        self.value = value
        self.selectedRange = selectedRange
        self.selectedText = selectedText
        self.isValueSettable = isValueSettable
        self.isSelectedTextSettable = isSelectedTextSettable
        self.hints = hints
    }

    public var isReadable: Bool { value != nil }

    /// AX role/subrole for a password field. Dictation must never be posted into one (R2.3).
    public static let secureRole = "AXSecureTextField"

    /// The AX attributes `hints` is read from, in the order they are reported. These are exactly
    /// `kAXIdentifierAttribute`, `kAXDescriptionAttribute`, `kAXTitleAttribute` and
    /// `kAXRoleDescriptionAttribute`; spelled as literals so this file stays Foundation-only.
    public static let hintAttributes = ["AXIdentifier", "AXDescription", "AXTitle", "AXRoleDescription"]

    /// Raw attribute reads → `hints`: trimmed, blanks and nils dropped, duplicates dropped
    /// (an element whose title and role description are both "Terminal" contributes one hint).
    /// An element that exposes none of them degrades to `[]` — never an error, never a `nil` hole.
    public static func hints(from raw: [String?]) -> [String] {
        var out: [String] = []
        for value in raw {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, !out.contains(trimmed) else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// True when this element is a password field by role *or* subrole.
    public var isSecure: Bool { role == Self.secureRole || subrole == Self.secureRole }
}

/// One pasteboard item: every type it carries, as raw bytes (so images round-trip losslessly).
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public var types: [String: Data]
    public init(types: [String: Data]) { self.types = types }
}

public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [PasteboardItemSnapshot]
    public var changeCount: Int
    public init(items: [PasteboardItemSnapshot], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }
}

/// Key combos we synthesise (paste, cell-edit helpers). Key codes are macOS virtual key codes.
public struct KeyCombo: Equatable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var shift: Bool
    public var control: Bool

    public init(keyCode: UInt16, command: Bool = false, option: Bool = false, shift: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.shift = shift
        self.control = control
    }

    public static let paste = KeyCombo(keyCode: 9, command: true)          // ⌘V
    public static let returnKey = KeyCombo(keyCode: 36)
    public static let optionReturn = KeyCombo(keyCode: 36, option: true)   // newline inside a spreadsheet cell
    /// Q1 — a soft line break in chat composers (Claude, Slack, Cursor): never sends the message.
    public static let shiftReturn = KeyCombo(keyCode: 36, shift: true)
}

public enum SystemAccessError: Error, Equatable, Sendable {
    case accessibilityNotTrusted
    case noFocusedElement
    case attributeNotSettable(String)
    case axError(Int32)
    case eventPostFailed
    /// FX1 — the focused element belongs to this process and the call is not on the main thread.
    /// Thrown before anything is posted; `LiveSystemAccess` retries the call on the main thread.
    case ownProcessOffMain
    /// FX1 — the main thread did not pick up a `MainThreadHop` in time. Nothing ran, nothing will.
    case mainThreadBusy
}

/// Every OS touch-point the injection stack uses. Real implementation: `LiveSystemAccess`
/// (AX + CGEvent + NSPasteboard). Tests and the App's mock engine use `MockSystemAccess`.
public protocol SystemAccess: AnyObject {
    var isAccessibilityTrusted: Bool { get }

    /// How many side effects have been posted into another app so far: AX text writes,
    /// synthesised keystrokes and key combos. Monotonic, never reset.
    ///
    /// This is what makes the readback rule airtight (R2.3, V3 §14.4): the injector compares the
    /// count either side of a method, so a method that posted *and then* threw is still treated as
    /// "possibly landed" and no second method runs. Do not count pasteboard writes or caret moves —
    /// neither can put text in the user's field.
    var postCount: Int { get }

    // Focus
    func frontmostApp() -> FocusSnapshot?
    func focusedElement() throws -> FocusedElementInfo

    // AX writes
    func setFocusedValue(_ value: String) throws
    func setFocusedSelectedRange(_ range: Range<Int>) throws
    /// Replaces the current selection (or inserts at the caret) via `kAXSelectedTextAttribute`.
    func setFocusedSelectedText(_ text: String) throws

    // CGEvent
    func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws
    func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws

    // Pasteboard
    func readPasteboard() -> PasteboardSnapshot
    /// Writes a plain string and returns the resulting changeCount.
    @discardableResult func writePasteboard(string: String) -> Int
    func restorePasteboard(_ snapshot: PasteboardSnapshot)
    var pasteboardChangeCount: Int { get }

    /// Sleeps for settle time (mock returns immediately).
    func settle(milliseconds: Int)
}

// MARK: - Q1 — the web document a field lives in

/// Q1 — the URL of the web page holding the focused element (`AXURL` on the nearest `AXWebArea`
/// ancestor). A separate protocol so existing conformers compile unchanged; asked for only when a
/// multi-line write goes into a browser (Google Sheets needs ⌥↩, not ⇧↩).
public protocol FocusedDocumentURLReading: AnyObject {
    func focusedDocumentURL() -> String?
}

// MARK: - D1 (V4.2, V4.3) — reading the caret honestly

/// The text either side of the caret, as read through WebKit/Chromium text markers
/// (`AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`). The selection itself — the text
/// an insertion replaces — is in neither string.
public struct TextMarkerCaret: Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// `endOfField` when nothing follows the selection, `known` otherwise; each side bounded to
    /// `window` UTF-16 units (surrogate pairs are never split).
    public func caretState(window: Int = CaretWindow.defaultWindow) -> CaretState {
        let before = CaretWindow.tail(of: before, window: window)
        guard !after.isEmpty else { return .endOfField(before: before) }
        return .known(before: before, after: CaretWindow.head(of: after, window: window))
    }
}

/// D1 — the second caret rung: WebKit and Chromium expose the caret as opaque text markers even
/// where `kAXSelectedTextRange` is missing or stale. `LiveSystemAccess` reads them with the
/// parameterized attributes; a test double conforms to model an app that does (or does not).
///
/// A separate protocol rather than a `SystemAccess` requirement, so every existing conformer
/// (and every subclass of `MockSystemAccess`) keeps compiling unchanged: a reader asks
/// `system as? TextMarkerCaretReading`.
public protocol TextMarkerCaretReading: AnyObject {
    /// `nil` when the focused element exposes no marker range, or any read fails.
    func caretByTextMarkers() -> TextMarkerCaret?
}

/// UTF-16 windows around a caret. AX reports offsets in UTF-16 units, so splits happen there,
/// and a window edge is nudged off a surrogate pair rather than slicing one in half (an emoji
/// before the caret must not become U+FFFD).
public enum CaretWindow {
    /// How much text either side of the caret is carried. The continuation planner only ever
    /// looks at the tail before the caret and the first character after it, and a code editor's
    /// value can be a megabyte — so this is a window, not the field.
    public static let defaultWindow = 400

    /// Splits `value` at `range` (the selection is dropped): `nil` when the range does not fit
    /// the value — a stale value from an app that updates it lazily. Never clamped to the end:
    /// that is the V3 bug this rung exists to remove.
    public static func split(value: String, range: Range<Int>, window: Int = defaultWindow) -> (before: String, after: String)? {
        let units = Array(value.utf16)
        let count = units.count
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        let before = slice(units, from: max(0, range.lowerBound - window), to: range.lowerBound)
        let after = slice(units, from: range.upperBound, to: min(count, range.upperBound + window))
        return (before, after)
    }

    /// The last `window` UTF-16 units of `text`.
    public static func tail(of text: String, window: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > window else { return text }
        return slice(units, from: units.count - window, to: units.count)
    }

    /// The first `window` UTF-16 units of `text`.
    public static func head(of text: String, window: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > window else { return text }
        return slice(units, from: 0, to: window)
    }

    static func slice(_ units: [UInt16], from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        var lower = start, upper = end
        // A low (trailing) surrogate at the lower edge has lost its partner: start after it.
        if lower > 0, UTF16.isTrailSurrogate(units[lower]) { lower += 1 }
        // A high (leading) surrogate at the upper edge has lost its partner: stop before it.
        if upper > lower, upper < units.count, UTF16.isLeadSurrogate(units[upper - 1]) { upper -= 1 }
        guard lower < upper else { return "" }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }
}

public extension FocusedElementInfo {
    /// D1 — the first caret rung: `kAXSelectedTextRange` over `kAXValue`.
    ///
    /// `nil` (the rung did not answer) when either is missing, or when the range does not fit the
    /// value. `endOfField` only when a range was read **and** its end is the value's length;
    /// a value without a range is never "the end of the field".
    func caretFromSelectedRange(window: Int = CaretWindow.defaultWindow) -> CaretState? {
        guard let value, let range = selectedRange,
              let (before, after) = CaretWindow.split(value: value, range: range, window: window) else { return nil }
        return range.upperBound == value.utf16.count ? .endOfField(before: before) : .known(before: before, after: after)
    }
}

// MARK: - FX1 — never drive our own UI through Accessibility from a background thread

/// FX1 — what "our own process" is, decided without an AX round trip.
///
/// AX calls whose target is this process do not go through the main run loop: macOS runs AppKit's
/// accessibility handler **in-process, on the calling thread**. From a background thread that edits
/// an `NSTextView` off the main thread while the main thread lays the same view out — TextKit 2
/// takes its two locks in opposite orders and both threads stop for good. That was the onboarding
/// "Try your first sentence" freeze (1.11.0 / 1.11.1): the practice field is VoicePlus's own
/// `TextEditor`, and the turn's write ran `AXUIElementSetAttributeValue(kAXSelectedText)` from the
/// Swift concurrency pool.
public enum OwnProcess {
    public static let pid: Int32 = ProcessInfo.processInfo.processIdentifier

    /// True when `focus` is VoicePlus itself: our pid, or our bundle ID (a snapshot taken by a
    /// different instance of the app still names our windows).
    public static func owns(_ focus: FocusSnapshot?, pid: Int32 = OwnProcess.pid,
                            bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let focus else { return false }
        if focus.pid == pid { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return focus.bundleID == bundleID
    }
}

/// FX1 — the text path into VoicePlus's **own** focused text view, which never goes through AX.
///
/// `LiveSystemAccess` conforms: it drives the key window's first responder (`NSTextView`, or a text
/// field's field editor) directly. A separate protocol, like `TextMarkerCaretReading`, so every
/// existing `SystemAccess` conformer keeps compiling: callers ask `system as? InProcessTextDelivering`.
///
/// **Main thread only.** Both methods refuse off the main thread (`ownFocusedText()` returns `nil`,
/// `insertIntoOwnFocusedText` throws `.ownProcessOffMain` before touching anything).
public protocol InProcessTextDelivering: AnyObject {
    /// Our first responder's text as a `FocusedElementInfo` (value, selection, role); `nil` when
    /// the first responder is not text, or off the main thread.
    func ownFocusedText() -> FocusedElementInfo?
    /// Inserts `text` at our first responder's selection, exactly as typing would (undo, delegate,
    /// SwiftUI bindings). `false` when the first responder is not editable text. Counts as a post.
    func insertIntoOwnFocusedText(_ text: String) throws -> Bool
}

/// FX1 — runs work on the main thread from any thread, and never waits on it forever.
///
/// The caller waits at most `startTimeout` for the main thread to *start* the work. If it has not
/// started by then the work is cancelled — it will never run — and `.mainThreadBusy` is thrown, so
/// a write that timed out can never land late (the readback rule's "nothing posted" still holds).
/// Once the work has started, the caller waits for it to finish: it is running on the main thread
/// right now, and a started write must report what it did.
///
/// On the main thread the work runs inline.
public enum MainThreadHop {
    /// How long a read waits for the main thread to pick it up.
    public static let readStartTimeout: TimeInterval = 1.0
    /// How long a write waits. Longer: giving up on a write holds the user's text.
    public static let writeStartTimeout: TimeInterval = 3.0

    public static func run<T>(startTimeout: TimeInterval = readStartTimeout,
                              _ work: @escaping () throws -> T) throws -> T {
        if Thread.isMainThread { return try work() }
        let hop = Hop<T>()
        DispatchQueue.main.async {
            guard hop.begin() else { return }
            hop.finish(Result { try work() })
        }
        if hop.started.wait(timeout: .now() + max(0, startTimeout)) == .timedOut, hop.cancel() {
            throw SystemAccessError.mainThreadBusy
        }
        hop.done.wait()
        return try hop.outcome()
    }

    private final class Hop<T>: @unchecked Sendable {
        private enum State { case pending, running, cancelled }
        private let lock = NSLock()
        private var state = State.pending
        private var result: Result<T, Error>?
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        /// Main thread: claim the work. `false` when the caller already gave up.
        func begin() -> Bool {
            let claimed = lock.withLock { () -> Bool in
                guard state == .pending else { return false }
                state = .running
                return true
            }
            if claimed { started.signal() }
            return claimed
        }

        /// Caller: give up. `false` when the main thread has already begun (then wait for it).
        func cancel() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .cancelled
                return true
            }
        }

        func finish(_ value: Result<T, Error>) {
            lock.withLock { result = value }
            done.signal()
        }

        func outcome() throws -> T {
            guard let result = lock.withLock({ result }) else { throw SystemAccessError.mainThreadBusy }
            return try result.get()
        }
    }
}
