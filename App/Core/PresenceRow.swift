import CoreGraphics
import Foundation

/// P5 fix — how the presence indicator's expanded row decides *what* to say and *how wide to be*.
///
/// The bug this replaces: the row was a fixed 190 pt panel rendering
/// `Text(...).lineLimit(1).truncationMode(.tail)`, so "VoicePlus · Ready — hold Right ⌃" came out as
/// "VoicePlus · Ready — hold R…" and never became readable — the panel never grew, so there was no
/// state in which the user could see the end of the sentence.
///
/// The rule now: **the panel is sized to its text**, clamped to the display. Only when a message
/// genuinely cannot fit the display does it shorten — and it shortens by dropping whole components
/// ("hold Right ⌃", then the "VoicePlus · " prefix, then whole trailing words), never by cutting a
/// word in half. `PresenceRowTests` asserts the "no dangling mid-word ellipsis" property directly.
public enum PresenceRow {
    /// Leading + trailing padding inside the row.
    public static let horizontalPadding: CGFloat = 20
    /// The status glyph plus the gap after it.
    public static let iconWidth: CGFloat = 20
    /// Narrowest a row is ever drawn: below this it reads as a blob rather than a message.
    public static let minWidth: CGFloat = 120

    /// Prefix the state sentences share. Stripping it is the first thing that goes when space is
    /// short — the user knows which app the thing under their notch belongs to.
    static let brandPrefix = "VoicePlus · "

    public struct Fit: Equatable, Sendable {
        /// The text that should actually be drawn.
        public var text: String
        /// Panel width needed to draw it in full (already clamped to `maxWidth`).
        public var width: CGFloat
        /// True only when even the shortest whole-word form had to lose words.
        public var truncated: Bool

        public init(text: String, width: CGFloat, truncated: Bool) {
            self.text = text
            self.width = width
            self.truncated = truncated
        }
    }

    /// The hotkey hint belongs on the states where pressing the key would actually do something.
    /// Telling someone to "hold Right ⌃" while the mic is denied or the model is still downloading
    /// is advice that does not work.
    public static func hint(_ hint: String, for state: PresenceState) -> String {
        switch state {
        case .ready, .paused: return hint
        case .off, .listening, .processing, .muted, .blocked: return ""
        }
    }

    /// Progressively shorter renderings of the same message, most complete first.
    public static func candidates(detail: String, hint: String) -> [String] {
        let detail = detail.trimmingCharacters(in: .whitespaces)
        let hint = hint.trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        if !hint.isEmpty { out.append("\(detail) — \(hint)") }
        out.append(detail)
        if detail.hasPrefix(brandPrefix) { out.append(String(detail.dropFirst(brandPrefix.count))) }
        // A short hint on its own still tells the user what to press, which beats a bare glyph.
        if !hint.isEmpty { out.append(hint) }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Pick the longest candidate that fits `maxWidth`, and report the width the panel needs.
    /// `measure` returns the drawn width of a string in points (injected so this stays pure and
    /// testable with no font stack and no window server).
    public static func fit(detail: String, hint: String, maxWidth: CGFloat,
                           measure: (String) -> CGFloat) -> Fit {
        let chrome = iconWidth + horizontalPadding
        let textBudget = max(24, maxWidth - chrome)
        let options = candidates(detail: detail, hint: hint)

        for text in options where measure(text) <= textBudget {
            let width = min(maxWidth, max(minWidth, measure(text) + chrome))
            return Fit(text: text, width: width, truncated: false)
        }

        // Nothing fits whole. Drop trailing *words* from the shortest candidate — never characters,
        // so the result is never a half-word plus an ellipsis.
        let shortest = options.last ?? detail
        let clipped = dropTrailingWords(shortest, toFit: textBudget, measure: measure)
        return Fit(text: clipped, width: min(maxWidth, max(minWidth, measure(clipped) + chrome)),
                   truncated: clipped != shortest)
    }

    /// Removes whole trailing words until the string (plus an ellipsis) fits. If even the first word
    /// overflows, the first word is returned bare — a readable word beats a truncated one.
    static func dropTrailingWords(_ text: String, toFit budget: CGFloat, measure: (String) -> CGFloat) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return words.first ?? text }
        var count = words.count - 1
        while count >= 1 {
            let head = words.prefix(count).joined(separator: " ")
            // Some sentences already end in an ellipsis ("VoicePlus · Working…"); don't double it.
            let candidate = head.hasSuffix("…") ? head : head + "…"
            if measure(candidate) <= budget { return candidate }
            count -= 1
        }
        return words[0]
    }
}

/// Where "hold Right ⌃" / "press ⌃⌥D" comes from. Derived from the *configured* binding — the
/// dictation key is user-settable, so the hint must never be a hardcoded "Right Control".
public enum HotkeyHint {
    /// A bare modifier is held down for the length of the utterance; a chord is pressed once.
    public static func label(for kind: HotkeyBinding.Kind) -> String {
        switch kind.style {
        case .bareModifier: return "hold \(kind.displayName)"
        case .chord: return "press \(kind.displayName)"
        }
    }

    /// Used when the binding cannot be read at all (hotkey service not up yet).
    public static let unknown = "the dictation key"
}
