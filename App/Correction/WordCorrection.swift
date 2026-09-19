import AppKit
import Engine
import Foundation
import Injection
import Shared

// S5 — applying a word correction (design §7, §8.8; catalogue D10). A replacement goes in only if the
// marked range still reads exactly as it landed (`ReplaceRange`); otherwise nothing is touched, the
// user sees "The text has changed — Your correction has not replaced anything." and can copy the
// correction instead. "Remember this spelling" is a separate, explicit option that feeds the learned
// lexicon; nothing else does.

/// Replaces a range of the destination field only if it still reads `expected`.
public protocol MarkTextEditing: AnyObject {
    func replace(range: Range<Int>, expected: String, with replacement: String) -> ReplaceRangeOutcome
}

public protocol CorrectionClipboard: AnyObject {
    func copy(_ text: String)
}

/// The learned lexicon, fed only by "Remember this spelling in Dictionary".
public protocol SpellingMemory: AnyObject {
    func remember(heard: String, spelling: String, audioRange: ClosedRange<TimeInterval>)
}

/// What a decision did.
public enum WordCorrectionResult: Equatable, Sendable {
    /// The replacement is in the verified range; the mark is gone.
    case replaced(verified: Bool)
    /// The word stays; its mark is gone for this turn.
    case kept
    /// Nothing happened.
    case dismissed
    /// D10: the range no longer reads as landed. Nothing was replaced; the correction can be copied.
    case textChanged(replacement: String)

    public var recovery: RecoveryEntry? {
        if case .textChanged = self { return RecoveryCatalog.entry(.D10) }
        return nil
    }
}

public final class WordCorrectionApplier {
    public let editor: MarkTextEditing
    public var spelling: SpellingMemory?

    public init(editor: MarkTextEditing, spelling: SpellingMemory? = nil) {
        self.editor = editor
        self.spelling = spelling
    }

    /// Carries out `decision` for `mark` of `session`. A remembered spelling is saved whatever the
    /// destination did — it is the user's explicit choice about the dictionary, not about this field.
    @discardableResult
    public func apply(_ decision: WordReviewDecision, mark: UncertainMark, in session: DestinationMarkSession,
                      audioRange: ClosedRange<TimeInterval> = 0...0) -> WordCorrectionResult {
        switch decision {
        case .dismiss:
            return .dismissed
        case .keep:
            session.kept(mark.id)
            return .kept
        case .replace(let replacement, let remember):
            if remember { spelling?.remember(heard: mark.heard.isEmpty ? mark.text : mark.heard, spelling: replacement, audioRange: audioRange) }
            guard let current = session.marks.first(where: { $0.id == mark.id }) else { return .textChanged(replacement: replacement) }
            let outcome = editor.replace(range: session.fieldRange(of: current), expected: current.text, with: replacement)
            switch outcome {
            case .replaced(let verified):
                session.corrected(current.id, with: replacement)
                return .replaced(verified: verified)
            case .mismatch, .unavailable:
                // D10 — "invalidate stale range": the overlay goes; the marks stay in Review / Today.
                session.clear(.textChanged)
                return .textChanged(replacement: replacement)
            }
        }
    }
}

/// Choices made in the pill's final preview, before anything was inserted. The payload is immutable
/// (S3), so a chosen spelling is applied to the verified range right after the text lands — through
/// the same range guard as any correction — and a kept word just loses its mark.
public struct StagedCorrections: Equatable, Sendable {
    public private(set) var replacements: [Int: (String, Bool)] = [:]
    public private(set) var kept: Set<Int> = []

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.kept == b.kept && a.replacements.keys == b.replacements.keys
            && a.replacements.allSatisfy { k, v in b.replacements[k].map { $0.0 == v.0 && $0.1 == v.1 } ?? false }
    }

    public var isEmpty: Bool { replacements.isEmpty && kept.isEmpty }
    /// Marks the preview no longer draws.
    public var resolved: Set<Int> { kept.union(replacements.keys) }

    public mutating func record(_ decision: WordReviewDecision, for markID: Int) {
        switch decision {
        case .replace(let text, let remember):
            replacements[markID] = (text, remember)
            kept.remove(markID)
        case .keep:
            kept.insert(markID)
            replacements[markID] = nil
        case .dismiss:
            break
        }
    }

    /// The decisions to apply once the text landed, in mark order.
    public var decisions: [(Int, WordReviewDecision)] {
        let replaced = replacements.map { ($0.key, WordReviewDecision.replace($0.value.0, remember: $0.value.1)) }
        return (replaced + kept.map { ($0, WordReviewDecision.keep) }).sorted { $0.0 < $1.0 }
    }
}

// MARK: - Live implementations

/// `ReplaceRangeEditor` over the live `SystemAccess`, but only while the field the text landed in is
/// still the focused one (element identity from the landing's focus snapshot).
public final class FocusedFieldMarkEditor: MarkTextEditing {
    private let system: SystemAccess
    private let editor: ReplaceRangeEditor
    private let expected: FocusSnapshot?

    public init(system: SystemAccess, landedIn focus: FocusSnapshot?) {
        self.system = system
        self.editor = ReplaceRangeEditor(system: system)
        self.expected = focus
    }

    public func replace(range: Range<Int>, expected text: String, with replacement: String) -> ReplaceRangeOutcome {
        if let expected, let now = system.frontmostApp() {
            guard now.bundleID == expected.bundleID, now.pid == expected.pid else {
                return .unavailable(reason: "destination app changed")
            }
            if let token = expected.elementToken, let current = now.elementToken, token != current {
                return .unavailable(reason: "focused field changed")
            }
        }
        return editor.replace(ReplaceRangeRequest(range: range, expected: text, replacement: replacement))
    }
}

public final class PasteboardCorrectionClipboard: CorrectionClipboard {
    public init() {}
    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Remember this spelling": one `CorrectionRecord` into the correction log the app already fans out
/// to history and the adaptation loop (`AdaptationService.ingest` → learned lexicon variants).
public final class CorrectionLogSpellingMemory: SpellingMemory {
    public static let source = "wordReview"
    private let sink: CorrectionSink

    public init(sink: CorrectionSink) { self.sink = sink }

    public func remember(heard: String, spelling: String, audioRange: ClosedRange<TimeInterval>) {
        let original = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !corrected.isEmpty, original != corrected else { return }
        sink.record(CorrectionRecord(utteranceID: "wordReview:\(UUID().uuidString)", original: original, corrected: corrected,
                                     audioRange: audioRange, source: Self.source))
    }
}
