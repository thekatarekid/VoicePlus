import Foundation
import Testing
@testable import Injection
import Shared

/// D1 (V4.2, V4.3) — the caret rungs `Injection` provides: `kAXSelectedTextRange` over `kAXValue`,
/// and text markers. A value without a range is never "the end of the field".
@Suite struct CaretReadingTests {
    static func info(value: String?, range: Range<Int>?, role: String = "AXTextArea",
                     subrole: String? = nil) -> FocusedElementInfo {
        FocusedElementInfo(role: role, value: value, selectedRange: range, isValueSettable: true,
                           isSelectedTextSettable: true, subrole: subrole)
    }

    @Test("a value without a range does not answer (unknown, not end of field)")
    func valueWithoutRange() {
        #expect(Self.info(value: "Hello there", range: nil).caretFromSelectedRange() == nil)
        #expect(Self.info(value: nil, range: 3..<3).caretFromSelectedRange() == nil)
        #expect(Self.info(value: nil, range: nil).caretFromSelectedRange() == nil)
    }

    @Test("a range at the value's length is endOfField; anywhere else is known")
    func rangeAnswers() {
        let value = "The quick brown jumps over"
        let caret = "The quick brown".utf16.count
        #expect(Self.info(value: value, range: caret..<caret).caretFromSelectedRange()
                == .known(before: "The quick brown", after: " jumps over"))
        let end = value.utf16.count
        #expect(Self.info(value: value, range: end..<end).caretFromSelectedRange() == .endOfField(before: value))
        #expect(Self.info(value: "", range: 0..<0).caretFromSelectedRange() == .endOfField(before: ""))
        // A selection reaching the end replaces the tail: the insertion ends the field.
        #expect(Self.info(value: "abc def", range: 4..<7).caretFromSelectedRange() == .endOfField(before: "abc "))
        // A selection in the middle drops the selected text from both sides.
        #expect(Self.info(value: "abc def ghi", range: 4..<7).caretFromSelectedRange()
                == .known(before: "abc ", after: " ghi"))
    }

    @Test("a range that does not fit the value (a stale value) is not clamped to the end")
    func staleValue() {
        #expect(Self.info(value: "", range: 12..<12).caretFromSelectedRange() == nil)
        #expect(Self.info(value: "abc", range: 2..<9).caretFromSelectedRange() == nil)
        #expect(Self.info(value: "abc", range: -1..<0).caretFromSelectedRange() == nil)
    }

    @Test("windows are bounded in UTF-16 units and never split a surrogate pair")
    func windows() {
        let long = String(repeating: "x", count: 5_000)
        let caret = Self.info(value: long, range: 2_500..<2_500).caretFromSelectedRange(window: 400)
        #expect(caret?.textBefore?.count == 400)
        #expect(caret?.textAfter?.count == 400)
        let emoji = "ab\u{1F600}cd"
        let end = emoji.utf16.count
        let tail = Self.info(value: emoji, range: end..<end).caretFromSelectedRange(window: 3)
        #expect(tail?.textBefore?.contains("\u{FFFD}") == false)
        #expect(CaretWindow.tail(of: emoji, window: 3) == "cd")
        #expect(CaretWindow.head(of: "\u{1F600}ab", window: 1) == "")
        #expect(CaretWindow.head(of: "abc", window: 10) == "abc")
    }

    @Test("a marker read answers known, or endOfField when nothing follows")
    func markerCaret() {
        #expect(TextMarkerCaret(before: "Hello ", after: "world").caretState() == .known(before: "Hello ", after: "world"))
        #expect(TextMarkerCaret(before: "Hello", after: "").caretState() == .endOfField(before: "Hello"))
        let long = TextMarkerCaret(before: String(repeating: "a", count: 900), after: String(repeating: "b", count: 900))
        #expect(long.caretState(window: 400) == .known(before: String(repeating: "a", count: 400),
                                                        after: String(repeating: "b", count: 400)))
    }

    /// A mock app whose element exposes text markers (WebKit / Chromium).
    final class MarkerApp: MockSystemAccess, TextMarkerCaretReading {
        var markers: TextMarkerCaret?
        private(set) var markerReads = 0
        func caretByTextMarkers() -> TextMarkerCaret? {
            markerReads += 1
            return markers
        }
    }

    @Test("the marker rung is reachable from a SystemAccess by conformance")
    func markerConformance() {
        let app = MarkerApp()
        app.markers = TextMarkerCaret(before: "a", after: "b")
        let system: SystemAccess = app
        #expect((system as? TextMarkerCaretReading)?.caretByTextMarkers() == TextMarkerCaret(before: "a", after: "b"))
        #expect(app.markerReads == 1)
        #expect((MockSystemAccess() as SystemAccess) as? TextMarkerCaretReading == nil)
        #expect((LiveSystemAccess() as SystemAccess) is TextMarkerCaretReading)
    }

    @Test("a secure field's element info still reads as secure (the reader refuses it before any rung)")
    func secureStillSecure() {
        let native = Self.info(value: nil, range: 0..<0, role: FocusedElementInfo.secureRole)
        let web = Self.info(value: "", range: 0..<0, role: "AXTextField", subrole: FocusedElementInfo.secureRole)
        #expect(native.isSecure)
        #expect(web.isSecure)
    }
}
