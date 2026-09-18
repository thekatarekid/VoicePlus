import Foundation
import CoreGraphics
import Shared

public struct DeixisLexicon: Sendable {
    public static let `default` = DeixisLexicon(words: [
        "this": .proximal, "these": .proximal, "here": .locative,
        "that": .distal, "those": .distal, "there": .locative,
    ])
    public var words: [String: DeicticKind]
    public init(words: [String: DeicticKind]) { self.words = words }

    public func kind(of text: String) -> DeicticKind? {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return words[t]
    }
}

public struct DeixisConfig: Sendable {
    /// How far from the word's audio midpoint a pointer sample may be.
    public var pointerTolerance: TimeInterval = 0.35
    /// Half-window around the word in which a stroke counts as "drawn for this word".
    public var strokeWindow: TimeInterval = 0.6
    /// Near-miss radius (points) when the pointer is not inside any element.
    public var nearMissRadius: CGFloat = 40
    /// Two candidates whose distance scores differ by less than this are ambiguous.
    public var ambiguityDelta: CGFloat = 12
    /// Lead: speakers typically point slightly *before* the word; shift lookup earlier by this.
    public var gestureLead: TimeInterval = 0.08
    public init() {}
}

/// Binds deictic words to what the pointer/ink was on when the word was spoken.
public final class DeixisResolver {
    public let lexicon: DeixisLexicon
    public let config: DeixisConfig
    private let hitTester: AXHitTesting

    public init(hitTester: AXHitTesting, lexicon: DeixisLexicon = .default, config: DeixisConfig = DeixisConfig()) {
        self.hitTester = hitTester; self.lexicon = lexicon; self.config = config
    }

    public func resolve(spans: [TranscriptSpan], alignment: CaptureAlignment, timeline: InputTimeline) -> [DeixisBinding] {
        spans.enumerated().compactMap { i, s in
            guard let kind = lexicon.kind(of: s.text) else { return nil }
            return bind(word: s.text, kind: kind, index: i, audioRange: s.audioRange, alignment: alignment, timeline: timeline)
        }
    }

    public func bind(word: String, kind: DeicticKind, index: Int, audioRange: ClosedRange<TimeInterval>,
                     alignment: CaptureAlignment, timeline: InputTimeline) -> DeixisBinding {
        let mid = (audioRange.lowerBound + audioRange.upperBound) / 2
        let t = alignment.instant(forAudioSeconds: mid) - config.gestureLead
        var b = DeixisBinding(word: word, kind: kind, spanIndex: index, audioRange: audioRange, instant: t,
                              anchor: nil, reference: nil, candidates: [], confidence: 0, isAmbiguous: false)

        // 1. A box wins (G1): the one drawn nearest the word, inside ±strokeWindow. Several boxes
        //    in one utterance each bind their own word.
        let window = (t - config.strokeWindow)...(t + config.strokeWindow)
        if let box = timeline.regions(in: window).min(by: { $0.distance(to: t) < $1.distance(to: t) }) {
            let region = Self.region(from: box.sample, hitTester: hitTester)
            b.reference = .region(region); b.candidates = [.region(region)]; b.confidence = 0.9
            b.anchor = GlobalPoint(x: region.centroid.x, y: region.centroid.y, displayID: region.displayID)
            return b
        }

        // 1b. Legacy ink: a free-hand stroke bundle around the word (replayed timelines).
        let strokes = timeline.strokes(in: window)
        if let region = Self.region(from: strokes, hitTester: hitTester) {
            b.reference = .region(region); b.candidates = [.region(region)]; b.confidence = 0.9
            b.anchor = GlobalPoint(x: region.centroid.x, y: region.centroid.y, displayID: region.displayID)
            return b
        }

        // 2. Pointer position → AX hit-test.
        guard let p = timeline.pointer(at: t, tolerance: config.pointerTolerance) else { return b }
        b.anchor = p
        if let e = hitTester.element(at: p) {
            b.reference = .element(e); b.candidates = [.element(e)]; b.confidence = 0.85
            return b
        }

        // 3. Near miss: rank by distance; two close scores ⇒ ambiguous.
        let r = config.nearMissRadius
        let near = hitTester.elements(intersecting: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), displayID: p.displayID)
        let ranked = near.map { ($0, Self.distance(from: p.cgPoint, to: $0.frame)) }.sorted { $0.1 < $1.1 }
        b.candidates = ranked.map { .element($0.0) }
        guard let best = ranked.first else { return b }
        b.isAmbiguous = ranked.count > 1 && (ranked[1].1 - best.1) < config.ambiguityDelta
        b.reference = b.isAmbiguous ? nil : .element(best.0)
        b.confidence = b.isAmbiguous ? 0.4 : Float(max(0.2, 0.7 - Double(best.1 / r) * 0.3))
        return b
    }

    static func region(from strokes: [UUID: [TimelineEvent]], hitTester: AXHitTesting) -> RegionReference? {
        let pts = strokes.values.flatMap { $0 }.compactMap { $0.kind.point }
        guard !pts.isEmpty else { return nil }
        // Bundle on the display holding most points (a stroke never spans displays in practice).
        let display = Dictionary(grouping: pts, by: \.displayID).max { $0.value.count < $1.value.count }!.key
        let on = pts.filter { $0.displayID == display }
        let xs = on.map(\.x), ys = on.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let c = CGPoint(x: xs.reduce(0, +) / CGFloat(on.count), y: ys.reduce(0, +) / CGFloat(on.count))
        let els = coveredElements(bounds: bounds, centroid: c, displayID: display, hitTester: hitTester)
        return RegionReference(bounds: bounds, centroid: c, displayID: display, strokeIDs: Array(strokes.keys), elements: els)
    }

    /// A drawn box as a region reference, with the elements it covers.
    public static func region(from box: RegionSample, hitTester: AXHitTesting) -> RegionReference {
        let c = CGPoint(x: box.rect.midX, y: box.rect.midY)
        let els = coveredElements(bounds: box.rect, centroid: c, displayID: box.displayID, hitTester: hitTester)
        return RegionReference(bounds: box.rect, centroid: c, displayID: box.displayID, elements: els, regionID: box.regionID)
    }

    /// Elements mostly (≥ 50 %) inside `bounds`, smallest first; else the element under the
    /// centroid; else whatever the bounds touch.
    public static func coveredElements(bounds: CGRect, centroid c: CGPoint, displayID display: UInt32,
                                       hitTester: AXHitTesting) -> [ElementReference] {
        var els = hitTester.elements(intersecting: bounds, displayID: display)
        let inside = els.filter { $0.frame.intersection(bounds).width * $0.frame.intersection(bounds).height >= 0.5 * $0.area }
        if !inside.isEmpty { els = inside }
        else if let e = hitTester.element(at: GlobalPoint(x: c.x, y: c.y, displayID: display)) { els = [e] }
        return els.sorted { $0.area < $1.area }
    }

    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}

public extension DeixisBinding {
    /// Compact context line for the pipeline/LLM prompt, e.g. `this = button "Send" @display 1`.
    var contextLine: String {
        guard let ref = reference else { return isAmbiguous ? "\(word) = ? (\(candidates.count) candidates)" : "\(word) = unresolved" }
        return "\(word) = \(ref.label) @display \(ref.displayID)"
    }
}
