import CoreGraphics
import Foundation
import Testing
@testable import Shared

/// G0.1 — shared types for V4 Wave 1: `CaretState`, `PunctuationOrigin`, `renderedText`,
/// `TurnID`/`TurnRecord`, `ScreenTextReader`/`ScreenTextLine`, `DeliveryOutcome.partial`.
@Suite struct G01SharedTypesTests {

    private func roundTrip<T: Codable & Equatable>(
        _ value: T, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == value, sourceLocation: sourceLocation)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func spans(_ texts: [String]) -> [TranscriptSpan] {
        texts.enumerated().map { i, t in
            TranscriptSpan(text: t, confidence: 0.9, audioRange: Double(i)...Double(i) + 0.5)
        }
    }

    // MARK: - CaretState

    @Test func caretStateExposesTextOnlyWhenACaretWasRead() {
        let known = CaretState.known(before: "Dear Sam,", after: " thanks")
        #expect(known.textBefore == "Dear Sam,")
        #expect(known.textAfter == " thanks")
        #expect(known.hasCaret && !known.isUnknown && !known.isEndOfField)

        let end = CaretState.endOfField(before: "Hello there.")
        #expect(end.textBefore == "Hello there.")
        #expect(end.textAfter == "")
        #expect(end.hasCaret && end.isEndOfField)

        // Unknown is not an empty field: nothing is invented on either side.
        let unknown = CaretState.unknown
        #expect(unknown.textBefore == nil)
        #expect(unknown.textAfter == nil)
        #expect(!unknown.hasCaret && unknown.isUnknown && !unknown.isEndOfField)
        #expect(unknown != .endOfField(before: ""))
        #expect(unknown != .known(before: "", after: ""))
    }

    @Test func caretStateRoundTripsEveryCase() throws {
        let cases: [CaretState] = [
            .known(before: "a 😀 b", after: "c"),
            .known(before: "", after: ""),
            .endOfField(before: "done."),
            .endOfField(before: ""),
            .unknown,
        ]
        for state in cases {
            try roundTrip(state)
        }
        try roundTrip(cases)
        #expect(Set(cases.map(\.kind)) == Set(CaretState.Kind.allCases))
    }

    @Test func caretStateEncodesWithKindDiscriminator() throws {
        let known = try json(CaretState.known(before: "x", after: "y"))
        #expect(known["kind"] as? String == "known")
        #expect(known["before"] as? String == "x")
        #expect(known["after"] as? String == "y")

        let end = try json(CaretState.endOfField(before: "x"))
        #expect(end["kind"] as? String == "endOfField")
        #expect(end["after"] == nil)

        let unknown = try json(CaretState.unknown)
        #expect(unknown["kind"] as? String == "unknown")
        #expect(unknown["before"] == nil && unknown["after"] == nil)

        // Missing text decodes as empty, never as a different case.
        let bare = #"{"kind":"known"}"#
        #expect(try JSONDecoder().decode(CaretState.self, from: Data(bare.utf8)) == .known(before: "", after: ""))
    }

    @Test func caretStateDescriptionCarriesNoUserText() {
        let secret = CaretState.known(before: "my password is hunter2", after: "tail")
        #expect(!secret.description.contains("hunter2"))
        #expect(secret.description == "known(before: 22, after: 4)")
        #expect(CaretState.endOfField(before: "abc").description == "endOfField(before: 3)")
        #expect(CaretState.unknown.description == "unknown")
    }

    // MARK: - PunctuationOrigin

    @Test func punctuationOriginDefaultsToModel() {
        let span = TranscriptSpan(text: "hello,", confidence: 0.9, audioRange: 0...1)
        #expect(span.punctuationOrigin == .model)
        // The full pre-G0.1 call site compiles unchanged and still defaults.
        let full = TranscriptSpan(text: "hi", confidence: 0.9, audioRange: 0...1, alternates: [],
                                  provenance: [.asr], needsRepair: false, stability: .committed)
        #expect(full.punctuationOrigin == .model)
        #expect(PunctuationOrigin.model.isProvisional)
        #expect(!PunctuationOrigin.spoken.isProvisional && !PunctuationOrigin.stage.isProvisional)
    }

    @Test(arguments: PunctuationOrigin.allCases)
    func transcriptSpanRoundTripsEveryPunctuationOrigin(_ origin: PunctuationOrigin) throws {
        let span = TranscriptSpan(
            text: "Kothari.", confidence: 0.42, audioRange: 0.75...1.3,
            alternates: [Alternate(text: "Kotari.", score: 0.3, source: .beam)],
            provenance: [.asr, .formatterProse], needsRepair: true, stability: .committed,
            punctuationOrigin: origin
        )
        #expect(span.punctuationOrigin == origin)
        try roundTrip(span)
        try roundTrip([span])
        #expect(try json(span)["punctuationOrigin"] as? String == origin.rawValue)
    }

    /// JSON written before G0.1 has no `punctuationOrigin` key and must still decode as `.model`.
    @Test func legacySpanJSONDecodesAsModelPunctuation() throws {
        let legacy = #"""
        {"text":"hello there.","confidence":0.91,"audioStart":0.0,"audioEnd":1.4,
         "alternates":[],"provenance":["asr"],"needsRepair":false,"stability":"final"}
        """#
        let span = try JSONDecoder().decode(TranscriptSpan.self, from: Data(legacy.utf8))
        #expect(span.punctuationOrigin == .model)
        #expect(span.text == "hello there.")
        #expect(span.stability == .final)

        let minimal = #"{"text":"hi","confidence":0.5,"audioStart":0,"audioEnd":0.2}"#
        #expect(try JSONDecoder().decode(TranscriptSpan.self, from: Data(minimal.utf8)).punctuationOrigin == .model)
    }

    @Test func punctuationOriginSurvivesStageHelpers() {
        let spoken = TranscriptSpan(text: "yes,", confidence: 0.9, audioRange: 0...1, punctuationOrigin: .spoken)
        #expect(spoken.touched(by: .style).punctuationOrigin == .spoken)
        #expect(spoken.rewritten("Yes,", by: .style).punctuationOrigin == .spoken)
        #expect(spoken.stabilized(.final).punctuationOrigin == .spoken)
        #expect(spoken.flaggedForRepair(by: .style).punctuationOrigin == .spoken)
        // Equality sees the field, so a stage that changes it is visible to the contract diff.
        var model = spoken
        model.punctuationOrigin = .model
        #expect(model != spoken)
        #expect(ConfidenceContract.verify(input: [spoken], output: [spoken.touched(by: .style)]) == [])
    }

    // MARK: - renderedText vs joinedText

    /// (span texts, renderedText, joinedText). `joinedText` stays as it was: tests and diagnostics.
    static let renderTable: [([String], String, String)] = [
        (["hello", "world"], "hello world", "hello world"),
        // V4 §5 cause 2: a removed leading filler leaves an empty first span.
        (["", "hello", "world"], "hello world", " hello world"),
        // V4 §4 cause 3: ITN writes 5100 into the first span and blanks the other three.
        (["5100", "", "", ""], "5100", "5100   "),
        (["I", "", "agree."], "I agree.", "I  agree."),
        (["we", "", "", "met"], "we met", "we   met"),
        (["hello ", " world"], "hello world", "hello   world"),
        (["  ", "ok"], "ok", "   ok"),
        (["a  b", "c"], "a b c", "a  b c"),
        ([" leading", "trailing "], "leading trailing", " leading trailing "),
        ([], "", ""),
        ([""], "", ""),
        (["", "", ""], "", "  "),
        // Line breaks: no space on either side of one, spaces before one are dropped.
        (["Groceries:", "\n- eggs", "\n- milk"], "Groceries:\n- eggs\n- milk", "Groceries: \n- eggs \n- milk"),
        (["end. ", "\nNext"], "end.\nNext", "end.  \nNext"),
        (["one\n", "two"], "one\ntwo", "one\n two"),
        // Indentation right after a line break is kept (code, nested lists); runs inside collapse.
        (["def f():\n    return  x"], "def f():\n    return x", "def f():\n    return  x"),
        (["a\n   \nb"], "a\n\nb", "a\n   \nb"),
        // Only U+0020 collapses; tabs and non-breaking spaces are content.
        (["tab\tkept", "nbsp\u{00A0}\u{00A0}kept"], "tab\tkept nbsp\u{00A0}\u{00A0}kept", "tab\tkept nbsp\u{00A0}\u{00A0}kept"),
    ]

    @Test(arguments: renderTable)
    func renderedTextVersusJoinedText(_ row: ([String], String, String)) {
        let spans = Self.spans(row.0)
        #expect(spans.renderedText == row.1)
        #expect(spans.joinedText == row.2)
    }

    @Test func renderedTextNeverStartsOrEndsWithASpaceOrDoublesOne() {
        let pieces = ["", " ", "  ", "um", "5100", "hello ", " world", "a  b", "\n- x", "done."]
        for a in pieces {
            for b in pieces {
                for c in pieces {
                    let rendered = Self.spans([a, b, c]).renderedText
                    #expect(!rendered.hasPrefix(" "), "\([a, b, c]) → \(rendered.debugDescription)")
                    #expect(!rendered.hasSuffix(" "), "\([a, b, c]) → \(rendered.debugDescription)")
                    #expect(!rendered.contains("  "), "\([a, b, c]) → \(rendered.debugDescription)")
                    #expect(!rendered.contains(" \n"), "\([a, b, c]) → \(rendered.debugDescription)")
                }
            }
        }
    }

    @Test func renderedTextWorksOnAnySequenceOfSpans() {
        let spans = Self.spans(["", "one", "", "two", "three"])
        #expect(spans[1...3].renderedText == "one two")
        #expect(spans.lazy.filter { $0.text != "three" }.renderedText == "one two")
        // Joining never alters the spans themselves.
        #expect(spans.map(\.text) == ["", "one", "", "two", "three"])
    }

    // MARK: - TurnID / TurnRecord

    @Test func turnIDRoundTripsAsABareUUIDString() throws {
        let uuid = try #require(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"))
        let id = TurnID(uuid)
        try roundTrip(id)
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"]"#)
        #expect(id.description == "0F1E2D3C")
        #expect(TurnID() != TurnID())
        #expect(Set([id, TurnID(uuid)]).count == 1)
    }

    private static func fullRecord(outcome: DeliveryOutcome?) -> TurnRecord {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        return TurnRecord(
            turnID: TurnID(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!),
            startedAt: t0,
            destination: .init(bundleID: "com.apple.mail", appName: "Mail", role: "AXTextArea",
                               elementHash: -4_611_686_018_427_387_904, displayID: 69_732_928,
                               selection: 12..<12, textVersion: 987_654_321, isSecure: false),
            rawText: "um send the report to kothari by friday",
            finalText: "Send the report to Kothari by Friday.",
            uncertainSpans: [19..<26],
            capture: .init(captureOpened: t0.addingTimeInterval(0.062),
                           captureClosed: t0.addingTimeInterval(2.4),
                           finalPublished: t0.addingTimeInterval(2.71),
                           finalRendered: t0.addingTimeInterval(2.73),
                           writeDispatched: t0.addingTimeInterval(4.53)),
            writeAttempted: true,
            outcome: outcome,
            retainedAudioPath: "/tmp/voiceplus/turn.caf"
        )
    }

    @Test func turnRecordRoundTripsWithEveryOutcome() throws {
        for outcome: DeliveryOutcome? in [
            nil,
            .delivered(verified: true, method: "keystroke"),
            .delivered(verified: false, method: "paste"),
            .partial(method: "keystroke"),
            .held(reason: "destination changed"),
            .failed(reason: "secure field"),
        ] {
            let record = Self.fullRecord(outcome: outcome)
            try roundTrip(record)
            let decoded = try JSONDecoder().decode(TurnRecord.self, from: JSONEncoder().encode(record))
            #expect(decoded.outcome == outcome)
            #expect(decoded.uncertainSpans == [19..<26])
            #expect(decoded.destination.selection == 12..<12)
        }
        try roundTrip([Self.fullRecord(outcome: nil), TurnRecord()])
    }

    @Test func turnRecordDefaultsDescribeATurnThatHasNotWritten() throws {
        let record = TurnRecord()
        #expect(record.id == record.turnID)
        #expect(record.rawText.isEmpty && record.finalText.isEmpty)
        #expect(!record.writeAttempted)
        #expect(record.outcome == nil)
        #expect(!record.hasUncertainty)
        #expect(!record.isSettled)
        #expect(record.captureOpenLatency == nil)
        #expect(record.retainedAudioPath == nil)
        #expect(!record.destination.isSecure)
        try roundTrip(record)
    }

    /// A row carrying only identity and start time (an older or partial write) still decodes.
    @Test func turnRecordDecodesFromAMinimalRow() throws {
        let minimal = #"{"turnID":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","startedAt":0,"destination":{}}"#
        let record = try JSONDecoder().decode(TurnRecord.self, from: Data(minimal.utf8))
        #expect(record.turnID.rawValue.uuidString == "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
        #expect(record.destination == TurnRecord.Destination())
        #expect(record.uncertainSpans.isEmpty && record.outcome == nil && !record.writeAttempted)
    }

    @Test func turnRecordSeparatesWriteAttemptFromVerification() throws {
        let unconfirmed = Self.fullRecord(outcome: .delivered(verified: false, method: "paste"))
        #expect(unconfirmed.writeAttempted && unconfirmed.outcome?.isVerified == false)
        #expect(unconfirmed.isSettled)
        #expect(unconfirmed.hasUncertainty)
        let latency = try #require(unconfirmed.captureOpenLatency)
        #expect(abs(latency - 0.062) < 0.0005)
        // Held text is still waiting for the user.
        #expect(!Self.fullRecord(outcome: .held(reason: "destination changed")).isSettled)
        #expect(Self.fullRecord(outcome: .partial(method: "keystroke")).isSettled)
    }

    // MARK: - ScreenText

    private final class FixedScreenTextReader: ScreenTextReader {
        let lines: [ScreenTextLine]
        private(set) var requests: [(CGRect, CGDirectDisplayID)] = []
        init(_ lines: [ScreenTextLine]) { self.lines = lines }
        func lines(in rect: CGRect, display: CGDirectDisplayID) async throws -> [ScreenTextLine] {
            requests.append((rect, display))
            return lines.intersecting(rect)
        }
    }

    private struct DeniedReader: ScreenTextReader {
        struct Denied: Error {}
        func lines(in rect: CGRect, display: CGDirectDisplayID) async throws -> [ScreenTextLine] { throw Denied() }
    }

    private static let sampleLines = [
        ScreenTextLine(text: "Quarterly report", box: CGRect(x: 100, y: 700, width: 180, height: 20), confidence: 0.97),
        ScreenTextLine(text: "Revenue 4.2M", box: CGRect(x: 100, y: 670, width: 140, height: 18), confidence: 0.41,
                       characterBoxes: (0..<12).map { CGRect(x: 100 + Double($0) * 11, y: 670, width: 11, height: 18) }),
        ScreenTextLine(text: "Footer", box: CGRect(x: 100, y: 20, width: 60, height: 12), confidence: 0.9),
    ]

    @Test func screenTextReaderIsDrivableThroughTheProtocol() async throws {
        let reader = FixedScreenTextReader(Self.sampleLines)
        let reading: any ScreenTextReader = reader
        let rect = CGRect(x: 90, y: 650, width: 300, height: 80)
        let lines = try await reading.lines(in: rect, display: 1)
        #expect(lines.map(\.text) == ["Quarterly report", "Revenue 4.2M"])
        #expect(lines.text == "Quarterly report\nRevenue 4.2M")
        #expect(reader.requests.count == 1 && reader.requests.first?.1 == 1)

        await #expect(throws: DeniedReader.Denied.self) {
            _ = try await DeniedReader().lines(in: rect, display: 1)
        }
    }

    @Test func screenTextLineClampsConfidenceAndRoundTrips() throws {
        #expect(ScreenTextLine(text: "x", box: .zero, confidence: 1.7).confidence == 1)
        #expect(ScreenTextLine(text: "x", box: .zero, confidence: -0.2).confidence == 0)
        #expect(Self.sampleLines[1].isLowConfidence && !Self.sampleLines[0].isLowConfidence)
        #expect(Self.sampleLines[0].characterBoxes == nil)
        #expect(Self.sampleLines[1].characterBoxes?.count == Self.sampleLines[1].text.count)
        for line in Self.sampleLines { try roundTrip(line) }
        try roundTrip(Self.sampleLines)
    }

    @Test func screenTextLineLookupByPoint() {
        let lines = Self.sampleLines
        #expect(lines.line(at: CGPoint(x: 150, y: 710))?.text == "Quarterly report")
        #expect(lines.line(at: CGPoint(x: 150, y: 675))?.text == "Revenue 4.2M")
        #expect(lines.line(at: CGPoint(x: 5, y: 5)) == nil)
        #expect(lines.intersecting(CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
    }

    // MARK: - DeliveryOutcome.partial

    @Test func partialOutcomeRoundTripsAndEncodesWithKind() throws {
        let partial = DeliveryOutcome.partial(method: "keystroke")
        try roundTrip(partial)
        try roundTrip([partial, .delivered(verified: false, method: "paste")])
        let object = try json(partial)
        #expect(object["kind"] as? String == "partial")
        #expect(object["method"] as? String == "keystroke")
        #expect(object["reason"] == nil && object["verified"] == nil)
        #expect(DeliveryOutcome.Kind.allCases == [.delivered, .partial, .held, .failed])

        let decoded = try JSONDecoder().decode(DeliveryOutcome.self, from: Data(#"{"kind":"partial"}"#.utf8))
        #expect(decoded == .partial(method: ""))
    }

    @Test func partialOutcomeConvenienceSurface() {
        let partial = DeliveryOutcome.partial(method: "keystroke")
        #expect(partial.isPartial)
        #expect(partial.kind == .partial)
        // Terminal: nothing retries it (readback rule); it is not a delivery and never verified.
        #expect(partial.isTerminal)
        #expect(!partial.isDelivered && !partial.isVerified && !partial.isHeld && !partial.isFailed)
        #expect(partial.writeReachedDestination)
        #expect(partial.method == "keystroke")
        #expect(partial.reason == nil)
        #expect(partial.description == "partial(keystroke)")
        #expect(partial != .delivered(verified: false, method: "keystroke"))

        #expect(DeliveryOutcome.delivered(verified: false, method: "paste").writeReachedDestination)
        #expect(!DeliveryOutcome.held(reason: "x").writeReachedDestination)
        #expect(!DeliveryOutcome.failed(reason: "x").writeReachedDestination)
        #expect(!DeliveryOutcome.delivered(verified: true, method: "paste").isPartial)
    }
}
