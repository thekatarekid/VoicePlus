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

    @Test("H9: a selection edit leaves the new text selected, not the old range")
    func selectResultSelectsReplacement() {
        let (ed, mock) = editor("say we should meet sometime soon ok", selection: 4..<32)
        let outcome = ed.replace(ReplaceRangeRequest(range: 4..<32, expected: "we should meet sometime soon",
                                                     replacement: "let's meet", selectResult: true))
        #expect(outcome == .replaced(verified: true))
        #expect(mock.field.value == "say let's meet ok")
        #expect(mock.field.selection == 4..<14)
        // Longer result: the selection grows with it.
        let (ed2, mock2) = editor("x ab y", selection: 2..<4)
        _ = ed2.replace(ReplaceRangeRequest(range: 2..<4, expected: "ab", replacement: "abcdef", selectResult: true))
        #expect(mock2.field.selection == 2..<8)
        #expect(ReplaceRangeRequest(range: 2..<4, expected: "ab", replacement: "abcdef").resultingRange == 2..<8)
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

    @Test("Safety: a password field is never written, even when AX would allow it")
    func refusesSecureField() {
        for web in [false, true] {
            let mock = MockSystemAccess()
            var f = MockSystemAccess.Field.secure(webStyle: web)
            f.value = "hunter2"; f.selection = 0..<7
            mock.field = f
            let ed = ReplaceRangeEditor(system: mock)
            #expect(ed.replace(ReplaceRangeRequest(range: 0..<7, expected: "hunter2", replacement: "x")) == .unavailable(reason: ReplaceRangeEditor.secureFieldReason))
            #expect(mock.field.value == "hunter2")
        }
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
