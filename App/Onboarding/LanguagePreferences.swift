import Carbon.HIToolbox
import Engine
import Foundation
import Pipeline

// V5 LANG1 — the languages the user speaks, the script each one is written in, and the English
// spelling variant. Asked once in onboarding (after Try dictation), stored in settings, and read by
// every consumer below. Nothing here guesses: an empty store means "not answered yet", and every
// consumer then behaves exactly as before LANG1 existed.

public extension SettingsKeys {
    /// Comma-separated base language codes in the user's order ("en,hi").
    static let languages = "lang.languages"
    /// `code=script` pairs, comma-separated ("hi=roman"); only languages with a script choice.
    static let scriptByLanguage = "lang.scriptByLanguage"
    /// "en-US" | "en-GB" | "en-IN".
    static let spellingVariant = "lang.spellingVariant"
}

/// English spelling variant (LANG1). Drives P-series dictionaries and the ITN locale (en-IN).
public enum SpellingVariant: String, CaseIterable, Sendable {
    case enUS = "en-US", enGB = "en-GB", enIN = "en-IN"

    public var title: String {
        switch self {
        case .enUS: return "American English"
        case .enGB: return "British English"
        case .enIN: return "Indian English"
        }
    }
}

/// One language row of the onboarding step (plain name, no flag).
public struct LanguageOption: Equatable, Identifiable, Sendable {
    public var code: String
    public var name: String
    public var id: String { code }
    /// Scripts the user may pick for it. One entry = no choice to make.
    public var scripts: [OutputScript]

    public init(code: String, name: String, scripts: [OutputScript] = [.roman]) {
        self.code = code; self.name = name; self.scripts = scripts
    }

    public var hasScriptChoice: Bool { scripts.count > 1 }
}

public struct LanguagePreferences: Equatable, Sendable {
    /// Base codes, in the user's order, no duplicates.
    public var languages: [String]
    public var scriptByLanguage: [String: OutputScript]
    public var spelling: SpellingVariant

    public init(languages: [String] = ["en"], scriptByLanguage: [String: OutputScript] = [:], spelling: SpellingVariant = .enUS) {
        var seen = Set<String>()
        self.languages = languages.map(Self.base).filter { !$0.isEmpty && seen.insert($0).inserted }
        self.scriptByLanguage = scriptByLanguage
        self.spelling = spelling
    }

    static func base(_ tag: String) -> String {
        tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    // MARK: The catalogue offered

    /// Hindi is the one language with a script choice today (Roman default; G3).
    public static let hindiScripts: [OutputScript] = [.roman, .devanagari, .mixed]

    /// Every language the step offers: English, Hindi, then Parakeet v3's languages by name.
    public static var catalogue: [LanguageOption] {
        var out = [LanguageOption(code: "en", name: "English"), LanguageOption(code: "hi", name: "Hindi", scripts: hindiScripts)]
        out += VoiceLanguage.parakeetV3.filter { $0.code != "en" }.sorted { $0.name < $1.name }
            .map { LanguageOption(code: $0.code, name: $0.name) }
        return out
    }

    public static func option(for code: String) -> LanguageOption {
        let c = base(code)
        if let known = catalogue.first(where: { $0.code == c }) { return known }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: c) ?? c
        return LanguageOption(code: c, name: name)
    }

    /// The script a language is written in: the stored choice, else Roman (owner decision).
    public func script(for code: String) -> OutputScript {
        let c = Self.base(code)
        guard Self.option(for: c).hasScriptChoice else { return .default }
        return scriptByLanguage[c] ?? .default
    }

    public var includesHindi: Bool { languages.contains("hi") }

    // MARK: Prefill

    /// From `Locale.preferredLanguages` and the enabled keyboard input sources, in that order.
    /// English is always offered first when nothing else is known.
    public static func prefill(preferredLanguages: [String], inputSourceLanguages: [String]) -> LanguagePreferences {
        var codes = (preferredLanguages + inputSourceLanguages).map(base).filter { !$0.isEmpty }
        if codes.isEmpty { codes = ["en"] }
        return LanguagePreferences(languages: codes, scriptByLanguage: [:],
                                   spelling: spellingVariant(preferredLanguages: preferredLanguages))
    }

    static func spellingVariant(preferredLanguages: [String]) -> SpellingVariant {
        for tag in preferredLanguages {
            let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.uppercased() }
            guard parts.first == "EN" else {
                if parts.first == "HI" { return .enIN }
                continue
            }
            if parts.contains("IN") { return .enIN }
            if parts.contains("GB") || parts.contains("AU") || parts.contains("NZ") || parts.contains("IE") { return .enGB }
            return .enUS
        }
        return .enUS
    }

    // MARK: Persistence

    /// Nil when LANG1 was never answered.
    public static func load(_ store: SettingsStore?) -> LanguagePreferences? {
        guard let raw = store?.string(SettingsKeys.languages), !raw.isEmpty else { return nil }
        var scripts: [String: OutputScript] = [:]
        for pair in (store?.string(SettingsKeys.scriptByLanguage) ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let s = OutputScript(rawValue: kv[1]) { scripts[base(kv[0])] = s }
        }
        let spelling = store?.string(SettingsKeys.spellingVariant).flatMap(SpellingVariant.init(rawValue:)) ?? .enUS
        return LanguagePreferences(languages: raw.split(separator: ",").map(String.init), scriptByLanguage: scripts, spelling: spelling)
    }

    public func save(to store: SettingsStore?) {
        guard let store else { return }
        store.set(languages.joined(separator: ","), for: SettingsKeys.languages)
        let pairs = scriptByLanguage.keys.sorted().compactMap { k in scriptByLanguage[k].map { "\(k)=\($0.rawValue)" } }
        store.set(pairs.joined(separator: ","), for: SettingsKeys.scriptByLanguage)
        store.set(spelling.rawValue, for: SettingsKeys.spellingVariant)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    public static let didChangeNotification = Notification.Name("VoicePlus.LanguagePreferences.didChange")

    // MARK: Consumers (LANG1 second bullet)

    /// `LanguageDetector` constraint: only the chosen languages are ever guessed.
    public var detectorConstraint: Set<SpokenLanguage>? { LanguageDetector.allowedLanguages(fromCodes: languages) }

    /// `Qwen3AsrLanguageHint`: one chosen language → named; several (code-switching) → automatic.
    public var qwenHint: Qwen3AsrLanguageHint {
        languages.count == 1 ? .named(languages[0]) : .automatic
    }

    /// D1's ITN locale.
    public var itnLocale: ITNLocale {
        ITNLocale.from(languages: languages, hindiScript: includesHindi ? script(for: "hi") : nil, spelling: spelling.rawValue)
    }

    /// The script a turn is written in when nothing overrides it, or nil when no chosen language
    /// has a script choice (the script stage then stays inert — pre-LANG behaviour).
    public var defaultTurnScript: OutputScript? { includesHindi ? script(for: "hi") : nil }

    /// Cleanup model choice: English-only users keep the English cleanup path; anything else goes
    /// to the multilingual local model (CU8's) once it is registered.
    public var isEnglishOnly: Bool { languages == ["en"] }

    /// Which ASR routes the chosen languages need — download only these (G1/G2 add the models).
    public enum ASRRoute: String, CaseIterable, Sendable {
        /// Parakeet TDT v3 — its 25 European languages (English included).
        case parakeetV3
        /// Hindi + English (G1: Srota / Nemotron-Hinglish, on demand).
        case hinglish
        /// Anything else (G2: Nemotron 3.5 multilingual, on demand).
        case multilingual

        /// The catalogue model behind the route; nil until G1/G2 land their catalogue entries.
        public var modelID: ModelID? { self == .parakeetV3 ? .parakeetTDTv3 : nil }
    }

    public var asrRoutes: [ASRRoute] {
        let parakeet = Set(VoiceLanguage.parakeetV3.map(\.code))
        var routes: [ASRRoute] = []
        if languages.contains(where: { parakeet.contains($0) }) || languages.isEmpty { routes.append(.parakeetV3) }
        if includesHindi { routes.append(.hinglish) }
        if languages.contains(where: { $0 != "hi" && !parakeet.contains($0) }) { routes.append(.multilingual) }
        return routes
    }
}

// MARK: - What this Mac says about languages

/// Prefill sources, behind a protocol so the step is testable without a Mac's settings.
public protocol LanguageEnvironment {
    var preferredLanguages: [String] { get }
    var inputSourceLanguages: [String] { get }
}

public struct LiveLanguageEnvironment: LanguageEnvironment {
    public init() {}
    public var preferredLanguages: [String] { Locale.preferredLanguages }

    /// Languages of the enabled keyboard input sources (TIS), first language of each.
    public var inputSourceLanguages: [String] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
            return langs?.first
        }
    }
}

public struct FixedLanguageEnvironment: LanguageEnvironment {
    public var preferredLanguages: [String]
    public var inputSourceLanguages: [String]
    public init(preferredLanguages: [String] = ["en-US"], inputSourceLanguages: [String] = []) {
        self.preferredLanguages = preferredLanguages; self.inputSourceLanguages = inputSourceLanguages
    }
}
