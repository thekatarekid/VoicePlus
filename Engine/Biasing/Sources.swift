import Foundation

// MARK: - AX tree (focused window)

/// Visible strings of the focused window. Live impl reads AXUIElement; tests use the mock.
public protocol FocusedWindowTextProvider: Sendable {
    /// Returns (string, salience). Title/headers should carry higher salience than body text.
    func visibleStrings() -> [(String, Double)]
}

public struct MockFocusedWindowText: FocusedWindowTextProvider {
    public var strings: [(String, Double)]
    public init(_ strings: [(String, Double)]) { self.strings = strings }
    public init(_ plain: [String]) { self.strings = plain.map { ($0, 1.0) } }
    public func visibleStrings() -> [(String, Double)] { strings }
}

public struct AXTreeSource: ContextSource {
    public let kind = ContextSourceKind.axTree
    public var provider: FocusedWindowTextProvider
    public init(provider: FocusedWindowTextProvider) { self.provider = provider }

    public func harvest(now: Date) -> [ContextEntry] {
        var out: [ContextEntry] = []
        for (s, sal) in provider.visibleStrings() {
            for (term, strength) in EntityExtractor.extractWeighted(from: s) {
                out.append(ContextEntry(text: term, source: .axTree, observedAt: now, salience: sal * strength))
            }
        }
        return out
    }
}

// MARK: - Recent words ring (10 min)

/// Thread-safe ring of recently dictated/typed words with a sliding time window.
public final class RecentWordsRing: ContextSource, @unchecked Sendable {
    public let kind = ContextSourceKind.recentWords
    public let window: TimeInterval
    public let capacity: Int
    private let lock = NSLock()
    private var buffer: [(word: String, at: Date)] = []

    public init(window: TimeInterval = 600, capacity: Int = 4_000) {
        self.window = window
        self.capacity = capacity
    }

    public func record(_ text: String, at: Date = Date()) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { w -> String in
            var s = String(w)
            while let l = s.last, ".,;:!?\"".contains(l) { s.removeLast() }
            return s
        }.filter { $0.count >= 2 }
        lock.lock(); defer { lock.unlock() }
        buffer.append(contentsOf: words.map { ($0, at) })
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }

    public func harvest(now: Date) -> [ContextEntry] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        buffer.removeAll { $0.at < cutoff }
        var latest: [String: Date] = [:]
        for (w, at) in buffer where EntityExtractor.isEntityLike(w) || w.count >= 4 {
            if let d = latest[w], d >= at { continue }
            latest[w] = at
        }
        return latest.map { ContextEntry(text: $0.key, source: .recentWords, observedAt: $0.value, salience: 0.6) }
    }
}

// MARK: - Corrections + dictionary (AppDatabase behind a protocol)

/// Abstracts `AppDatabase` so the harvester is testable without GRDB.
public protocol CorrectionStore: Sendable {
    /// Corrected forms with when they were made.
    func correctedTerms() throws -> [(term: String, at: Date)]
    /// Dictionary terms with their weight (0…∞; ≥1 typical).
    func dictionaryTerms() throws -> [(term: String, weight: Double)]
    /// N1 — Dictionary rows with their real origin (personal / contacts / imported / earlier).
    func dictionaryEntries() throws -> [DictionaryEntry]
}

extension CorrectionStore {
    /// A store that records no origins: every row counts as typed by the user.
    public func dictionaryEntries() throws -> [DictionaryEntry] {
        try dictionaryTerms().map { DictionaryEntry(term: $0.term, weight: $0.weight, origin: .personal) }
    }
}

public struct MockCorrectionStore: CorrectionStore {
    public var corrections: [(term: String, at: Date)]
    public var dictionary: [(term: String, weight: Double)]
    /// N1 — rows with an explicit origin (e.g. Contacts imports), after `dictionary`'s personal rows.
    public var entries: [DictionaryEntry]
    public init(corrections: [(term: String, at: Date)] = [], dictionary: [(term: String, weight: Double)] = [],
                entries: [DictionaryEntry] = []) {
        self.corrections = corrections
        self.dictionary = dictionary
        self.entries = entries
    }
    public func correctedTerms() throws -> [(term: String, at: Date)] { corrections }
    public func dictionaryTerms() throws -> [(term: String, weight: Double)] {
        dictionary + entries.map { (term: $0.term, weight: $0.weight) }
    }
    public func dictionaryEntries() throws -> [DictionaryEntry] {
        dictionary.map { DictionaryEntry(term: $0.term, weight: $0.weight, origin: .personal) } + entries
    }
}

public struct CorrectionSource: ContextSource {
    public let kind = ContextSourceKind.corrections
    public var store: CorrectionStore
    public init(store: CorrectionStore) { self.store = store }

    public func harvest(now: Date) -> [ContextEntry] {
        var out: [ContextEntry] = []
        for c in (try? store.correctedTerms()) ?? [] {
            for w in c.term.split(separator: " ") where w.count >= 2 {
                out.append(ContextEntry(text: String(w), source: .corrections, observedAt: c.at, salience: 1.0))
            }
        }
        // N1: each row keeps its real origin — a Contacts import is tagged `.contacts`, never
        // `.dictionary`, so it cannot enter the authored tier (and `ContextRanker` drops it).
        for d in (try? store.dictionaryEntries()) ?? [] {
            out.append(ContextEntry(text: d.term, source: d.origin.contextSource, observedAt: now, salience: min(1, d.weight)))
        }
        return out
    }
}

// MARK: - Code symbols (file names)

public protocol OpenDocumentProvider: Sendable {
    /// Paths or names of documents open in the focused app (AXDocument, window titles).
    func openDocumentNames() -> [String]
}

public struct MockOpenDocuments: OpenDocumentProvider {
    public var names: [String]
    public init(_ names: [String]) { self.names = names }
    public func openDocumentNames() -> [String] { names }
}

public struct CodeSymbolSource: ContextSource {
    public let kind = ContextSourceKind.codeSymbols
    public var provider: OpenDocumentProvider
    public init(provider: OpenDocumentProvider) { self.provider = provider }

    public func harvest(now: Date) -> [ContextEntry] {
        var out: [ContextEntry] = []
        var seen = Set<String>()
        for name in provider.openDocumentNames() {
            for sym in Self.symbols(fromFileName: name) where seen.insert(sym).inserted {
                out.append(ContextEntry(text: sym, source: .codeSymbols, observedAt: now, salience: 0.8))
            }
        }
        return out
    }

    /// `Engine/Biasing/ShallowFusionBiaser.swift` → ["ShallowFusionBiaser.swift", "ShallowFusionBiaser", "Shallow", "Fusion", "Biaser", "Biasing"].
    public static func symbols(fromFileName path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        var out: [String] = [url.lastPathComponent]
        let stem = url.deletingPathExtension().lastPathComponent
        if stem != url.lastPathComponent, !stem.isEmpty { out.append(stem) }
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, parent != "/", parent != "." { out.append(parent) }
        out.append(contentsOf: splitCamel(stem).filter { $0.count >= 3 })
        return out
    }

    static func splitCamel(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        for ch in s {
            if ch == "_" || ch == "-" || ch == "." { if !cur.isEmpty { parts.append(cur) }; cur = ""; continue }
            if ch.isUppercase, let last = cur.last, last.isLowercase { parts.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.count > 1 ? parts : []
    }
}

// MARK: - Contacts / participants (permissioned)

public protocol ContactsProvider: Sendable {
    /// Names; must return [] (never prompt) when permission is not already granted.
    func contactNames() -> [String]
}

public struct MockContacts: ContactsProvider {
    public var names: [String]
    public init(_ names: [String]) { self.names = names }
    public func contactNames() -> [String] { names }
}

public struct ContactsSource: ContextSource {
    public let kind = ContextSourceKind.contacts
    public var provider: ContactsProvider
    public init(provider: ContactsProvider) { self.provider = provider }
    public func harvest(now: Date) -> [ContextEntry] {
        provider.contactNames().map { ContextEntry(text: $0, source: .contacts, observedAt: now, salience: 0.5) }
    }
}

/// Thread participants / calendar attendees supplied by the app layer (Mail/Calendar adapters).
public final class ParticipantsSource: ContextSource, @unchecked Sendable {
    public let kind = ContextSourceKind.participants
    private let lock = NSLock()
    private var names: [String] = []
    public init() {}
    public func set(_ names: [String]) { lock.withLock { self.names = names } }
    public func harvest(now: Date) -> [ContextEntry] {
        lock.withLock { names.map { ContextEntry(text: $0, source: .participants, observedAt: now, salience: 0.9) } }
    }
}
