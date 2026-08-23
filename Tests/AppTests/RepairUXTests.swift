import Foundation
import Testing
import Shared
import Engine
@testable import VoicePlusApp

@Suite("P1.6 T4 — repair fan-out UX model")
struct RepairUXTests {
    static let spans = [
        TranscriptSpan(text: "send", confidence: 0.98, audioRange: 0...0.1),
        TranscriptSpan(text: "kothari", confidence: 0.4, audioRange: 0.8...1.04, alternates: [
            Alternate(text: "Cotari", score: 0.5, source: .beam), Alternate(text: "Kothari", score: 0.3, source: .biasing),
            Alternate(text: "cotari", score: 0.2, source: .beam), Alternate(text: "Katari", score: 0.1, source: .beam),
            Alternate(text: "Kotari", score: 0.05, source: .beam), Alternate(text: "Cottari", score: 0.01, source: .beam),
        ]),
        TranscriptSpan(text: "now", confidence: 0.45, audioRange: 1.2...1.4, alternates: [Alternate(text: "no", score: 0.4, source: .beam)]),
    ]

    @Test func numberedDistinctAlternatesCappedAtFive() throws {
        let m = try #require(RepairFanoutModel(span: Self.spans[1], index: 1))
        #expect(m.items.map(\.number) == [1, 2, 3, 4, 5])
        #expect(m.items.map(\.text) == ["Cotari", "Kothari", "Katari", "Kotari", "Cottari"]) // "cotari" dup dropped
        #expect(m.alternateIndex(forNumber: 2) == 1 && m.alternateIndex(forNumber: 6) == nil)
        #expect(RepairFanoutModel(span: Self.spans[0], index: 0) == nil)
    }

    @Test func picksSpanUnderMouseElseWeakestWithAlternates() {
        let rects: [Int: CGRect] = [1: CGRect(x: 100, y: 500, width: 60, height: 18), 2: CGRect(x: 170, y: 500, width: 30, height: 18)]
        #expect(RepairFanoutModel.spanIndex(under: CGPoint(x: 180, y: 505), wordRects: rects, spans: Self.spans) == 2)
        #expect(RepairFanoutModel.spanIndex(under: CGPoint(x: 10, y: 10), wordRects: rects, spans: Self.spans) == 1)
        #expect(RepairFanoutModel.spanIndex(under: nil, wordRects: [:], spans: Self.spans) == 1)
        #expect(RepairFanoutModel.spanIndex(under: nil, wordRects: [:], spans: [Self.spans[0]]) == nil)
    }

    @Test func anchorsBeneathWordFlipsAboveAndClampsToScreen() throws {
        let m = try #require(RepairFanoutModel(span: Self.spans[1], index: 1))
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let word = CGRect(x: 300, y: 600, width: 60, height: 18)
        let below = m.frame(anchoredTo: word, in: screen)
        #expect(below.minX == 300 && below.maxY == 600 - RepairFanoutModel.gap && below.height == m.size.height)
        let lowWord = CGRect(x: 1400, y: 20, width: 60, height: 18)
        let flipped = m.frame(anchoredTo: lowWord, in: screen)
        #expect(flipped.minY == 20 + 18 + RepairFanoutModel.gap)       // above the word
        #expect(flipped.maxX <= screen.maxX && flipped.minX < 1400)    // pulled left onto the screen
    }

    @Test func axRectConvertsToAppKitCoordinates() {
        let ax = CGRect(x: 100, y: 50, width: 80, height: 20) // Quartz: 50 pt from the top
        let r = RepairFanoutModel.appKitRect(fromAX: ax, primaryScreenHeight: 900)
        #expect(r == CGRect(x: 100, y: 830, width: 80, height: 20))
    }

    @Test @MainActor func panelPickRoutesToSession() throws {
        final class FakeRects: WordRectProvider {
            func wordRect(utf16Range: Range<Int>) -> CGRect? { CGRect(x: CGFloat(utf16Range.lowerBound) * 8 + 200, y: 400, width: CGFloat(utf16Range.count) * 8, height: 18) }
        }
        let sink = InMemoryReplaceRangeSink(document: "send kothari now")
        let session = RepairSession(replaceSink: sink)
        session.land(Utterance(spans: Self.spans), fieldOffset: 0)
        let panel = RepairFanoutPanel(session: session, rectProvider: FakeRects())
        #expect(panel.show(at: nil, fieldOffset: 0))
        #expect(panel.isVisible && panel.model?.spanIndex == 1)
        #expect(panel.pick(number: 2) == .replaced(spanIndex: 1, from: "kothari", to: "Kothari"))
        #expect(sink.document == "send Kothari now" && !panel.isVisible)
        #expect(panel.pick(number: 1) == nil) // nothing shown any more
        session.end()
        #expect(!panel.show(at: nil, fieldOffset: 0))
    }
}
