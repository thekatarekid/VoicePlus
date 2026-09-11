import Foundation
import Injection
import Pipeline
import Shared

/// R4.2 wiring — the focused AX element → `FieldContext`, the value `Pipeline` classifies.
///
/// This is the piece that makes the headline case real rather than test-only: `FieldRole.classify`
/// decides a VS Code integrated terminal from its editor pane by the element's descriptive strings
/// (`FocusedElementInfo.hints`), and nothing was carrying them out of `Injection` before. With them
/// in hand, "terminal inside an editor" is decided by the accessibility tree instead of the bundle
/// ID, which is the whole point of the item.
///
/// One `focusedElement()` call per utterance — the same one the injector's caret read already makes.
/// Nothing here traverses the tree a second time.
public final class FieldContextReader: @unchecked Sendable {
    private let system: SystemAccess

    /// How much text either side of the caret is carried, in UTF-16 units. The continuation
    /// planner only ever looks at the tail before the caret and the first character after it, and
    /// a code editor's value can be a megabyte — so this is a window, not the field.
    public var window: Int

    public init(system: SystemAccess, window: Int = 400) {
        self.system = system
        self.window = window
    }

    /// `nil` only when there is no readable focused element at all (no accessibility permission,
    /// nothing focused). A field that answers with a role but no hints is not nil: it is a
    /// `FieldContext` with `hints == []`, which classifies by role + app exactly as before.
    public func fieldContext(bundleID: String?) -> FieldContext? {
        guard let info = try? system.focusedElement() else { return nil }
        return Self.fieldContext(from: info, bundleID: bundleID, window: window)
    }

    public static func fieldContext(from info: FocusedElementInfo, bundleID: String?,
                                    window: Int = 400) -> FieldContext {
        let (before, after) = textAroundCaret(value: info.value, range: info.selectedRange, window: window)
        return FieldContext(appBundleID: bundleID,
                            axRole: info.role,
                            axSubrole: info.subrole,
                            hints: info.hints,
                            textBeforeCursor: before,
                            textAfterCursor: after)
    }

    /// Splits the field value at the caret, bounded to `window` UTF-16 units either side.
    ///
    /// AX reports offsets in UTF-16 units, so the split is done there and the window edges are
    /// nudged off a surrogate pair rather than slicing one in half (an emoji before the caret must
    /// not become U+FFFD, which would make the continuation planner read the wrong last character).
    /// With no caret the caret is taken to be the end of the value: appending is the safe reading.
    static func textAroundCaret(value: String?, range: Range<Int>?, window: Int) -> (String, String) {
        guard let value, !value.isEmpty else { return ("", "") }
        let units = Array(value.utf16)
        let count = units.count
        let caret = min(max(range?.lowerBound ?? count, 0), count)
        let selectionEnd = min(max(range?.upperBound ?? caret, caret), count)
        let before = slice(units, from: max(0, caret - window), to: caret)
        let after = slice(units, from: selectionEnd, to: min(count, selectionEnd + window))
        return (before, after)
    }

    private static func slice(_ units: [UInt16], from start: Int, to end: Int) -> String {
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
