import Foundation
import CoreGraphics
import Testing
import Shared
@testable import Actions

/// Deterministic LCG so the fixture is identical on every run.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + unit() * (hi - lo) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Two displays: primary 1920×1080 at origin, secondary 1440×900 to the right (Cocoa global).
let fixtureDisplays = [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                       DisplayFrame(id: 2, frame: CGRect(x: 1920, y: 180, width: 1440, height: 900))]

struct DeixisCase {
    var mode: String                // "point" | "stroke" | "move-then-point"
    var word: String
    var expectedID: String
    var timeline: InputTimeline
    var alignment: CaptureAlignment
    var spans: [TranscriptSpan]
    var elements: [ElementReference]
}

enum DeixisFixture {
    /// Grid of buttons on each display, with ≥32pt gaps so elements are distinct.
    static func layout(_ rng: inout SeededRNG) -> [ElementReference] {
        var out: [ElementReference] = []
        for d in fixtureDisplays {
            let cols = 5, rows = 4
            let cw = d.frame.width / CGFloat(cols), rh = d.frame.height / CGFloat(rows)
            for r in 0..<rows { for c in 0..<cols {
                let w = rng.range(cw * 0.4, cw * 0.75), h = rng.range(rh * 0.35, rh * 0.7)
                let x = d.frame.minX + CGFloat(c) * cw + rng.range(0, cw - w)
                let y = d.frame.minY + CGFloat(r) * rh + rng.range(0, rh - h)
                out.append(ElementReference(id: "d\(d.id)-r\(r)c\(c)", role: "AXButton", label: "Item \(r)\(c)", frame: CGRect(x: x, y: y, width: w, height: h), displayID: d.id))
            } }
        }
        return out
    }

    static func make(count: Int, seed: UInt64 = 42) -> [DeixisCase] {
        var rng = SeededRNG(seed: seed)
        let n = DisplayNormalizer(displays: fixtureDisplays)
        let elements = layout(&rng)
        return (0..<count).map { i in
            let target = elements[rng.int(elements.count)]
            let captureStart: TimelineInstant = 1000 + Double(i) * 10
            let align = CaptureAlignment(captureStart: captureStart)
            let tl = InputTimeline()
            let words = ["this", "that", "there", "these", "those", "here"]
            let word = words[rng.int(words.count)]
            // Utterance: "move <word> over ..." — deictic word at 0.9…1.1 s into capture.
            let wordStart = 0.9 + Double(rng.unit()) * 0.3
            let wordRange = wordStart...(wordStart + 0.18)
            let wordMid = align.instant(forAudioSeconds: (wordRange.lowerBound + wordRange.upperBound) / 2)
            let mode = ["point", "stroke", "move-then-point"][i % 3]
            // Random start anywhere (often on the other display) → pointer travels to target.
            let startEl = elements[rng.int(elements.count)]
            let start = CGPoint(x: startEl.frame.midX, y: startEl.frame.midY)
            let dest = CGPoint(x: target.frame.midX + rng.range(-target.frame.width * 0.3, target.frame.width * 0.3),
                               y: target.frame.midY + rng.range(-target.frame.height * 0.3, target.frame.height * 0.3))
            // Arrive 100–250 ms before the word midpoint; 120 Hz samples.
            let arrive = wordMid - 0.10 - Double(rng.unit()) * 0.15
            let travel = 0.4
            var t = arrive - travel
            while t < arrive {
                let f = CGFloat((t - (arrive - travel)) / travel)
                let p = CGPoint(x: start.x + (dest.x - start.x) * f, y: start.y + (dest.y - start.y) * f)
                tl.record(.pointerMove(n.normalize(cocoa: p)), at: t); t += 1.0 / 120
            }
            if mode == "stroke" {
                // Circle the target around the word.
                let sid = UUID(); let r = max(target.frame.width, target.frame.height) * 0.55
                for k in 0..<24 {
                    let a = CGFloat(k) / 24 * 2 * .pi
                    let p = CGPoint(x: target.frame.midX + cos(a) * r, y: target.frame.midY + sin(a) * r)
                    tl.record(.strokePoint(strokeID: sid, n.normalize(cocoa: p), pressure: 1), at: arrive + Double(k) * 0.02)
                }
            } else {
                // Dwell with jitter through the word, then (move-then-point) leave quickly afterwards.
                var d = arrive
                while d < wordMid + 0.25 {
                    let p = CGPoint(x: dest.x + rng.range(-2, 2), y: dest.y + rng.range(-2, 2))
                    tl.record(.pointerMove(n.normalize(cocoa: p)), at: d); d += 1.0 / 120
                }
                if mode == "move-then-point" {
                    let other = elements[rng.int(elements.count)]
                    tl.record(.pointerMove(n.normalize(cocoa: CGPoint(x: other.frame.midX, y: other.frame.midY))), at: wordMid + 0.4)
                }
            }
            let spans = [TranscriptSpan(text: "move", confidence: 0.9, audioRange: 0.5...0.8),
                         TranscriptSpan(text: word, confidence: 0.9, audioRange: wordRange),
                         TranscriptSpan(text: "over", confidence: 0.9, audioRange: (wordRange.upperBound + 0.05)...(wordRange.upperBound + 0.3))]
            return DeixisCase(mode: mode, word: word, expectedID: target.id, timeline: tl, alignment: align, spans: spans, elements: elements)
        }
    }
}

@Suite("P3.3 deixis binding fixture (phase gate ≥95%)")
struct DeixisFixtureTests {
    @Test func scriptedSuiteBindsAtLeast95Percent() {
        let cases = DeixisFixture.make(count: 120)
        var correct = 0, displays = Set<UInt32>()
        for c in cases {
            let resolver = DeixisResolver(hitTester: MockAXHitTester(elements: c.elements))
            let b = resolver.resolve(spans: c.spans, alignment: c.alignment, timeline: c.timeline)
            #expect(b.count == 1)
            guard let ref = b.first?.reference else { continue }
            let id: String?
            switch ref {
            case .element(let e): id = e.id
            case .region(let r): id = r.elements.count == 1 ? r.elements[0].id : nil
            }
            if id == c.expectedID { correct += 1 }
            displays.insert(ref.displayID)
        }
        let pct = Double(correct) / Double(cases.count) * 100
        print("DEIXIS FIXTURE: \(correct)/\(cases.count) correct (\(pct)%)")
        #expect(pct >= 95, "binding accuracy \(pct)% below 95% gate")
        #expect(displays == [1, 2], "fixture must exercise both displays")
    }

    @Test func bothReferentsOfMoveThisOverThere() {
        let els = [ElementReference(id: "a", role: "AXImage", label: "Logo", frame: CGRect(x: 100, y: 100, width: 200, height: 100), displayID: 1),
                   ElementReference(id: "b", role: "AXGroup", label: "Sidebar", frame: CGRect(x: 2000, y: 300, width: 300, height: 500), displayID: 2)]
        let n = DisplayNormalizer(displays: fixtureDisplays)
        let tl = InputTimeline(); let align = CaptureAlignment(captureStart: 100)
        tl.record(.pointerMove(n.normalize(cocoa: CGPoint(x: 150, y: 150))), at: 100.4)           // on "a" during "this"
        tl.record(.pointerMove(n.normalize(cocoa: CGPoint(x: 2100, y: 500))), at: 101.3)          // on "b" during "there"
        let spans = [TranscriptSpan(text: "move", confidence: 1, audioRange: 0.1...0.3),
                     TranscriptSpan(text: "this", confidence: 1, audioRange: 0.4...0.6),
                     TranscriptSpan(text: "over", confidence: 1, audioRange: 0.8...1.0),
                     TranscriptSpan(text: "there", confidence: 1, audioRange: 1.3...1.5)]
        let b = DeixisResolver(hitTester: MockAXHitTester(elements: els)).resolve(spans: spans, alignment: align, timeline: tl)
        #expect(b.map(\.word) == ["this", "there"])
        #expect(b[0].reference == .element(els[0]) && b[1].reference == .element(els[1]))
        #expect(b[0].contextLine == "this = Logo @display 1")
    }

    @Test func nearMissBetweenTwoElementsIsAmbiguous() {
        let els = [ElementReference(id: "l", role: "AXButton", label: "Left", frame: CGRect(x: 0, y: 0, width: 100, height: 50), displayID: 1),
                   ElementReference(id: "r", role: "AXButton", label: "Right", frame: CGRect(x: 120, y: 0, width: 100, height: 50), displayID: 1)]
        let tl = InputTimeline(); tl.record(.pointerMove(GlobalPoint(x: 110, y: 25, displayID: 1)), at: 10.5)
        let spans = [TranscriptSpan(text: "That", confidence: 1, audioRange: 0.4...0.6)]
        let b = DeixisResolver(hitTester: MockAXHitTester(elements: els)).resolve(spans: spans, alignment: CaptureAlignment(captureStart: 10), timeline: tl)
        #expect(b[0].isAmbiguous && b[0].reference == nil && b[0].candidates.count == 2)
        #expect(ReverseElicitation.needsElicitation(b[0]))
        // Same display id required: an element on display 2 at the same local coords is not a candidate.
        let tl2 = InputTimeline(); tl2.record(.pointerMove(GlobalPoint(x: 110, y: 25, displayID: 2)), at: 10.5)
        let b2 = DeixisResolver(hitTester: MockAXHitTester(elements: els)).resolve(spans: spans, alignment: CaptureAlignment(captureStart: 10), timeline: tl2)
        #expect(b2[0].reference == nil && b2[0].candidates.isEmpty)
    }

    @Test func strokeBundleProducesRegionWithCoveredElements() {
        let els = [ElementReference(id: "a", role: "AXStaticText", label: "A", frame: CGRect(x: 10, y: 10, width: 40, height: 20), displayID: 1),
                   ElementReference(id: "b", role: "AXStaticText", label: "B", frame: CGRect(x: 60, y: 10, width: 40, height: 20), displayID: 1),
                   ElementReference(id: "far", role: "AXStaticText", label: "Far", frame: CGRect(x: 500, y: 500, width: 40, height: 20), displayID: 1)]
        let tl = InputTimeline(); let sid = UUID()
        for (k, p) in [(0, 0), (110, 0), (110, 40), (0, 40)].enumerated() {
            tl.record(.strokePoint(strokeID: sid, GlobalPoint(x: CGFloat(p.0), y: CGFloat(p.1), displayID: 1), pressure: 1), at: 20 + Double(k) * 0.05)
        }
        let b = DeixisResolver(hitTester: MockAXHitTester(elements: els)).resolve(
            spans: [TranscriptSpan(text: "these", confidence: 1, audioRange: 0.2...0.4)], alignment: CaptureAlignment(captureStart: 20), timeline: tl)
        guard case .region(let r)? = b.first?.reference else { Issue.record("expected region"); return }
        #expect(Set(r.elements.map(\.id)) == ["a", "b"] && r.strokeIDs == [sid])
        #expect(r.bounds == CGRect(x: 0, y: 0, width: 110, height: 40))
    }

    @Test func noPointerHistoryLeavesUnresolved() {
        let b = DeixisResolver(hitTester: MockAXHitTester(elements: [])).resolve(
            spans: [TranscriptSpan(text: "this", confidence: 1, audioRange: 0...0.2)], alignment: CaptureAlignment(captureStart: 0), timeline: InputTimeline())
        #expect(b[0].reference == nil && b[0].contextLine == "this = unresolved")
    }
}
