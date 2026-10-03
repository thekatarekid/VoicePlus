import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Hands-free fix (RC6) — in Claude (Electron) the AX value and caret lag our own keystroke write, so
/// the next hands-free piece read a stale caret and landed with no leading space, a lowercased first
/// word and its full stop dropped. A reading that does not show our just-landed text before the
/// caret yields to landing memory (nothing has touched the field since).
@Suite("Hands-free: stale AX caret after our own landing (RC6)")
struct HandsFreeStaleCaretTests {
    typealias C = CaretLandingTests

    @Test("a stale AX reading after our landing: the next piece joins with a space, a capital and its stop")
    func staleReadingJoinsOntoOurLanding() async {
        let mock = C.mock(MockSystemAccess.Field(role: "AXTextArea", value: ""))
        mock.runtimeByPID[100] = .electron
        let reader = FieldContextReader(system: mock)
        let lander = C.lander(mock, reader: reader)
        let first = await lander.land(C.words("Finish dictation is not landing the text."), startedAt: Date(), focus: mock.frontmost)
        #expect(first.landed)
        // Electron has not refreshed AX yet: the composer still reads as it was before the write.
        mock.field = MockSystemAccess.Field(role: "AXTextArea", value: "Fin", selection: 2..<2)
        let second = await lander.land(C.words("Pausing while I speak is landing the text in some cases."),
                                       startedAt: Date(), focus: mock.frontmost)
        #expect(reader.lastReading?.rung == .landingMemory)
        #expect(second.text == " Pausing while I speak is landing the text in some cases.", "\(second.text)")
    }

    @Test("a native text view's AX reading is never second-guessed")
    func nativeReadingStands() async {
        let mock = C.mock(MockSystemAccess.Field(role: "AXTextArea", value: ""))
        let reader = FieldContextReader(system: mock)
        let lander = C.lander(mock, reader: reader)
        _ = await lander.land(C.words("Finish dictation is not landing the text."), startedAt: Date(), focus: mock.frontmost)
        mock.field = MockSystemAccess.Field(role: "AXTextArea", value: "", selection: 0..<0)
        _ = await lander.land(C.words("Next."), startedAt: Date(), focus: mock.frontmost)
        #expect(reader.lastReading?.rung == .selectedRange)
    }

    @Test("an AX reading that shows our landing is used as it is")
    func freshReadingStands() async {
        let mock = C.mock(MockSystemAccess.Field(role: "AXTextArea", value: ""))
        mock.runtimeByPID[100] = .electron
        let reader = FieldContextReader(system: mock)
        let lander = C.lander(mock, reader: reader)
        _ = await lander.land(C.words("Send the report."), startedAt: Date(), focus: mock.frontmost)
        #expect(mock.field.value.hasSuffix("Send the report."))
        let second = await lander.land(C.words("Then the invoice."), startedAt: Date(), focus: mock.frontmost)
        #expect(reader.lastReading?.rung == .selectedRange)
        #expect(second.text == " Then the invoice.", "\(second.text)")
    }

    @Test("stale-reading rule: compared on our text's tail, smart quotes and whitespace ignored")
    func rule() {
        typealias R = FieldContextReader
        #expect(!R.readingMissesLanding(.endOfField(before: "Hello there. I don’t know. "), landed: " I don't know."))
        #expect(R.readingMissesLanding(.known(before: "Fi", after: "nish"), landed: "Finish the work."))
        #expect(!R.readingMissesLanding(.unknown, landed: "x"))
        #expect(!R.readingMissesLanding(.endOfField(before: "abc"), landed: "   "))
        #expect(!R.readingMissesLanding(.endOfField(before: "abc"), landed: nil))
    }
}
