import Engine
import Foundation
import Shared

/// P6.3 integration — code-switching at the composition root: `ScriptAwareMerger` turns the
/// final spans into one script-aware string (Devanagari + Latin in a single utterance),
/// `LanguageDetector` + `ScriptIndicatorModel` drive the pill's script badge, and the
/// `CodeSwitchRouter` (built in `EngineFactory`) reports whether an Indic re-decode would be
/// used. No language toggle anywhere.
public final class CodeSwitchService: @unchecked Sendable {
    public let merger = ScriptAwareMerger()
    /// Rebuilt with the engine: a container that came up without a speech model has no router until
    /// one is downloaded (`AppContainer.refreshEngineIfNeeded()`).
    public private(set) var router: CodeSwitchRouter?
    public private(set) var indicator = ScriptIndicatorModel()
    /// Pill badge: "" | "EN" | "हि" | "EN·हि".
    public var onIndicatorChange: ((String) -> Void)?
    public private(set) var lastSegments: ScriptSegments?
    private var detector = LanguageDetector()
    private let lock = NSLock()

    public init(router: CodeSwitchRouter? = nil) { self.router = router }

    /// V5 LANG1 — the badge's detector guesses only the chosen languages (nil = unconstrained).
    public func setAllowedLanguages(_ allowed: Set<SpokenLanguage>?) {
        lock.lock(); defer { lock.unlock() }
        detector = LanguageDetector(allowed: allowed)
    }

    public func setRouter(_ router: CodeSwitchRouter?) {
        lock.lock(); defer { lock.unlock() }
        self.router = router
    }

    /// `UtteranceLander.textFinalizer` — returns the merged script-aware string for
    /// code-switched utterances (nil keeps the default joined text), updating the indicator
    /// either way.
    public func finalize(_ spans: [TranscriptSpan]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let segments = merger.merge(spans)
        lastSegments = segments
        detector.reset()
        detector.feed(segments.text)
        indicator.update(with: segments)
        onIndicatorChange?(indicator.label)
        return segments.isCodeSwitched ? segments.text : nil
    }

    /// Streaming preview keeps the badge live while speaking.
    public func preview(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        indicator.update(with: detector.feed(text))
        onIndicatorChange?(indicator.label)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        detector.reset()
        indicator.reset()
        onIndicatorChange?(indicator.label)
    }
}
