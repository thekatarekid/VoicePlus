import AppKit
import Foundation
import Shared
import SwiftUI

// S5 — the correction popover (design §7 "Click uncertain word / Review", §8.8, prototype
// `#reviewDialog`): anchored to the word; at most three credible alternatives, the word itself to
// keep, Edit… for a spelling of one's own, "Remember this spelling in Dictionary" (unchecked); closes
// on Escape and gives focus back. It never edits anything itself: a decision goes to
// `WordCorrectionApplier`, which replaces only a range that still reads as landed (D10 otherwise).

/// What the user decided in the popover.
public enum WordReviewDecision: Equatable, Sendable {
    /// Replace the marked word with this spelling. `remember` adds it to the learned lexicon.
    case replace(String, remember: Bool)
    /// Keep the word as it is; its mark clears for this turn.
    case keep
    /// Closed (Escape, Cancel, ×): nothing changes.
    case dismiss
}

/// The popover as a value: copy, choices and the steps between them. Tests drive it without AppKit.
public struct CorrectionPopoverModel: Equatable, Sendable {
    /// Before insertion (the pill's final preview) or on the verified range in the destination.
    public enum Origin: String, Equatable, Sendable { case preview, destination }

    public enum Stage: Equatable, Sendable {
        /// Alternatives, Keep and Edit….
        case choosing
        /// The spelling field is open.
        case editing
        /// D10: the destination changed before the correction; nothing was replaced. `copied` once
        /// "Copy correction" put the spelling on the clipboard.
        case textChanged(replacement: String, copied: Bool)
    }

    // Copy (prototype `#reviewDialog`; design §7 ASCII; catalogue T05 / D10).
    public static let eyebrow = "Word review"
    public static let suggestionNote = "Suggested spelling, not certainty"
    public static let editLabel = "Edit…"
    public static let editPrompt = "Or enter a spelling"
    public static let editPlaceholder = "Your spelling"
    public static let useSpellingLabel = "Use spelling"
    public static let rememberLabel = "Remember this spelling in Dictionary"
    public static let cancelLabel = "Cancel"
    public static let closeLabel = "Close correction review"
    /// Before insertion a choice is applied to the verified range right after the text lands.
    public static let previewNote = "Your choice replaces the word once it is inserted, only if the text is unchanged."

    public var mark: UncertainMark
    public var origin: Origin
    public var confidenceAvailable: Bool
    public var stage: Stage = .choosing
    public var draft: String = ""
    /// "Remember this spelling in Dictionary" — unchecked unless the user ticks it.
    public var remember = false
    /// "2 of 3" when Review walks several marks.
    public var position: (index: Int, total: Int)?

    public init(mark: UncertainMark, origin: Origin, confidenceAvailable: Bool = true, position: (Int, Int)? = nil) {
        self.mark = mark
        self.origin = origin
        self.confidenceAvailable = confidenceAvailable
        self.position = position.map { (index: $0.0, total: $0.1) }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.mark == b.mark && a.origin == b.origin && a.confidenceAvailable == b.confidenceAvailable && a.stage == b.stage
            && a.draft == b.draft && a.remember == b.remember && a.position?.index == b.position?.index
            && a.position?.total == b.position?.total
    }

    /// ≤ 3 credible alternatives, best first.
    public var alternatives: [String] { Array(mark.alternatives.prefix(UncertaintyMarkMapper.maxAlternatives)) }

    public var isPhrase: Bool { mark.kind != .word }

    /// "Did you mean “Meera”?" · "Review “Mira”" · "Review this phrase" (T05) · "The text has changed" (D10).
    public var title: String {
        if case .textChanged = stage { return RecoveryCatalog.entry(.D10).headline }
        if isPhrase { return MarkCopy.reviewPhrase }
        if let top = alternatives.first { return "Did you mean “\(top)”?" }
        return "Review “\(mark.text)”"
    }

    /// "“Mira” was uncertain. Choose a spelling or keep what you said." — or T05's / D10's consequence,
    /// or "Confidence unavailable" when the result carried none (nothing is claimed as checked).
    public var detail: String {
        if case .textChanged = stage { return RecoveryCatalog.entry(.D10).consequence }
        if !confidenceAvailable { return MarkCopy.confidenceUnavailable }
        if isPhrase { return RecoveryCatalog.entry(.T05).consequence }
        return "“\(mark.text)” was uncertain. Choose a spelling or keep what you said."
    }

    /// "Mira · keep".
    public var keepLabel: String { "\(mark.text) · keep" }

    /// D10's one action.
    public var copyCorrectionLabel: String { RecoveryCatalog.entry(.D10).action }

    /// Remembering applies to one word's spelling.
    public var offersRemember: Bool { !isPhrase }

    public var positionLabel: String? {
        guard let p = position, p.total > 1 else { return nil }
        return "\(p.index) of \(p.total)"
    }

    /// VoiceOver for the popover as a whole.
    public var accessibilityLabel: String { "\(Self.eyebrow). \(title). \(detail)" }

    // MARK: Steps

    public func choose(_ alternative: String) -> WordReviewDecision {
        .replace(alternative, remember: remember && offersRemember)
    }

    public func keep() -> WordReviewDecision { .keep }

    public mutating func startEditing() {
        stage = .editing
        if draft.isEmpty { draft = mark.text }
    }

    /// "Use spelling": nil while the field is blank; the word itself counts as keeping it.
    public func submitEdit() -> WordReviewDecision? {
        let spelling = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty else { return nil }
        if spelling == mark.text { return .keep }
        return .replace(spelling, remember: remember && offersRemember)
    }

    /// Escape, Cancel or ×.
    public func dismiss() -> WordReviewDecision { .dismiss }

    /// D10: show the changed-text notice with "Copy correction".
    public mutating func textChanged(replacement: String) {
        stage = .textChanged(replacement: replacement, copied: false)
    }

    /// "Copy correction" was pressed; returns the text to put on the clipboard.
    public mutating func copyCorrection() -> String? {
        guard case .textChanged(let replacement, _) = stage else { return nil }
        stage = .textChanged(replacement: replacement, copied: true)
        return replacement
    }
}
