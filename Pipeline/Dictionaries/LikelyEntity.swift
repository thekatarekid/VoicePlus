import Foundation
import Shared

/// V5 P5 — a set of ordinary English words (lowercase). A word *not* in it is out of vocabulary and
/// so a likely entity: a name, a product, a project ("Kothari", "Kubernetes", "Parakeet").
///
/// Source, first found: SCOWL size 50 downloaded into `PublicDictionaries.directory()`
/// (`PublicDictionaryCatalog.scowl`), then the macOS `/usr/share/dict/words` (Webster's Second,
/// public domain, present on every Mac). Both are read lazily, once. Only lowercase entries count:
/// `web2` lists "Aaron" capitalised, so "aaron" stays out of vocabulary — correctly.
public struct WordVocabulary: Sendable {
    private let words: Set<String>

    public init(words: some Sequence<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    /// Parses a word list: one word per line; SCOWL/ESDB's licence header (everything up to a `---`
    /// line, when one exists) is skipped; capitalised entries are proper nouns and are dropped.
    public init(listText text: String) {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let separator = lines.firstIndex(where: { $0.hasPrefix("---") }), separator < 200 {
            lines.removeFirst(separator + 1)
        }
        var set = Set<String>()
        set.reserveCapacity(lines.count)
        for line in lines {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, word == word.lowercased() else { continue }
            set.insert(word)
        }
        set.formUnion(Self.modern)
        self.words = set
    }

    public var count: Int { words.count }
    public var isEmpty: Bool { words.isEmpty }

    /// True for an ordinary word or a regular inflection of one ("batteries", "focused", "emails").
    public func contains(_ word: String) -> Bool {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if words.contains(key) { return true }
        var stems: [String] = []
        if key.hasSuffix("'s") { stems.append(String(key.dropLast(2))) }
        if key.hasSuffix("ies") { stems.append(String(key.dropLast(3)) + "y") }
        if key.hasSuffix("es") { stems.append(String(key.dropLast(2))) }
        if key.hasSuffix("s") { stems.append(String(key.dropLast())) }
        if key.hasSuffix("ed") { stems += [String(key.dropLast(2)), String(key.dropLast())] }
        if key.hasSuffix("ing") { stems += [String(key.dropLast(3)), String(key.dropLast(3)) + "e"] }
        if key.hasSuffix("er") { stems += [String(key.dropLast(2)), String(key.dropLast())] }
        if key.hasSuffix("ly") { stems.append(String(key.dropLast(2))) }
        return stems.contains { $0.count >= 2 && words.contains($0) }
    }

    /// Everyday words Webster's Second (1934) predates. SCOWL has them; this keeps the macOS
    /// fallback from treating "email" as a name.
    static let modern: Set<String> = [
        "email", "emails", "online", "offline", "website", "app", "apps", "blog", "login", "logout", "username",
        "wifi", "smartphone", "laptop", "internet", "download", "upload", "video", "podcast", "emoji", "selfie",
        "hashtag", "browser", "inbox", "spam", "cloud", "server", "admin", "dev", "repo", "okay", "ok", "hey",
        "hi", "yeah", "yep", "nope", "gonna", "wanna", "gotta", "lol", "btw", "fyi", "asap", "via", "update",
        "updates", "feedback", "workflow", "dashboard", "deadline", "timeline", "screenshot", "chatbot", "toolbar",
        "desktop", "keyboard", "touchscreen", "startup", "website", "webpage", "online", "texting", "text",
        "tech", "zoom", "meetup", "teammate", "teammates", "weekend", "kinda", "sorta", "alright", "cool",
    ]

    /// SCOWL when downloaded, else the macOS word list, else just the modern supplement.
    public static func installed() -> WordVocabulary {
        var candidates: [URL] = []
        if let scowl = PublicDictionaryCatalog.scowl.localURL { candidates.append(scowl) }
        candidates.append(URL(fileURLWithPath: PublicDictionaryCatalog.systemWords.source))
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let vocabulary = WordVocabulary(listText: text)
                if vocabulary.count > 1_000 { return vocabulary }
            }
        }
        return WordVocabulary(words: modern)
    }
}

/// V5 P5 — which tokens of a text are likely entities (out of vocabulary). Never a decision about
/// what the word *should* be: only "leave this one alone".
public enum LikelyEntity {
    /// A token is a likely entity when its core (edge punctuation stripped) has ≥ 2 letters and
    /// either is out of vocabulary or has non-trivial casing (inner capital: "iPhone", "McKinsey").
    public static func isLikelyEntity(_ token: String, vocabulary: WordVocabulary, casing: CasingLexicon? = nil) -> Bool {
        let core = TokenEdges.split(token).1
        guard core.filter(\.isLetter).count >= 2, core.first?.isLetter == true else { return false }
        if core.dropFirst().contains(where: \.isUppercase), core.contains(where: \.isLowercase) { return true }
        if let casing, casing.canonicalForm(of: core) != nil { return true }
        let letters = core.filter { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        guard letters.count == core.count else { return true } // digits / symbols: gpt-4o, B2B
        if core.contains("-") {
            return core.split(separator: "-").contains { !vocabulary.contains(String($0)) }
        }
        return !vocabulary.contains(core)
    }

    /// Cores of the likely-entity tokens in `text`, in order.
    public static func tokens(in text: String, vocabulary: WordVocabulary, casing: CasingLexicon? = nil) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { isLikelyEntity($0, vocabulary: vocabulary, casing: casing) }
            .map { TokenEdges.split($0).1 }
    }
}

public extension TranscriptSpan {
    /// V5 P5 — true when any token of this span is out of vocabulary (`LikelyEntity`). Computed (no
    /// stored field: `Shared/` is not this lane's); `EntityGuard` is what enforces it.
    func isLikelyEntity(vocabulary: WordVocabulary = PublicDictionaries.shared.vocabulary) -> Bool {
        !LikelyEntity.tokens(in: text, vocabulary: vocabulary).isEmpty
    }
}

/// V5 P5 — cleanup/style stages never lowercase or "correct" a likely entity.
///
/// `restore(original:rewritten:)` compares a stage's output with its input token by token (an LCS
/// alignment over case-folded cores) and puts back every likely-entity token the stage only
/// lowercased (a stage may still capitalise one); `corrections(original:rewritten:)` reports likely entities a stage *replaced* with a
/// near-identical word ("Kothari" → "Kotari"), for a guard (D3) to reject the rewrite.
public struct EntityGuard: Sendable {
    public let vocabulary: WordVocabulary
    public let casing: CasingLexicon?

    public init(vocabulary: WordVocabulary = PublicDictionaries.shared.vocabulary,
                casing: CasingLexicon? = PublicDictionaries.shared.casing) {
        self.vocabulary = vocabulary
        self.casing = casing
    }

    /// `rewritten` with every likely-entity token of `original` that only changed case restored.
    public func restore(original: String, rewritten: String) -> String {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        var after = rewritten.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let afterIndices = after.indices.filter { !after[$0].isEmpty }
        let pairs = Self.align(before.map { TokenEdges.split($0).1.lowercased() },
                               afterIndices.map { TokenEdges.split(after[$0]).1.lowercased() })
        var changed = false
        for (i, j) in pairs {
            let original = TokenEdges.split(before[i]).1
            let k = afterIndices[j]
            let (lead, now, trail) = TokenEdges.split(after[k])
            guard now != original, Self.lowersCase(from: original, to: now), isLikelyEntity(before[i]) else { continue }
            after[k] = lead + original + trail
            changed = true
        }
        return changed ? after.joined(separator: " ") : rewritten
    }

    /// Likely entities of `original` that a rewrite turned into a different but similar word.
    public func corrections(original: String, rewritten: String) -> [(from: String, to: String)] {
        let before = original.split(whereSeparator: \.isWhitespace).map { TokenEdges.split(String($0)).1 }
        let after = rewritten.split(whereSeparator: \.isWhitespace).map { TokenEdges.split(String($0)).1 }
        let kept = Set(Self.align(before.map { $0.lowercased() }, after.map { $0.lowercased() }).map(\.0))
        let unmatchedAfter = after.filter { word in !before.contains { $0.lowercased() == word.lowercased() } }
        var out: [(String, String)] = []
        for (i, word) in before.enumerated() where !kept.contains(i) && isLikelyEntity(word) {
            if let near = unmatchedAfter.first(where: { Self.similar(word.lowercased(), $0.lowercased()) }) {
                out.append((word, near))
            }
        }
        return out
    }

    /// True when some letter that was uppercase in `original` is lowercase in `now` (same letters).
    /// Capitalising a sentence-initial "priya" is fine; lowercasing "Priya" or "iPhone" is not.
    static func lowersCase(from original: String, to now: String) -> Bool {
        guard original.count == now.count else { return false }
        return zip(original, now).contains { $0.isUppercase && $1.isLowercase }
    }

    func isLikelyEntity(_ token: String) -> Bool {
        LikelyEntity.isLikelyEntity(token, vocabulary: vocabulary, casing: casing)
    }

    /// Index pairs of an LCS alignment of two token lists.
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    /// Edit distance ≤ max(1, len/4): "kothari"/"kotari", not "kothari"/"carry".
    static func similar(_ a: String, _ b: String) -> Bool {
        guard a != b, !a.isEmpty, !b.isEmpty else { return false }
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= max(1, a.count / 4) else { return false }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count] <= max(1, a.count / 4)
    }
}

/// V5 P5 — wraps a cleanup/style stage so it can never lowercase a likely entity. Same `id` as the
/// wrapped stage (it *is* that stage, guarded); provenance comes from the inner stage.
public struct EntityProtectingStage: PipelineStage {
    public let inner: any PipelineStage
    public let entityGuard: @Sendable () -> EntityGuard
    public var id: StageID { inner.id }

    public init(_ inner: any PipelineStage, guard entityGuard: @escaping @Sendable () -> EntityGuard = { EntityGuard() }) {
        self.inner = inner
        self.entityGuard = entityGuard
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        let output = try await inner.process(spans, context: context)
        guard output.count == spans.count, zip(spans, output).contains(where: { $0.text != $1.text }) else { return output }
        let guardian = entityGuard()
        return zip(spans, output).map { before, after in
            guard before.text != after.text else { return after }
            var fixed = after
            fixed.text = guardian.restore(original: before.text, rewritten: after.text)
            return fixed
        }
    }
}
