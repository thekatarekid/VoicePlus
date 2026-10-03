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
///
/// S12 — between editing and done sits the edited preview (R1): the morph shows the before → after
/// diff, no ghost (nothing is written, so there is nothing to undo), no warm countdown. `done` and
/// its ghost (R2, "Updated · Undo") only follow a replacement that was actually written.
public struct TransformPillReducer: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case began(words: Int)
        /// S12 — R1's edited final preview; the original is still unchanged.
        case previewing(instruction: String, before: String, after: String, diff: WordDiff)
        case applied(instruction: String, before: String, after: String, diff: WordDiff)
        case noChange
        case failed(String)
        /// S12 — the preview was cancelled; nothing was replaced.
        case cancelled
        /// S12 — the target changed before the replacement; the edit went to the held-text row.
        case held(reason: String)
        /// S12 — undo was refused (window over, or the edited range changed); `line` says which.
        case undoRefused(String)
        case undone
        /// H6 — the notch asks for something ("Say the new text") and waits up to the warm window.
        case prompt(String)
        /// H7 — a closing notice for a command that edits nothing ("Copied", "Nothing to undo").
        case notice(String)
        /// H8 / X5 — an LLM command with no model: `line` ("Needs the on-device model · Saved to
        /// Notes"); `offerDownload` puts the one-time Download button on the row (ModelOfferPolicy).
        case needsModel(line: String, offerDownload: Bool)
        case tick
        case ended
    }
    /// How long a closing notice (cancelled, undo refused) stays before the pill retracts.
    public static let closingNotice: TimeInterval = 1.2

    public var warmWindow: TimeInterval
    public var ghostLifetime: TimeInterval
    public private(set) var state: PillState = .hidden
    public private(set) var ghost: TransformGhost?
    public private(set) var morph: MorphAnimationModel?
    private var words = 0
    private var warmSince: Date?
    private var hideAt: Date?

    public init(warmWindow: TimeInterval = 8, ghostLifetime: TimeInterval = TransformGhost.lifetime) {
        self.warmWindow = warmWindow; self.ghostLifetime = ghostLifetime
    }

    public var isWarm: Bool { warmSince != nil }
    /// Something is timed: the warm window, or a closing notice waiting to retract.
    public var needsTicks: Bool { warmSince != nil || hideAt != nil }
    /// S12 — the edit is running or its preview is showing: nothing has been written, so Escape
    /// keeps the original (R1 "Esc"). False from the first outcome on.
    public private(set) var awaitsDecision = false
    /// S12 — the edited preview is on the row; hover on the pill freezes its dwell.
    public private(set) var isPreviewing = false
    /// H8 / X5 — the row offers "Download" (the one-time notch offer). Cleared by any other event.
    public private(set) var offersDownload = false
    /// How long the needs-model row stays: long enough to read, longer with the Download button.
    public static let needsModelNotice: TimeInterval = 4
    public static let downloadOfferNotice: TimeInterval = 10

    @discardableResult
    public mutating func reduce(_ event: Event, now: Date) -> PillState {
        if event != .tick { hideAt = nil; awaitsDecision = false; isPreviewing = false; offersDownload = false }
        switch event {
        case .began(let n):
            words = n; ghost = nil; morph = nil; warmSince = nil
            awaitsDecision = true
            state = .transform(.init(editingWords: n, stage: .editing))
        case .previewing(let instruction, let before, let after, let diff):
            let preview = TransformPreview(instruction: instruction, before: before, after: after)
            morph = MorphAnimationModel(diff: diff)
            ghost = nil; warmSince = nil
            awaitsDecision = true; isPreviewing = true
            words = preview.wordCount
            state = .transform(.init(editingWords: words, stage: .notice(TransformPreviewCopy.compactLine(preview))))
        case .cancelled:
            ghost = nil; morph = nil; warmSince = nil; hideAt = now + Self.closingNotice
            state = .transform(.init(editingWords: words, stage: .notice(TransformPreviewCopy.cancelledLine)))
        case .held:
            warmSince = nil; ghost = nil; morph = nil
            state = .hidden
        case .undoRefused(let line):
            ghost = nil; morph = nil; warmSince = nil; hideAt = now + Self.closingNotice
            state = .transform(.init(editingWords: words, stage: .notice(line)))
        case .applied(let instruction, let before, let after, let diff):
            let m = MorphAnimationModel(diff: diff)
            morph = m
            ghost = TransformGhost(instruction: instruction, before: before, after: after, shownAt: now, lifetime: ghostLifetime)
            warmSince = now
            words = after.split(whereSeparator: { $0.isWhitespace }).count
            state = .transform(.init(editingWords: words, stage: .done(changed: m.changedCount)))
        case .noChange:
            // H9 — "say more" (the warm row) only after an applied edit; this notice just closes.
            warmSince = nil; ghost = nil; morph = nil; hideAt = now + Self.closingNotice
            state = .transform(.init(editingWords: words, stage: .notice("no change")))
        case .failed(let why):
            warmSince = nil; ghost = nil; morph = nil; hideAt = now + Self.closingNotice
            state = .transform(.init(editingWords: words, stage: .notice(why)))
        case .prompt(let line):
            warmSince = nil; ghost = nil; morph = nil; hideAt = now + warmWindow
            state = .transform(.init(editingWords: words, stage: .notice(line)))
        case .notice(let line):
            ghost = nil; morph = nil; warmSince = nil; hideAt = now + Self.closingNotice
            state = .transform(.init(editingWords: words, stage: .notice(line)))
        case .needsModel(let line, let offer):
            ghost = nil; morph = nil; warmSince = nil
            offersDownload = offer
            hideAt = now + (offer ? Self.downloadOfferNotice : Self.needsModelNotice)
            state = .transform(.init(editingWords: words, stage: .notice(line)))
        case .undone:
            ghost = nil; morph = nil; warmSince = now
            state = .transform(.init(editingWords: words, stage: .notice("put back")))
        case .tick:
            if let end = hideAt {
                if now >= end { hideAt = nil; offersDownload = false; state = .hidden }
                break
            }
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
