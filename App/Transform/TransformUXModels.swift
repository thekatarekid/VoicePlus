import Foundation
import Pipeline
import Shared

/// P2.3 — inline morph: the old text collapses (deleted words shrink out) for half a beat, then
/// the new text expands (inserted words grow in). One beat ≈ 320 ms, driven by `WordDiff`.
public struct MorphAnimationModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case collapse, expand, settled }
    public struct Token: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case kept, removed, added }
        public var id: Int
        public var text: String
        public var kind: Kind
    }
    public static let beat: TimeInterval = 0.32

    public var tokens: [Token]
    public var beat: TimeInterval

    public init(diff: WordDiff, beat: TimeInterval = MorphAnimationModel.beat) {
        var out: [Token] = []
        for (i, op) in diff.ops.enumerated() {
            switch op {
            case .equal(let t): out.append(Token(id: i, text: t, kind: .kept))
            case .delete(let t): out.append(Token(id: i, text: t, kind: .removed))
            case .insert(let t): out.append(Token(id: i, text: t, kind: .added))
            }
        }
        tokens = out
        self.beat = beat
    }

    public var isIdentity: Bool { tokens.allSatisfy { $0.kind == .kept } }
    public var changedCount: Int { tokens.filter { $0.kind != .kept }.count }

    public func phase(at elapsed: TimeInterval) -> Phase {
        if elapsed < beat / 2 { return .collapse }
        if elapsed < beat { return .expand }
        return .settled
    }

    /// Scale (0…1) of a token at `elapsed`: removed words collapse to 0 in the first half,
    /// added words expand from 0 in the second half, kept words stay at 1.
    public func scale(of token: Token, at elapsed: TimeInterval) -> Double {
        let half = beat / 2
        switch token.kind {
        case .kept: return 1
        case .removed: return max(0, 1 - min(elapsed, half) / half)
        case .added: return elapsed < half ? 0 : min(1, (elapsed - half) / half)
        }
    }

    /// Tokens visible at `elapsed` (removed ones vanish once collapsed, added ones appear as they expand).
    public func visibleText(at elapsed: TimeInterval) -> String {
        tokens.filter { scale(of: $0, at: elapsed) > 0 }.map(\.text).joined(separator: " ")
    }
}

/// The 5 s "↩ / try again" ghost under the pill after a rewrite lands.
public struct TransformGhost: Equatable, Sendable {
    public static let lifetime: TimeInterval = 5
    public enum Action: Equatable, Sendable { case undo, tryAgain }
    public var instruction: String
    public var before: String
    public var after: String
    public var shownAt: Date
    public var lifetime: TimeInterval

    public init(instruction: String, before: String, after: String, shownAt: Date, lifetime: TimeInterval = TransformGhost.lifetime) {
        self.instruction = instruction; self.before = before; self.after = after; self.shownAt = shownAt; self.lifetime = lifetime
    }
    public func isAlive(at now: Date) -> Bool { now.timeIntervalSince(shownAt) < lifetime }
    public func remaining(at now: Date) -> TimeInterval { max(0, lifetime - now.timeIntervalSince(shownAt)) }
    public var undoLabel: String { "↩ undo" }
    public var tryAgainLabel: String { "try again" }
}

/// Pure reducer for the transform pill (P2.3): editing → done(+ghost) → warm(8 s) → hidden.
/// The warm window is `TransformSession.warmWindow`; the ghost is `TransformGhost.lifetime`.
public struct TransformPillReducer: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case began(words: Int)
        case applied(instruction: String, before: String, after: String, diff: WordDiff)
        case noChange
        case failed(String)
        case undone
        case tick
        case ended
    }
    public var warmWindow: TimeInterval
    public var ghostLifetime: TimeInterval
    public private(set) var state: PillState = .hidden
    public private(set) var ghost: TransformGhost?
    public private(set) var morph: MorphAnimationModel?
    private var words = 0
    private var warmSince: Date?

    public init(warmWindow: TimeInterval = 8, ghostLifetime: TimeInterval = TransformGhost.lifetime) {
        self.warmWindow = warmWindow; self.ghostLifetime = ghostLifetime
    }

    public var isWarm: Bool { warmSince != nil }

    @discardableResult
    public mutating func reduce(_ event: Event, now: Date) -> PillState {
        switch event {
        case .began(let n):
            words = n; ghost = nil; morph = nil; warmSince = nil
            state = .transform(.init(editingWords: n, stage: .editing))
        case .applied(let instruction, let before, let after, let diff):
            let m = MorphAnimationModel(diff: diff)
            morph = m
            ghost = TransformGhost(instruction: instruction, before: before, after: after, shownAt: now, lifetime: ghostLifetime)
            warmSince = now
            words = after.split(whereSeparator: { $0.isWhitespace }).count
            state = .transform(.init(editingWords: words, stage: .done(changed: m.changedCount)))
        case .noChange:
            warmSince = now; ghost = nil
            state = .transform(.init(editingWords: words, stage: .notice("no change")))
        case .failed(let why):
            warmSince = now; ghost = nil
            state = .transform(.init(editingWords: words, stage: .notice(why)))
        case .undone:
            ghost = nil; morph = nil; warmSince = now
            state = .transform(.init(editingWords: words, stage: .notice("put back")))
        case .tick:
            guard let since = warmSince else { break }
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= warmWindow { warmSince = nil; ghost = nil; state = .hidden; break }
            if let g = ghost, !g.isAlive(at: now) { ghost = nil }
            if ghost == nil, case .transform(let info) = state, info.stage != .editing {
                if case .notice = info.stage, elapsed < 1.2 { break }
                state = .transform(.init(editingWords: words, stage: .warm(remaining: Int((warmWindow - elapsed).rounded(.up)))))
            }
        case .ended:
            warmSince = nil; ghost = nil; morph = nil
            state = .hidden
        }
        return state
    }
}
