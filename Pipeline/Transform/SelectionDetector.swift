import Foundation
import Shared
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

public extension StageID {
    /// P2.1/P2.2 — the transform (rewrite-in-place) stage.
    static let transform: StageID = "transform"
    /// P2.4 — question-about-selection stage (answer typed below, never replaces).
    static let question: StageID = "question"
}

/// What the user had selected when the hotkey went down (P2.1). Ranges are UTF-16 units in the
/// focused element's value (AX convention) so they map 1:1 onto a replace-range request.
public struct SelectionSnapshot: Equatable, Sendable, Codable {
    public var text: String
    public var range: Range<Int>
    /// H15 — the surrounding text for the model (`EditContextBuilder.surrounding`): the previous
    /// paragraph and the current one around the selection, sentence-aligned, ≤ ~1,200 tokens.
    /// Memory only; empty for a secure field or an unreadable value.
    public var before: String
    public var after: String
    public var bundleID: String?
    public var elementToken: String?
    /// H15 — app name, window title, field label and surface kind (nil: unknown or secure).
    public var destination: EditDestination?

    public init(text: String, range: Range<Int>, before: String = "", after: String = "",
                bundleID: String? = nil, elementToken: String? = nil, destination: EditDestination? = nil) {
        self.text = text; self.range = range; self.before = before; self.after = after
        self.bundleID = bundleID; self.elementToken = elementToken; self.destination = destination
    }

    /// Bet 5: a whitespace-only or empty selection is no selection.
    public var isMeaningful: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    /// H9 — the same selected text at the same place in the same field. The surrounding context is
    /// ignored: it is a model hint, not identity (a chained edit's snapshot keeps the first turn's).
    public func isSameTarget(as other: SelectionSnapshot?) -> Bool {
        guard let other else { return false }
        return text == other.text && range == other.range && bundleID == other.bundleID && elementToken == other.elementToken
    }

    /// Build a snapshot from a full field value + selected UTF-16 range.
    /// H15 — the surrounding text comes from `EditContextBuilder` (paragraph-aware, budgeted).
    public static func from(value: String, selectedRange: Range<Int>, bundleID: String? = nil, elementToken: String? = nil,
                            destination: EditDestination? = nil) -> SelectionSnapshot? {
        let units = Array(value.utf16)
        guard selectedRange.lowerBound >= 0, selectedRange.upperBound <= units.count, !selectedRange.isEmpty else { return nil }
        let ctx = EditContextBuilder.surrounding(value: value, selectedRange: selectedRange)
        return SelectionSnapshot(text: String(decoding: units[selectedRange], as: UTF16.self), range: selectedRange,
                                 before: ctx.before, after: ctx.after,
                                 bundleID: bundleID, elementToken: elementToken, destination: destination)
    }
}

/// Reads the current selection. Live implementation is AX-backed; tests use the mock.
public protocol SelectionDetecting: Sendable {
    /// `nil` when nothing is selected, the element is unreadable, or AX is not trusted.
    func currentSelection() -> SelectionSnapshot?
}

public final class MockSelectionDetector: SelectionDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _selection: SelectionSnapshot?
    public var selection: SelectionSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _selection }
        set { lock.lock(); _selection = newValue; lock.unlock() }
    }
    public init(_ selection: SelectionSnapshot? = nil) { _selection = selection }
    public func currentSelection() -> SelectionSnapshot? { selection }
}

#if canImport(AppKit)
/// Live detector over the system-wide focused AX element. Never prompts; returns `nil`
/// whenever Accessibility is not trusted or the element does not expose a selection.
public struct AXSelectionDetector: SelectionDetecting {
    public init() {}

    public func currentSelection() -> SelectionSnapshot? {
        // K18 — own pid off-main → refuse; the guard owns the system-wide root.
        guard let element = AXGuard.focusedElement() else { return nil }
        // H8 — a password field is never read: role/subrole first, before range or value.
        guard !Self.isSecure(element) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange), cfRange.length > 0 else { return nil }
        let range = cfRange.location..<(cfRange.location + cfRange.length)
        var valueRef: CFTypeRef?
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let token = String(CFHash(element))
        let dest = Self.destination(of: element, pid: pid)
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success, let value = valueRef as? String {
            return SelectionSnapshot.from(value: value, selectedRange: range, bundleID: bundle, elementToken: token, destination: dest)
        }
        // Value unreadable (web views, canvases): fall back to the selected text alone.
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let sel = selRef as? String, !sel.isEmpty else { return nil }
        return SelectionSnapshot(text: sel, range: range, bundleID: bundle, elementToken: token, destination: dest)
    }

    /// H15 — app name, focused window title and the field's label (title, description or
    /// placeholder). The surface kind is added upstream from the turn's resolution.
    static func destination(of element: AXUIElement, pid: pid_t) -> EditDestination? {
        func string(_ el: AXUIElement, _ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return (ref as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var windowRef: CFTypeRef?
        var window: String?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success, let w = windowRef,
           CFGetTypeID(w) == AXUIElementGetTypeID() {
            window = string(w as! AXUIElement, kAXTitleAttribute)
        }
        let label = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
            ?? string(element, kAXPlaceholderValueAttribute)
        let d = EditDestination(appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
                                windowTitle: window, fieldLabel: label)
        return d.isEmpty ? nil : d
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        for attr in [kAXRoleAttribute, kAXSubroleAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               (ref as? String) == "AXSecureTextField" { return true }
        }
        return false
    }
}
#endif
