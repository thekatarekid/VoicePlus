import Foundation
import CoreGraphics

/// One thing the user can pick. `ring` is drawn by the overlay (P3.2 pulse) in Cocoa global coords.
public struct ElicitationCandidate: Equatable, Sendable {
    public var id: String
    public var label: String
    public var ring: CGRect
    public var displayID: UInt32
    public init(id: String, label: String, ring: CGRect, displayID: UInt32) { self.id = id; self.label = label; self.ring = ring; self.displayID = displayID }

    public static func from(_ ref: ScreenReference, id: String) -> ElicitationCandidate {
        ElicitationCandidate(id: id, label: ref.label, ring: ref.bounds.insetBy(dx: -6, dy: -6), displayID: ref.displayID)
    }
}

/// What the overlay/pill should show while a question is open.
public struct ElicitationPrompt: Equatable, Sendable {
    public var question: String
    public var phrase: String
    public var candidates: [ElicitationCandidate]
    public var deadline: TimelineInstant
}

public enum ElicitationState: Equatable, Sendable {
    case idle
    case prompting(ElicitationPrompt)
    case resolved(ElicitationCandidate, prompt: ElicitationPrompt)
    /// Nobody answered in time: the pill shows `clarifyingText` instead.
    case timedOut(clarifyingText: String, prompt: ElicitationPrompt)
    case cancelled
}

public enum ElicitationEvent: Equatable, Sendable {
    case ask(phrase: String, candidates: [ElicitationCandidate], now: TimelineInstant)
    case point(GlobalPoint, now: TimelineInstant)
    case speech(String, now: TimelineInstant)
    case tick(now: TimelineInstant)
    case cancel
}

/// Reverse elicitation: ring the candidates, ask "which one?", accept a point or a spoken answer,
/// fall back to clarifying text on timeout. Pure state machine; the overlay and pill observe `state`.
public struct ReverseElicitation: Equatable, Sendable {
    public var timeout: TimeInterval
    /// A point within this many points of a ring counts as choosing it.
    public var pointSlack: CGFloat
    public private(set) var state: ElicitationState = .idle

    public init(timeout: TimeInterval = 4, pointSlack: CGFloat = 24) { self.timeout = timeout; self.pointSlack = pointSlack }

    /// Whether a binding needs a question at all.
    public static func needsElicitation(_ b: DeixisBinding) -> Bool { b.isAmbiguous && b.candidates.count >= 2 }

    @discardableResult
    public mutating func handle(_ event: ElicitationEvent) -> ElicitationState {
        switch (state, event) {
        case (_, .ask(let phrase, let cands, let now)):
            let shown = Array(cands.prefix(4))
            state = shown.count >= 2
                ? .prompting(ElicitationPrompt(question: "which one?", phrase: phrase, candidates: shown, deadline: now + timeout))
                : (shown.first.map { .resolved($0, prompt: ElicitationPrompt(question: "", phrase: phrase, candidates: shown, deadline: now)) } ?? .idle)
        case (.prompting(let p), .point(let g, let now)):
            if now > p.deadline { state = timedOut(p) }
            else if let c = p.candidates.filter({ $0.displayID == g.displayID })
                .min(by: { Self.distance(g.cgPoint, $0.ring) < Self.distance(g.cgPoint, $1.ring) }),
                Self.distance(g.cgPoint, c.ring) <= pointSlack { state = .resolved(c, prompt: p) }
        case (.prompting(let p), .speech(let s, let now)):
            if now > p.deadline { state = timedOut(p) }
            else if let c = Self.match(s, in: p.candidates) { state = .resolved(c, prompt: p) }
        case (.prompting(let p), .tick(let now)):
            if now > p.deadline { state = timedOut(p) }
        case (_, .cancel):
            state = .cancelled
        default: break
        }
        return state
    }

    private func timedOut(_ p: ElicitationPrompt) -> ElicitationState {
        .timedOut(clarifyingText: Self.clarifyingText(for: p), prompt: p)
    }

    public static func clarifyingText(for p: ElicitationPrompt) -> String {
        let names = p.candidates.map { "“\($0.label)”" }
        let list = names.count == 2 ? names.joined(separator: " or ") : names.dropLast().joined(separator: ", ") + ", or " + names.last!
        return "Which one did you mean by “\(p.phrase)”: \(list)?"
    }

    /// Spoken answer: label words, ordinals ("the first/second"), or relative position ("the left one", "top").
    static func match(_ speech: String, in cands: [ElicitationCandidate]) -> ElicitationCandidate? {
        let s = speech.lowercased()
        let words = Set(s.split { !$0.isLetter }.map(String.init))
        let ordinals = ["first": 0, "second": 1, "third": 2, "fourth": 3]
        if let (_, i) = ordinals.first(where: { words.contains($0.key) }), i < cands.count { return cands[i] }
        if words.contains("left") { return cands.min { $0.ring.midX < $1.ring.midX } }
        if words.contains("right") { return cands.max { $0.ring.midX < $1.ring.midX } }
        if words.contains("top") || words.contains("upper") { return cands.max { $0.ring.midY < $1.ring.midY } }
        if words.contains("bottom") || words.contains("lower") { return cands.min { $0.ring.midY < $1.ring.midY } }
        let scored = cands.map { c -> (ElicitationCandidate, Int) in
            let lw = c.label.lowercased().split { !$0.isLetter }.map(String.init)
            return (c, lw.filter { words.contains($0) }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, scored.count == 1 || scored[1].1 < best.1 else { return nil }
        return best.0
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}
