import Foundation
import Testing
import Shared
@testable import Engine

/// Deterministic LCG so failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

@Suite("P1.5.1 — splice property test + precision")
struct ReconcileSpliceTests {
    static let vocab = ["send", "it", "to", "kothari", "tomorrow", "the", "quarterly", "numbers", "please", "and", "cc", "raj", "before", "noon", "meeting"]

    /// Tagged document: one tag per UTF-16 unit. "I" = injected by us, "U" = typed by the user, "C" = corrected.
    struct TaggedDoc {
        var units: [UInt16]; var tags: [Character]
        var text: String { String(decoding: units, as: UTF16.self) }
        mutating func userEdit<G: RandomNumberGenerator>(_ rng: inout G) {
            guard !units.isEmpty else { return }
            let pos = Int.random(in: 0...units.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: // insert
                let s = Array(["x", "Q", " ", "é", "ab"].randomElement(using: &rng)!.utf16)
                units.insert(contentsOf: s, at: pos); tags.insert(contentsOf: Array(repeating: "U", count: s.count), at: pos)
            case 1 where pos < units.count: // delete
                units.remove(at: pos); tags.remove(at: pos)
            default: // overwrite one unit with a char never produced by the recogniser
                if pos < units.count { units[pos] = Array("~".utf16)[0]; tags[pos] = "U" }
            }
        }
    }

    static func synthetic<G: RandomNumberGenerator>(_ rng: inout G, words: Int) -> (preview: [TranscriptSpan], final: [TranscriptSpan], truth: [String]) {
        var p: [TranscriptSpan] = [], f: [TranscriptSpan] = [], truth: [String] = []
        var t: TimeInterval = 0
        for _ in 0..<words {
            let w = vocab.randomElement(using: &rng)!; truth.append(w)
            let end = t + 0.3
            let previewWrong = Double.random(in: 0..<1, using: &rng) < 0.3
            let finalWrong = Double.random(in: 0..<1, using: &rng) < 0.08
            p.append(sp(previewWrong ? w + "a" : w, t...end, 0.5))
            let fc = finalWrong ? Float.random(in: 0.2..<0.75, using: &rng) : Float.random(in: 0.65..<1.0, using: &rng)
            f.append(sp(finalWrong ? w + "o" : w, t...end, fc))
            t = end + 0.05
        }
        return (p, f, truth)
    }

    @Test func correctionsNeverAlterUserModifiedText() {
        var rng = SeededRNG(42)
        var applied = 0, suggested = 0
        for _ in 0..<400 {
            let (p, f, _) = Self.synthetic(&rng, words: Int.random(in: 1...8, using: &rng))
            let prefix = ["", "Hi. ", "Note:\n"].randomElement(using: &rng)!
            let injected = p.joinedText
            let base = prefix + injected + " tail"
            var doc = TaggedDoc(units: Array(base.utf16), tags: Array(repeating: "I", count: base.utf16.count))
            for _ in 0..<Int.random(in: 0...4, using: &rng) { doc.userEdit(&rng) }
            let userUnits = zip(doc.units, doc.tags).filter { $0.1 == "U" }.map(\.0)
            let beforeText = doc.text

            let sink = InMemoryReplaceRangeSink(document: doc.text)
            let layout = LandedLayout(fieldOffset: prefix.utf16.count, spans: p)
            let plan = CorrectionPlanner().plan(utteranceID: UUID(), preview: p, final: f, layout: layout, readback: SinkReadback(sink))
            let events = CorrectionApplier(replaceSink: sink).apply(plan)

            // Mirror applied edits onto the tagged doc and check no "U" unit was inside a replaced range.
            for e in events.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                switch e.kind {
                case .applied:
                    applied += 1
                    let original = e.range.lowerBound..<(e.range.lowerBound + e.was.utf16.count)
                    #expect(doc.tags[original].allSatisfy { $0 == "I" }, "corrected a region the user touched: \(doc.text) range \(original)")
                    #expect(String(decoding: doc.units[original], as: UTF16.self) == e.was)
                    doc.units.replaceSubrange(original, with: Array(e.now.utf16))
                    doc.tags.replaceSubrange(original, with: Array(repeating: "C", count: e.now.utf16.count))
                case .suggested: suggested += 1
                case .refused: Issue.record("in-memory sink should never refuse after a clean plan")
                }
            }
            #expect(doc.text == sink.document)
            #expect(zip(doc.units, doc.tags).filter { $0.1 == "U" }.map(\.0) == userUnits, "user-typed units changed")
            // Once the landed region no longer reads as injected, every correction must have been downgraded.
            if CorrectionPlanner.slice(base, layout.range(for: 0..<p.count)) != CorrectionPlanner.slice(beforeText, layout.range(for: 0..<p.count)) {
                #expect(plan.corrections.isEmpty && events.allSatisfy { $0.kind != .applied })
            }
        }
        #expect(applied > 50 && suggested > 20, "fuzz should exercise both paths (applied=\(applied), suggested=\(suggested))")
    }

    @Test func precisionOnSyntheticDisagreementsIsAtLeast95Percent() {
        var rng = SeededRNG(7)
        var correct = 0, total = 0, disagreements = 0
        for _ in 0..<300 {
            let (p, f, truth) = Self.synthetic(&rng, words: 8)
            let sink = InMemoryReplaceRangeSink(document: p.joinedText)
            let plan = CorrectionPlanner().plan(utteranceID: UUID(), preview: p, final: f, layout: LandedLayout(fieldOffset: 0, spans: p), readback: SinkReadback(sink))
            disagreements += plan.items.count
            for item in plan.corrections {
                total += 1
                let idx = WordAligner.disagreements(preview: p, final: f).first { $0.audioRange == item.audioRange }!.previewRange
                if item.replacement == truth[idx].joined(separator: " ") { correct += 1 }
            }
        }
        let precision = Double(correct) / Double(max(total, 1))
        #expect(disagreements > 500 && total > 300)
        #expect(precision >= 0.95, "precision \(precision) (\(correct)/\(total))")
    }
}
