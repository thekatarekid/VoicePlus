import Foundation
import Shared

/// V5 P1–P7 — the process-wide public dictionaries the dictionary stages read by default.
///
/// Rule (V5 §P): public lists fix casing/formatting of words already recognised; they never feed
/// decode-time boosting. Every list is local: bundled (casing), the user's own (Text
/// Replacements), the OS's (`/usr/share/dict/words`), or a public list the user chose to download
/// into `~/Library/Application Support/VoicePlus/Dictionaries/` (`PublicDictionaryCatalog`).
///
/// Defaults are inert until the app opts in: the Text Replacements source starts empty so a test
/// process never expands the developer's own shortcuts; the app calls `useSystemTextReplacements()`
/// at launch. Casing and the vocabulary load lazily on first use.
public final class PublicDictionaries: @unchecked Sendable {
    public static let shared = PublicDictionaries()

    private let lock = NSLock()
    private var replacements: any TextReplacementSource = StaticTextReplacements()
    private var casingOverride: CasingLexicon?
    private var vocabularyOverride: WordVocabulary?
    private lazy var casingDefault: CasingLexicon = CasingLexicon.installed()
    private lazy var vocabularyDefault: WordVocabulary = WordVocabulary.installed()

    public init() {}

    /// Indirection so a stage built before configuration still sees the configured source.
    public var textReplacementSource: any TextReplacementSource { ConfiguredReplacements(owner: self) }

    public func setTextReplacements(_ source: any TextReplacementSource) { lock.withLock { replacements = source } }
    /// P1 — expand the user's macOS Text Replacements from now on. Call on the main thread.
    public func useSystemTextReplacements() {
        SystemTextReplacements.shared.refresh()
        setTextReplacements(SystemTextReplacements.shared)
    }

    public var casing: CasingLexicon {
        lock.withLock { casingOverride ?? casingDefault }
    }
    public func setCasing(_ lexicon: CasingLexicon?) { lock.withLock { casingOverride = lexicon } }

    public var vocabulary: WordVocabulary {
        lock.withLock { vocabularyOverride ?? vocabularyDefault }
    }
    public func setVocabulary(_ vocabulary: WordVocabulary?) { lock.withLock { vocabularyOverride = vocabulary } }

    fileprivate func currentReplacements() -> [String: String] {
        lock.withLock { replacements }.replacements()
    }

    /// `~/Library/Application Support/VoicePlus/Dictionaries/` — downloaded public lists.
    public static func directory() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Dictionaries", isDirectory: true)
    }
}

private struct ConfiguredReplacements: TextReplacementSource {
    let owner: PublicDictionaries
    func replacements() -> [String: String] { owner.currentReplacements() }
}

// MARK: - Catalog + notices

/// One public list: where it comes from, its licence, and whether it ships in the app.
public struct PublicDictionaryEntry: Sendable, Equatable, Identifiable {
    public enum Delivery: String, Sendable, Equatable {
        /// Compiled into the app (small).
        case bundled
        /// Read from the OS at runtime (nothing shipped).
        case system
        /// Downloaded on the user's request into `PublicDictionaries.directory()`.
        case download
        /// A model that is not converted / not shipped yet (see notes).
        case unavailable
    }

    public let id: String
    public let item: String
    public let title: String
    public let licence: String
    public let attribution: String
    public let source: String
    public let delivery: Delivery
    /// For `.download`: the URL fetched and the file name it is stored under.
    public let downloadURL: URL?
    public let fileName: String?
    public let approximateBytes: Int

    public var localURL: URL? { fileName.map { PublicDictionaries.directory().appendingPathComponent($0) } }
    public var isInstalled: Bool {
        switch delivery {
        case .bundled: return true
        case .system: return FileManager.default.fileExists(atPath: source)
        case .download: return localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        case .unavailable: return false
        }
    }
}

/// The lists P1–P7 use, with the licence notice each one requires. `notices` is the text the app
/// shows under Settings › Dictionary › Public word lists (and what `Notices` carries).
public enum PublicDictionaryCatalog {
    public static let textReplacements = PublicDictionaryEntry(
        id: "macos-text-replacements", item: "P1", title: "macOS Text Replacements",
        licence: "Your data", attribution: "Read from System Settings › Keyboard › Text Replacements; never copied or synced.",
        source: "NSSpellChecker.userReplacementsDictionary", delivery: .system, downloadURL: nil, fileName: nil,
        approximateBytes: 0)

    public static let casing = PublicDictionaryEntry(
        id: "casing", item: "P3", title: "Brand and tech casing",
        licence: "CC0-1.0 (Wikidata); Homebrew cask metadata BSD-2-Clause",
        attribution: "Names from Wikidata (CC0) and Homebrew casks, filtered against English words. Generated offline by Fixtures/dictionaries/generate_casing.py.",
        source: "Fixtures/dictionaries/casing.txt", delivery: .bundled, downloadURL: nil, fileName: nil,
        approximateBytes: 120_000)

    public static let cmudict = PublicDictionaryEntry(
        id: "cmudict", item: "P4", title: "CMU Pronouncing Dictionary",
        licence: "BSD-2-Clause",
        attribution: "Copyright (c) 1993-2015 Carnegie Mellon University. All rights reserved. Redistribution and use in source and binary forms, with or without modification, are permitted provided the copyright notice, this list of conditions and the disclaimer are retained.",
        source: "https://github.com/cmusphinx/cmudict", delivery: .download,
        downloadURL: URL(string: "https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict"),
        fileName: "cmudict.dict", approximateBytes: 3_618_488)

    public static let scowl = PublicDictionaryEntry(
        id: "scowl", item: "P5", title: "SCOWL / ESDB English word list (size 50)",
        licence: "SCOWL licence (permissive, notice required)",
        attribution: "Copyright 2000-2026 by Kevin Atkinson. Permission to use, copy, modify, distribute, and sell any part of the English Speller Database (ESDB, previously known as SCOWLv2), or word lists created from it, is hereby granted without fee, provided that the above copyright notice appears in all copies and that both the above copyright notice and this notice appear in supporting documentation. Kevin Atkinson makes no representations about the suitability of this database for any purpose. It is provided \"as is\" without express or implied warranty.",
        source: "https://wordlist.aspell.net", delivery: .download,
        downloadURL: URL(string: "https://app.aspell.net/create?max_size=50&spelling=US&max_variant=0&diacritic=strip&special=hacker&download=wordlist&encoding=utf-8&format=inline"),
        fileName: "scowl-en-50.txt", approximateBytes: 815_819)

    public static let systemWords = PublicDictionaryEntry(
        id: "system-words", item: "P5", title: "macOS word list (Webster's Second, public domain)",
        licence: "Public domain", attribution: "/usr/share/dict/words, shipped with macOS.",
        source: "/usr/share/dict/words", delivery: .system, downloadURL: nil, fileName: nil, approximateBytes: 0)

    public static let indicXlit = PublicDictionaryEntry(
        id: "indicxlit", item: "P6", title: "IndicXlit transliteration (AI4Bharat)",
        licence: "MIT",
        attribution: "Copyright (c) AI4Bharat. IndicXlit models are MIT licensed. Not shipped yet: the fairseq checkpoints need a Core ML conversion; a rule-based Devanagari transliterator is used meanwhile.",
        source: "https://github.com/AI4Bharat/IndicXlit", delivery: .unavailable, downloadURL: nil, fileName: nil,
        approximateBytes: 0)

    public static let gliner2 = PublicDictionaryEntry(
        id: "gliner2-small", item: "P7", title: "GLiNER2 small (Core ML, FluidUse)",
        licence: "Apache-2.0",
        attribution: "GLiNER2 by Fastino; Core ML conversion by FluidInference (FluidInference/gliner2-5-small-coreml), used through FluidUse (Apache-2.0).",
        source: "https://huggingface.co/FluidInference/gliner2-5-small-coreml", delivery: .unavailable,
        downloadURL: nil, fileName: nil, approximateBytes: 0)

    public static let all: [PublicDictionaryEntry] = [textReplacements, casing, cmudict, scowl, systemWords, indicXlit, gliner2]

    /// Licence notices, one block per third-party list.
    public static var notices: String {
        all.filter { $0.licence != "Your data" }.map { entry in
            "\(entry.title) — \(entry.licence)\n\(entry.source)\n\(entry.attribution)"
        }.joined(separator: "\n\n")
    }
}

/// Downloads a `.download` catalog entry into `PublicDictionaries.directory()`. Only ever called on
/// an explicit user action; nothing in the pipeline fetches.
public enum PublicDictionaryFetcher {
    public enum FetchError: Error, Equatable { case notDownloadable, badStatus(Int), tooLarge(Int) }

    /// Hard cap: these are word lists, not models.
    public static let maxBytes = 16 * 1024 * 1024

    public static func fetch(_ entry: PublicDictionaryEntry, session: URLSession = .shared) async throws -> URL {
        guard entry.delivery == .download, let url = entry.downloadURL, let destination = entry.localURL else {
            throw FetchError.notDownloadable
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        guard data.count <= maxBytes else { throw FetchError.tooLarge(data.count) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
