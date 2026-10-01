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
/// - per turn (`languageContext`): the app's remembered language (`AppLanguageMemory`) and the
///   language heard in this turn narrow the turn's languages → ITN locale, cleanup model
///   (`LanguageCleanup.swift`); the heard language is recorded for the app;
/// - the P-series word lists per language (`LanguageDictionaryPlan`).
///
/// With LANG1 unanswered nothing changes: no locale override, no constraint, the script stage inert.
public final class LanguageRuntime: @unchecked Sendable {
    public let settings: SettingsStore?
    public let scriptChoice: ScriptChoiceModel
    private let environment: [String: String]
    private let lock = NSLock()
    private var constraint: Set<SpokenLanguage>?
    private var cleanupChoice: CleanupModelChoice?
    private var dictionaryPlan: LanguageDictionaryPlan?
    private let dictionaryQueue = DispatchQueue(label: "voiceplus.lang.dictionaries", qos: .utility)
    /// Only the shipped app (a `.app` bundle) rewrites the process-wide word lists; a test runner
    /// never does (other suites read them in parallel).
    public var appliesDictionaries = Bundle.main.bundlePath.hasSuffix(".app")
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
            Self.isHindiWordForScript(word, constraint: self?.currentConstraint)
        }
        apply()
        observer = NotificationCenter.default.addObserver(forName: LanguagePreferences.didChangeNotification,
                                                          object: nil, queue: nil) { [weak self] _ in self?.apply() }
    }

    /// The script stage's word test. The constraint may only switch Hindi *off* (Hindi not chosen →
    /// no Latin word is Hindi). It never makes every Latin word Hindi when English was not chosen:
    /// a Hindi-only speaker still says English words, and Mixed must keep them Latin (G3) — the
    /// word's own lexical test decides.
    public static func isHindiWordForScript(_ word: String, constraint: Set<SpokenLanguage>?) -> Bool {
        if let constraint, !constraint.contains(.hindi) { return false }
        return LanguageDetector.isHindiWord(word, allowed: nil)
    }

    public var currentConstraint: Set<SpokenLanguage>? { lock.lock(); defer { lock.unlock() }; return constraint }

    public func apply() {
        let prefs = LanguagePreferences.load(settings)
        lock.lock(); constraint = prefs?.detectorConstraint; lock.unlock()
        if let locale = Self.itnLocale(prefs, environment: environment) { ITNStage.defaultLocale = locale }
        onConstraintChange?(prefs?.detectorConstraint)
        applyDictionaries(prefs)
        // G1/G2 — the engine may have been built before the answers were readable.
        LanguageASRRouting.shared.fetchNeededModels()
    }

    /// The LANG1 ITN locale, or nil when unanswered or pinned by `VOICEPLUS_ITN_LOCALE`.
    public static func itnLocale(_ prefs: LanguagePreferences?, environment: [String: String]) -> ITNLocale? {
        guard let prefs, environment["VOICEPLUS_ITN_LOCALE"]?.isEmpty ?? true else { return nil }
        return prefs.itnLocale
    }

    /// Chains the turn's languages and script onto an existing context augmenter.
    public func augmenter(after base: (([TranscriptSpan], StageContext) -> StageContext)?) -> ([TranscriptSpan], StageContext) -> StageContext {
        { [weak self, scriptChoice] spans, ctx in
            let ctx = base?(spans, ctx) ?? ctx
            return scriptChoice.augment(self?.languageContext(spans, ctx) ?? ctx)
        }
    }

    // MARK: Per turn (per-app memory, cleanup model, ITN locale)

    /// The cleanup model the current turn asked for (nil = LANG1 unanswered → English path).
    public var turnCleanupChoice: CleanupModelChoice? { lock.lock(); defer { lock.unlock() }; return cleanupChoice }

    /// Writes the turn's languages into the context and learns the app's language.
    public func languageContext(_ spans: [TranscriptSpan], _ ctx: StageContext) -> StageContext {
        guard let prefs = LanguagePreferences.load(settings) else {
            lock.lock(); cleanupChoice = nil; lock.unlock()
            return ctx
        }
        let memory = AppLanguageMemory(store: settings)
        let appLanguage = memory.language(for: ctx.appBundleID, chosen: prefs.languages)
        let heard = TurnLanguageClassifier.classify(spans.map(\.text).joined(separator: " "), chosen: prefs.languages)
        if let heard { memory.record(heard, for: ctx.appBundleID) }
        let turnLanguage = heard ?? appLanguage
        let turn = turnLanguage.map(prefs.narrowed(to:)) ?? prefs
        var ctx = ctx
        ctx.extra[LanguageTurnKeys.languages] = turn.languages.joined(separator: ",")
        if let appLanguage { ctx.extra[LanguageTurnKeys.appLanguage] = appLanguage }
        if turnLanguage != nil, ctx.extra[ITNStage.Keys.locale] == nil,
           let locale = Self.itnLocale(turn, environment: environment) {
            ctx.extra[ITNStage.Keys.locale] = locale.rawValue
        }
        let choice = prefs.cleanupModel(turnLanguage: turnLanguage)
        ctx.extra[LanguageTurnKeys.cleanupModel] = choice.rawValue
        lock.lock(); cleanupChoice = choice; lock.unlock()
        return ctx
    }

    // MARK: P-series per language

    /// Re-applies the word lists when the plan changed (off the main thread: it reads files).
    func applyDictionaries(_ prefs: LanguagePreferences?) {
        guard appliesDictionaries, let prefs else { return }
        let plan = LanguageDictionaryPlan(prefs)
        lock.lock(); let changed = plan != dictionaryPlan; dictionaryPlan = plan; lock.unlock()
        guard changed else { return }
        dictionaryQueue.async { plan.apply() }
    }

    /// Re-applies the current plan (a variant list was just downloaded).
    public func reapplyDictionaries() {
        lock.lock(); dictionaryPlan = nil; lock.unlock()
        applyDictionaries(LanguagePreferences.load(settings))
    }
}
