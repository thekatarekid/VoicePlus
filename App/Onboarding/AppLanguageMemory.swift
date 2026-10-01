import Engine
import Foundation
import NaturalLanguage

// V5 LANG1 — per-app language memory. A multilingual speaker writes Hindi in WhatsApp and English in
// Mail; once VoicePlus has heard it, a turn in that app is treated as that language: the ASR route
// prompts for it (G1/G2), ITN uses its locale (D1), and cleanup picks the matching model.
//
// Two sources, the user's first: a language pinned in Settings › Languages, else the language heard
// in at least `agreement` of the app's last `historyLength` turns. Only chosen languages count, and
// with one chosen language there is nothing to remember. Stored as strings in `SettingsStore`.

public extension SettingsKeys {
    /// `bundleID=code` pairs, comma-separated — languages the user pinned per app.
    static let languageByApp = "lang.languageByApp"
    /// `bundleID=code|code|…` pairs, comma-separated — the languages heard in the app's last turns.
    static let languageHistoryByApp = "lang.languageHistoryByApp"
}

public struct AppLanguageMemory {
    public static let historyLength = 5
    public static let agreement = 3

    public let store: SettingsStore?
    public init(store: SettingsStore?) { self.store = store }

    // MARK: Read

    public var pinned: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in Self.pairs(store?.string(SettingsKeys.languageByApp)) where !v.isEmpty { out[k] = v }
        return out
    }

    public var history: [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, v) in Self.pairs(store?.string(SettingsKeys.languageHistoryByApp)) {
            out[k] = v.split(separator: "|").map(String.init).filter { !$0.isEmpty }
        }
        return out
    }

    /// Apps with a pin or any history, sorted.
    public var apps: [String] { Set(pinned.keys).union(history.keys).sorted() }

    public func pinnedLanguage(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return pinned[bundleID]
    }

    /// The language heard in ≥ `agreement` of the app's last turns, or nil.
    public func learnedLanguage(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty, let recent = history[bundleID] else { return nil }
        var counts: [String: Int] = [:]
        for code in recent { counts[code, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              best.value >= Self.agreement else { return nil }
        return best.key
    }

    /// What a turn in `bundleID` is: the pin, else the learned language — only if still chosen.
    public func language(for bundleID: String?, chosen: [String]) -> String? {
        guard chosen.count > 1 else { return nil }
        let code = pinnedLanguage(for: bundleID) ?? learnedLanguage(for: bundleID)
        return code.flatMap { chosen.contains($0) ? $0 : nil }
    }

    // MARK: Write

    /// Pin `code` for the app; nil = automatic (learned).
    public func pin(_ code: String?, for bundleID: String) {
        guard Self.isStorable(bundleID) else { return }
        var map = pinned
        map[bundleID] = code.map(LanguagePreferences.base)
        write(map, key: SettingsKeys.languageByApp)
    }

    /// One turn in the app was heard as `code`.
    public func record(_ code: String, for bundleID: String?) {
        guard let bundleID, Self.isStorable(bundleID) else { return }
        var map = history
        var recent = map[bundleID] ?? []
        recent.append(LanguagePreferences.base(code))
        map[bundleID] = Array(recent.suffix(Self.historyLength))
        write(map.mapValues { $0.joined(separator: "|") }, key: SettingsKeys.languageHistoryByApp)
    }

    /// Drops the app's pin and history.
    public func forget(_ bundleID: String) {
        var p = pinned; p[bundleID] = nil
        write(p, key: SettingsKeys.languageByApp)
        var h = history; h[bundleID] = nil
        write(h.mapValues { $0.joined(separator: "|") }, key: SettingsKeys.languageHistoryByApp)
    }

    // MARK: Storage

    static func isStorable(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && !bundleID.contains(",") && !bundleID.contains("=") && !bundleID.contains("|")
    }

    static func pairs(_ raw: String?) -> [(String, String)] {
        (raw ?? "").split(separator: ",").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 && !kv[0].isEmpty ? (kv[0], kv[1]) : nil
        }
    }

    private func write(_ map: [String: String], key: String) {
        store?.set(map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: ","), for: key)
    }
}

// MARK: - Which chosen language a turn was in

public enum TurnLanguageClassifier {
    /// Fewer words than this say too little to remember.
    public static let minimumWords = 3

    /// The chosen language `text` is in, or nil (one language chosen, too short, or unsure).
    /// Hindi (romanised, Devanagari or mixed with English) is "hi" — the Hinglish route serves it.
    public static func classify(_ text: String, chosen: [String]) -> String? {
        guard chosen.count > 1 else { return nil }
        guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return nil }
        if chosen.contains("hi") {
            let detection = LanguageDetector.detect(text, allowed: LanguageDetector.allowedLanguages(fromCodes: chosen))
            switch detection.language {
            case .hindi, .mixed: return "hi"
            case .english: break
            case .unknown: return nil
            }
        }
        let latin = chosen.filter { $0 != "hi" }
        if latin.count == 1 { return latin[0] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = latin.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        let code = LanguagePreferences.base(best.key.rawValue)
        return latin.contains(code) ? code : nil
    }
}

public extension LanguagePreferences {
    /// The answers narrowed to one language a turn is known to be in. Hindi keeps English beside it
    /// (Hinglish); scripts and spelling are kept.
    func narrowed(to code: String) -> LanguagePreferences {
        let c = Self.base(code)
        guard languages.contains(c) else { return self }
        let langs = c == "hi" && languages.contains("en") ? ["hi", "en"] : [c]
        return LanguagePreferences(languages: langs, scriptByLanguage: scriptByLanguage, spelling: spelling)
    }
}
