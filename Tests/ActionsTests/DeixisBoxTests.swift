import Foundation
import CoreGraphics
import Testing
import Shared
@testable import Actions

/// G1 / G3 — a drawn box binds its deictic word, and a resolved box reads as a context line.
@Suite("G1 box binding + G3 region context")
struct DeixisBoxTests {
    static let elements = [
        ElementReference(id: "send", role: "AXButton", label: "Send", frame: CGRect(x: 100, y: 100, width: 80, height: 30), displayID: 1),
        ElementReference(id: "body", role: "AXTextArea", label: "Message", frame: CGRect(x: 100, y: 200, width: 400, height: 300), displayID: 1),
    ]

    static func box(_ rect: CGRect, from: TimelineInstant, to: TimelineInstant, into tl: InputTimeline, id: UUID = UUID()) {
        tl.record(.region(RegionSample(regionID: id, rect: .init(origin: rect.origin, size: .zero), displayID: 1, isComplete: false)), at: from)
        tl.record(.region(RegionSample(regionID: id, rect: rect, displayID: 1, isComplete: true)), at: to)
    }

    @Test func boxDrawnAroundTheWordWinsOverThePointer() {
        let tl = InputTimeline()
        // Pointer rests on the text area, but a box is drawn around the Send button while saying "this".
        tl.record(.pointerMove(GlobalPoint(x: 300, y: 300, displayID: 1)), at: 10.0)
        let id = UUID()
        Self.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 10.1, to: 10.4, into: tl, id: id)
        let resolver = DeixisResolver(hitTester: MockAXHitTester(elements: Self.elements))
        let spans = [TranscriptSpan(text: "send", confidence: 0.9, audioRange: 0.0...0.2),
                     TranscriptSpan(text: "this", confidence: 0.9, audioRange: 0.3...0.5)]
        let b = resolver.resolve(spans: spans, alignment: CaptureAlignment(captureStart: 10), timeline: tl)
        #expect(b.count == 1)
        guard case .region(let r)? = b.first?.reference else { Issue.record("expected a box"); return }
        #expect(r.regionID == id && r.elements.map(\.id) == ["send"] && b[0].confidence == 0.9)
        #expect(b[0].contextLine == "this = Send @display 1")
    }

    @Test func twoBoxesBindTwoWordsByTime() {
        let tl = InputTimeline()
        let first = UUID(), second = UUID()
        Self.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 0.1, to: 0.4, into: tl, id: first)
        Self.box(CGRect(x: 110, y: 210, width: 380, height: 280), from: 1.4, to: 1.7, into: tl, id: second)
        let resolver = DeixisResolver(hitTester: MockAXHitTester(elements: Self.elements))
        let spans = [TranscriptSpan(text: "this", confidence: 0.9, audioRange: 0.2...0.4),
                     TranscriptSpan(text: "into", confidence: 0.9, audioRange: 0.8...1.0),
                     TranscriptSpan(text: "that", confidence: 0.9, audioRange: 1.5...1.7)]
        let b = resolver.resolve(spans: spans, alignment: CaptureAlignment(captureStart: 0), timeline: tl)
        let ids = b.map { binding -> UUID? in
            if case .region(let r)? = binding.reference { return r.regionID }
            return nil
        }
        #expect(ids == [first, second])
    }

    @Test func unfinishedDragNeverBinds() {
        let tl = InputTimeline()
        tl.record(.region(RegionSample(regionID: UUID(), rect: .zero, displayID: 1, isComplete: false)), at: 0.2)
        #expect(tl.regions(in: 0...1).isEmpty)
    }

    @Test func regionContextLineCarriesRoleTitleAndText() {
        let region = DeixisRegion(id: UUID(), rect: CGRect(x: 0, y: 0, width: 320, height: 90), displayID: 1,
                                  element: Self.elements[1], text: "Send the deck\nby \"Friday\"", source: .ax)
        #expect(region.contextLine(index: 1) == #"region 1 = AXTextArea "Message" text: "Send the deck by \"Friday\"""#)
        let bare = DeixisRegion(id: UUID(), rect: .zero, displayID: 1)
        #expect(bare.contextLine(index: 2) == #"region 2 = AXUnknown "" text: """#)
        let long = DeixisRegion(id: UUID(), rect: .zero, displayID: 1, text: String(repeating: "a", count: 400))
        #expect(long.contextLine(index: 3).hasSuffix(String(repeating: "a", count: DeixisRegion.contextTextLimit) + "…\""))
    }

    @Test func boxedCharacterRangeClipsToVisible() {
        let visible = CFRange(location: 100, length: 500)
        // Corners inside the visible text: from the top-left character to the bottom-right one.
        let r = AXTextRange.boxed(visible: visible, topLeft: CFRange(location: 150, length: 1),
                                  bottomRight: CFRange(location: 220, length: 1))
        #expect(r?.location == 150 && r?.length == 71)
        // Corner lookups unsupported: the whole visible range.
        let whole = AXTextRange.boxed(visible: visible, topLeft: nil, bottomRight: nil)
        #expect(whole?.location == 100 && whole?.length == 500)
        // Corners outside the visible range are clipped to it.
        let clipped = AXTextRange.boxed(visible: visible, topLeft: CFRange(location: 20, length: 1),
                                        bottomRight: CFRange(location: 900, length: 1))
        #expect(clipped?.location == 100 && clipped?.length == 500)
        #expect(AXTextRange.boxed(visible: CFRange(location: 0, length: 0), topLeft: nil, bottomRight: nil) == nil)
    }
}

/// H4 — a box binds the word whose audioRange (± 300 ms) its drag overlaps, not the latest box.
@Suite("H4 time-aligned gesture binding")
struct DeixisTimeAlignedTests {
    static func boundID(_ b: DeixisBinding?) -> UUID? {
        if case .region(let r)? = b?.reference { return r.regionID }
        return nil
    }
    static func resolve(_ word: ClosedRange<TimeInterval>, _ tl: InputTimeline) -> DeixisBinding? {
        DeixisResolver(hitTester: MockAXHitTester(elements: DeixisBoxTests.elements))
            .resolve(spans: [TranscriptSpan(text: "this", confidence: 0.9, audioRange: word)],
                     alignment: CaptureAlignment(captureStart: 0), timeline: tl).first
    }

    @Test func boxDrawnDuringTheWordBeatsALaterBox() {
        let tl = InputTimeline()
        let during = UUID(), later = UUID()
        DeixisBoxTests.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 1.0, to: 1.3, into: tl, id: during)
        // A second box started right after the word, inside the ± 300 ms slack: latest, but not the word's.
        DeixisBoxTests.box(CGRect(x: 110, y: 210, width: 380, height: 280), from: 1.45, to: 1.6, into: tl, id: later)
        #expect(Self.boundID(Self.resolve(1.0...1.3, tl)) == during)
    }

    @Test func boxOutsideTheSlackDoesNotBind() {
        let tl = InputTimeline()
        tl.record(.pointerMove(GlobalPoint(x: 300, y: 300, displayID: 1)), at: 0.0)
        // Word 0.4–0.5; box drawn 0.85–0.95 — within the old ±0.6 s midpoint window, but > 300 ms after the word.
        DeixisBoxTests.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 0.85, to: 0.95, into: tl)
        let b = Self.resolve(0.4...0.5, tl)
        #expect(Self.boundID(b) == nil)
        guard case .element(let e)? = b?.reference else { Issue.record("expected pointer fallback"); return }
        #expect(e.id == "body")
    }

    @Test func boxFinishedJustBeforeTheWordBinds() {
        let tl = InputTimeline()
        let id = UUID()
        // Drawn 0.5–0.8, word spoken 1.05–1.2: the drag ended 250 ms before the word.
        DeixisBoxTests.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 0.5, to: 0.8, into: tl, id: id)
        #expect(Self.boundID(Self.resolve(1.05...1.2, tl)) == id)
        // 350 ms before: too early.
        let tl2 = InputTimeline()
        DeixisBoxTests.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 0.4, to: 0.7, into: tl2)
        #expect(Self.boundID(Self.resolve(1.05...1.2, tl2)) == nil)
    }

    @Test func longWordPicksTheBoxWithMostOverlap() {
        let tl = InputTimeline()
        let small = UUID(), big = UUID()
        DeixisBoxTests.box(CGRect(x: 95, y: 95, width: 90, height: 40), from: 1.9, to: 2.1, into: tl, id: small)
        DeixisBoxTests.box(CGRect(x: 110, y: 210, width: 380, height: 280), from: 1.0, to: 1.8, into: tl, id: big)
        #expect(Self.boundID(Self.resolve(1.0...2.0, tl)) == big)
    }
}
