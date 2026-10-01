import Engine
import Foundation
import Pipeline
import Shared

/// V5 LANG1 + LANG2 — the LANG answers reach their consumers. Installed once from the composition
/// root and re-applied whenever `LanguagePreferences.didChangeNotification` posts:
/// - D1 ITN locale (`ITNStage.defaultLocale`) — unless `VOICEPLUS_ITN_LOCALE` pins it;
/// - the code-switch detector, constrained to the chosen languages;
/// - `ScriptOutputStage`'s romanised-Hindi word test (Engine's detector, same constraint);
/// - the turn's output script (`ScriptChoiceModel.augment`) on the lander's context chain.
///
/// With LANG1 unanswered nothing changes: no locale override, no constraint, the script stage inert.
public final class LanguageRuntime: @unchecked Sendable {
    public let settings: SettingsStore?
    public let scriptChoice: ScriptChoiceModel
    private let environment: [String: String]
    private let lock = NSLock()
    private var constraint: Set<SpokenLanguage>?
    private var observer: NSObjectProtocol?
    /// Called with the new constraint (the code-switch service's detector).
    public var onConstraintChange: ((Set<SpokenLanguage>?) -> Void)?

    public init(settings: SettingsStore?, environment: [String: String] = ProcessInfo.processInfo.environment,
                scriptChoice: ScriptChoiceModel? = nil) {
        self.settings = settings
        self.environment = environment
        self.scriptChoice = scriptChoice ?? ScriptChoiceModel(settings: settings)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The app's one runtime, kept alive here (set by `wire`).
    public private(set) static var current: LanguageRuntime?

    /// Composition-root hook: LANG consumers + the notch script menu + the lander's context chain.
    public static func wire(settings: SettingsStore, lander: UtteranceLander, codeSwitch: CodeSwitchService,
                            pill: PillViewModel) {
        let runtime = LanguageRuntime(settings: settings)
        runtime.onConstraintChange = { [weak codeSwitch] in codeSwitch?.setAllowedLanguages($0) }
        runtime.install()
        lander.contextAugmenter = runtime.augmenter(after: lander.contextAugmenter)
        pill.scriptMenu = runtime.scriptChoice
        current = runtime
    }

    /// Applies the stored answers now and on every later change.
    public func install() {
        ScriptOutputStage.hindiWordClassifier = { [weak self] word in
            LanguageDetector.isHindiWord(word, allowed: self?.currentConstraint)
        }
        apply()
        observer = NotificationCenter.default.addObserver(forName: LanguagePreferences.didChangeNotification,
                                                          object: nil, queue: nil) { [weak self] _ in self?.apply() }
    }

    public var currentConstraint: Set<SpokenLanguage>? { lock.lock(); defer { lock.unlock() }; return constraint }

    public func apply() {
        let prefs = LanguagePreferences.load(settings)
        lock.lock(); constraint = prefs?.detectorConstraint; lock.unlock()
        if let locale = Self.itnLocale(prefs, environment: environment) { ITNStage.defaultLocale = locale }
        onConstraintChange?(prefs?.detectorConstraint)
    }

    /// The LANG1 ITN locale, or nil when unanswered or pinned by `VOICEPLUS_ITN_LOCALE`.
    public static func itnLocale(_ prefs: LanguagePreferences?, environment: [String: String]) -> ITNLocale? {
        guard let prefs, environment["VOICEPLUS_ITN_LOCALE"]?.isEmpty ?? true else { return nil }
        return prefs.itnLocale
    }

    /// Chains the turn's script onto an existing context augmenter.
    public func augmenter(after base: (([TranscriptSpan], StageContext) -> StageContext)?) -> ([TranscriptSpan], StageContext) -> StageContext {
        { [scriptChoice] spans, ctx in scriptChoice.augment(base?(spans, ctx) ?? ctx) }
    }
}
