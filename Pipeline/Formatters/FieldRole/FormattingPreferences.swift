import Foundation
import Shared

/// D6 (V4.17) — the user's spacing choice: what goes between the text already in the field and
/// the dictation. Settings → General renders it (S7g); `App` writes it into the run's
/// `StageContext` under `FieldContext.Keys.spacing`.
public enum SpacingPreference: String, Codable, Sendable, CaseIterable, Equatable {
    /// The continuation table decides (D3): a space after a word, none after a space, none at an
    /// unknown caret.
    case automatic
    /// Always start with a space, unless the text before the caret is known to be empty or to end
    /// in whitespace already (a doubled space helps nobody).
    case always
    /// Never add a space on either side of the dictation.
    case never
}

/// D3 (V4.2) — how text lands when the caret could not be read (`CaretState.unknown`).
public enum UnknownCaretStyle: String, Codable, Sendable, CaseIterable, Equatable {
    /// Default. An utterance of three or more words keeps the recogniser's own capital and
    /// period (it is probably a sentence); one or two words lose them (probably a fragment
    /// dropped into the middle of something).
    case sentence
    /// Exactly as spoken: no capital and no period that the user did not dictate, whatever the
    /// length. Spoken punctuation ("full stop") is still kept.
    case asSpoken
}

/// The two formatting settings the continuation planner reads, as one value.
public struct FormattingPreferences: Sendable, Equatable {
    public var spacing: SpacingPreference
    public var unknownCaretStyle: UnknownCaretStyle

    public init(spacing: SpacingPreference = .automatic, unknownCaretStyle: UnknownCaretStyle = .sentence) {
        self.spacing = spacing
        self.unknownCaretStyle = unknownCaretStyle
    }

    public static let `default` = FormattingPreferences()
}
