import Foundation
import Shared

/// T5 / Bet 4 safety rule: replace a range we previously wrote, via AX, only if the region still reads
/// *exactly* as what we wrote. Otherwise do not touch the document — surface a suggestion instead.
public struct ReplaceRangeRequest: Equatable, Sendable {
    /// UTF-16 range in the focused element's value.
    public var range: Range<Int>
    /// What we believe is there (what we injected earlier).
    public var expected: String
    public var replacement: String
    /// H9 — select the replacement afterwards (a selection edit: the result stays selected so a
    /// follow-up command edits it). false: put the user's caret back where it was (repair).
    public var selectResult: Bool
    public init(range: Range<Int>, expected: String, replacement: String, selectResult: Bool = false) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
        self.selectResult = selectResult
    }

    /// Where the replacement sits once written.
    public var resultingRange: Range<Int> { range.lowerBound..<(range.lowerBound + replacement.utf16.count) }
}

public enum ReplaceRangeOutcome: Equatable, Sendable {
    case replaced(verified: Bool)
    /// Region no longer matches (user edited, moved on, or another process changed it). Untouched.
    case mismatch(actual: String?)
    /// AX could not read or write the element; untouched.
    case unavailable(reason: String)
}

public final class ReplaceRangeEditor {
    private let system: SystemAccess
    public init(system: SystemAccess) { self.system = system }

    static func utf16Slice(_ value: String, _ range: Range<Int>) -> String? {
        let units = Array(value.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
        return String(decoding: units[range], as: UTF16.self)
    }

    public func replace(_ request: ReplaceRangeRequest) -> ReplaceRangeOutcome {
        let info: FocusedElementInfo
        do { info = try system.focusedElement() } catch { return .unavailable(reason: "\(error)") }
        guard let value = info.value else { return .unavailable(reason: "AX value unreadable") }
        guard let actual = Self.utf16Slice(value, request.range) else { return .mismatch(actual: nil) }
        guard actual == request.expected else { return .mismatch(actual: actual) }
        guard info.isSelectedTextSettable || info.isValueSettable else { return .unavailable(reason: "AX not settable") }

        let originalSelection = info.selectedRange
        do {
            if info.isSelectedTextSettable {
                try system.setFocusedSelectedRange(request.range)
                try system.setFocusedSelectedText(request.replacement)
            } else {
                var units = Array(value.utf16)
                units.replaceSubrange(request.range, with: Array(request.replacement.utf16))
                try system.setFocusedValue(String(decoding: units, as: UTF16.self))
            }
        } catch {
            return .unavailable(reason: "\(error)")
        }
        if request.selectResult {
            // H9 — the new text stays selected (not the old range, which now spans different text).
            try? system.setFocusedSelectedRange(request.resultingRange)
        } else if let sel = originalSelection {
            // Put the caret back where the user had it (shifted if it sat after the edit).
            let delta = request.replacement.utf16.count - request.range.count
            let shifted = sel.lowerBound >= request.range.upperBound
                ? (sel.lowerBound + delta)..<(sel.upperBound + delta) : sel
            try? system.setFocusedSelectedRange(shifted)
        }
        let after = (try? system.focusedElement())?.value
        let verified = after.flatMap { Self.utf16Slice($0, request.range.lowerBound..<(request.range.lowerBound + request.replacement.utf16.count)) } == request.replacement
        return .replaced(verified: verified)
    }
}
