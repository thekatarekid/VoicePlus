import CoreGraphics
import Foundation
import Testing
@testable import Shared

/// G0.1 verify — edge cases the first pass left open: decode-time clamping of screen-text
/// confidence (and NaN), corrupted rows failing cleanly instead of trapping, and `renderedText`
/// being idempotent.
@Suite struct G01VerifyTests {

    private static func spans(_ texts: [String]) -> [TranscriptSpan] {
        texts.enumerated().map { i, t in
            TranscriptSpan(text: t, confidence: 0.9, audioRange: Double(i)...Double(i) + 0.5)
        }
    }

    // MARK: - ScreenTextLine confidence

    @Test func screenTextLineTreatsNaNConfidenceAsUntrusted() {
        let line = ScreenTextLine(text: "x", box: .zero, confidence: .nan)
        #expect(line.confidence == 0)
        #expect(line.isLowConfidence)
        #expect(ScreenTextLine(text: "x", box: .zero, confidence: .infinity).confidence == 1)
        #expect(ScreenTextLine(text: "x", box: .zero, confidence: -.infinity).confidence == 0)
    }

    @Test func screenTextLineClampsConfidenceOnDecode() throws {
        let high = #"{"text":"a","box":[[0,0],[10,10]],"confidence":3.5}"#
        let decodedHigh = try JSONDecoder().decode(ScreenTextLine.self, from: Data(high.utf8))
        #expect(decodedHigh.confidence == 1)
        #expect(decodedHigh.characterBoxes == nil)
        #expect(decodedHigh.box == CGRect(x: 0, y: 0, width: 10, height: 10))

        let low = #"{"text":"b","box":[[1,2],[3,4]],"confidence":-1,"characterBoxes":[[[1,2],[3,4]]]}"#
        let decodedLow = try JSONDecoder().decode(ScreenTextLine.self, from: Data(low.utf8))
        #expect(decodedLow.confidence == 0)
        #expect(decodedLow.characterBoxes == [CGRect(x: 1, y: 2, width: 3, height: 4)])

        // Encoding keeps the same keys the decoder reads.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedLow)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["text", "box", "confidence", "characterBoxes"])
    }

    // MARK: - Corrupted rows fail cleanly

    @Test func corruptedRowsThrowInsteadOfTrapping() {
        // Inverted uncertainty range: Range's decoder rejects it; nothing traps.
        let inverted = #"{"turnID":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","startedAt":0,"uncertainSpans":[[9,3]]}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TurnRecord.self, from: Data(inverted.utf8))
        }
        // Identity and start time are required.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TurnRecord.self, from: Data(#"{"startedAt":0}"#.utf8))
        }
        // Unknown discriminators are errors, never a silent different case.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CaretState.self, from: Data(#"{"kind":"guessed"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DeliveryOutcome.self, from: Data(#"{"kind":"maybe"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PunctuationOrigin.self, from: Data(#""dictated""#.utf8))
        }
    }

    @Test func secureDestinationSurvivesARoundTrip() throws {
        let record = TurnRecord(destination: .init(bundleID: "com.1password.1password", role: "AXSecureTextField",
                                                   isSecure: true),
                                outcome: .failed(reason: "secure field"))
        let decoded = try JSONDecoder().decode(TurnRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.destination.isSecure)
        #expect(decoded.isSettled && !decoded.writeAttempted)
    }

    // MARK: - renderedText is idempotent

    @Test func renderedTextIsIdempotent() {
        let pieces = ["", " ", "um", "5100", "hello ", " world", "a  b", "\n- x", "\n    indented  code", "done."]
        for a in pieces {
            for b in pieces {
                let once = Self.spans([a, b]).renderedText
                #expect(Self.spans([once]).renderedText == once, "\([a, b]) → \(once.debugDescription)")
            }
        }
    }
}
