import Engine
import Foundation
import Pipeline

// V5 LANG1 — the P-series word lists, per chosen language:
// - P5 vocabulary follows the English spelling variant: SCOWL in American spelling for en-US, British
//   (-ise) for en-GB and en-IN. The variant list is downloaded only on a click (Settings › Languages);
//   until then the P5 default (US SCOWL if downloaded, else the macOS list) stays.
// - P3 casing, with Hindi chosen, never re-cases a romanised Hindi word (a brand whose lowercase is
//   "kya…"/"…hai" stays a Hindi word).
// - P6 transliteration runs only when Hindi is written in Devanagari or Mixed (LANG2/G3 stage).
// - P1 Text Replacements and P2 local names are the user's own and apply in every language.
// With LANG1 unanswered the plan is the pre-LANG behaviour and `apply` changes nothing.

/// One SCOWL spelling variant (P5).
public struct ScowlVariant: Equatable, Sendable {
    /// SCOWL's `spelling=` parameter: "US" or "GBs".
    public let spelling: String
    public let title: String

    public static let us = ScowlVariant(spelling: "US", title: "American spelling")
    public static let gbs = ScowlVariant(spelling: "GBs", title: "British spelling (-ise)")

    public static func forSpelling(_ variant: SpellingVariant) -> ScowlVariant { variant == .enUS ? .us : .gbs }

    /// US is P5's own catalogue entry; the others are stored beside it.
    public var fileName: String {
        spelling == "US" ? (PublicDictionaryCatalog.scowl.fileName ?? "scowl-en-50.txt") : "scowl-en-50-\(spelling).txt"
    }

    public var localURL: URL { PublicDictionaries.directory().appendingPathComponent(fileName) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    public var downloadURL: URL {
        let base = PublicDictionaryCatalog.scowl.downloadURL?.absoluteString ?? ""
        return URL(string: base.replacingOccurrences(of: "spelling=US", with: "spelling=\(spelling)"))!
    }

    /// The user's click only (same cap as `PublicDictionaryFetcher`).
    public func download(session: URLSession = .shared) async throws {
        let (data, response) = try await session.data(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PublicDictionaryFetcher.FetchError.badStatus(http.statusCode)
        }
        guard data.count <= PublicDictionaryFetcher.maxBytes else { throw PublicDictionaryFetcher.FetchError.tooLarge(data.count) }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
    }
}

public struct LanguageDictionaryPlan: Equatable, Sendable {
    public var scowl: ScowlVariant
    /// English is one of the chosen languages (P3–P5 are English lists).
    public var englishLists: Bool
    /// Hindi chosen: P3 casing skips romanised Hindi words.
    public var hindiSafeCasing: Bool
    /// P6 transliteration (Hindi in Devanagari or Mixed).
    public var transliteration: Bool

    public init(_ prefs: LanguagePreferences?) {
        scowl = ScowlVariant.forSpelling(prefs?.spelling ?? .enUS)
        englishLists = prefs.map { $0.languages.contains("en") } ?? true
        hindiSafeCasing = prefs?.includesHindi ?? false
        transliteration = prefs.map { $0.includesHindi && $0.script(for: "hi") != .roman } ?? false
    }

    /// The casing lexicon without romanised Hindi keys.
    public static func hindiSafe(_ lexicon: CasingLexicon) -> CasingLexicon {
        CasingLexicon(lexicon.canonical.filter { !LanguageDetector.isRomanHindi($0.key) }.map(\.value).sorted())
    }

    /// Installs the plan into the process-wide dictionaries. Reads files: call off the main thread.
    /// Only overrides this plan set are ever cleared, so a list the Dictionary page installed stays.
    public func apply(to dictionaries: PublicDictionaries = .shared) {
        let owned = Self.owned.withLock { $0[ObjectIdentifier(dictionaries)] ?? [] }
        var now: Set<String> = []
        if hindiSafeCasing {
            dictionaries.setCasing(Self.hindiSafe(CasingLexicon.installed())); now.insert("casing")
        } else if owned.contains("casing") {
            dictionaries.setCasing(nil)
        }
        if scowl != .us, scowl.isInstalled, let text = try? String(contentsOf: scowl.localURL, encoding: .utf8),
           case let vocabulary = WordVocabulary(listText: text), vocabulary.count > 1_000 {
            dictionaries.setVocabulary(vocabulary); now.insert("vocabulary")
        } else if owned.contains("vocabulary") {
            dictionaries.setVocabulary(WordVocabulary.installed())
        }
        Self.owned.withLock { $0[ObjectIdentifier(dictionaries)] = now }
    }

    private static let owned = LanguagePlanBox<[ObjectIdentifier: Set<String>]>([:])

    /// Settings › Languages lines: (list, what it does for these languages).
    public var lines: [(title: String, detail: String)] {
        var out: [(String, String)] = [
            ("Text Replacements and names", "Your macOS Text Replacements, contacts and app names — in every language."),
        ]
        if englishLists {
            out.append(("English word list", scowl.title + (scowl.isInstalled || scowl == .us ? "" : " — not downloaded yet")))
            out.append(("Brand and tech casing", hindiSafeCasing ? "Never changes a Hindi word." : "Fixes the case of names like GitHub."))
        } else {
            out.append(("Brand and tech casing", "Fixes the case of names like GitHub."))
        }
        if transliteration { out.append(("Hindi transliteration", "Writes Hindi in Devanagari where you chose it.")) }
        return out
    }

}

/// A tiny lock-guarded value.
final class LanguagePlanBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
