import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Replace range (T5 / Bet 4 safety)

@Suite struct ReplaceRangeTests {
    func editor(_ value: String, selection: Range<Int>? = nil, configure: (MockSystemAccess) -> Void = { _ in }) -> (ReplaceRangeEditor, MockSystemAccess) {
        let mock = MockSystemAccess()
        mock.field = MockSystemAccess.Field(value: value, selection: selection)
        configure(mock)
        return (ReplaceRangeEditor(system: mock), mock)
    }

    @Test func replacesExactMatch() {
        let (ed, mock) = editor("meet at the cafe tomorrow", selection: 25..<25)
        let outcome = ed.replace(ReplaceRangeRequest(range: 12..<16, expected: "cafe", replacement: "café"))
        #expect(outcome == .replaced(verified: true))
        #expect(mock.field.value == "meet at the café tomorrow")
        #expect(mock.field.selection == 25..<25)   // caret restored
    }

    @Test func caretAfterEditShiftsByDelta() {
        let (ed, mock) = editor("ab cd ef", selection: 8..<8)
        _ = ed.replace(ReplaceRangeRequest(range: 3..<5, expected: "cd", replacement: "cdcd"))
        #expect(mock.field.value == "ab cdcd ef")
        #expect(mock.field.selection == 10..<10)
    }

    @Test func refusesWhenUserEditedRegion() {
        let (ed, mock) = editor("meet at the coffee tomorrow")
        let outcome = ed.replace(ReplaceRangeRequest(range: 12..<16, expected: "cafe", replacement: "café"))
        #expect(outcome == .mismatch(actual: "coff"))
        #expect(mock.field.value == "meet at the coffee tomorrow")
        #expect(mock.journal.isEmpty)
    }

    @Test func refusesWhenRangeOutOfBounds() {
        let (ed, mock) = editor("short")
        #expect(ed.replace(ReplaceRangeRequest(range: 3..<40, expected: "rt", replacement: "x")) == .mismatch(actual: nil))
        #expect(mock.journal.isEmpty)
    }

    @Test func unavailableWhenAXUnreadable() {
        let (ed, mock) = editor("text") { $0.axReadable = false }
        #expect(ed.replace(ReplaceRangeRequest(range: 0..<4, expected: "text", replacement: "x")) == .unavailable(reason: "AX value unreadable"))
        #expect(mock.field.value == "text")
    }

    @Test func unavailableWhenNotSettable() {
        let (ed, mock) = editor("text") { $0.axWriteWorks = false }
        #expect(ed.replace(ReplaceRangeRequest(range: 0..<4, expected: "text", replacement: "x")) == .unavailable(reason: "AX not settable"))
        #expect(mock.field.value == "text")
    }

    @Test func emojiRangesUseUTF16Units() {
        let (ed, mock) = editor("a 🎉 b")
        let outcome = ed.replace(ReplaceRangeRequest(range: 2..<4, expected: "🎉", replacement: "🎂"))
        #expect(outcome == .replaced(verified: true))
        #expect(mock.field.value == "a 🎂 b")
    }
}
