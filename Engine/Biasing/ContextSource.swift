import Foundation

/// Where a harvested term came from. Drives ranking weights and Lab attribution.
public enum ContextSourceKind: String, CaseIterable, Sendable, Codable {
    case axTree          // proper nouns visible in the focused window's accessibility tree
    case recentWords     // words dictated/typed in the last 10 minutes
    case corrections     // words the user has ever corrected (CorrectionRecord)
    case dictionary      // user dictionary terms (DictionaryRecord)
    case codeSymbols     // file names / symbols from open documents
    case contacts        // contact names (only with granted permission)
    case participants    // thread participants / calendar attendees
}

/// One candidate term for biasing, tagged with its origin.
public struct ContextEntry: Hashable, Sendable {
    public var text: String
    public var source: ContextSourceKind
    /// When the term was observed (recency decay in the ranker).
    public var observedAt: Date
    /// Source-local salience in 0…1 (e.g. window title > body text; dictionary weight).
    public var salience: Double

    public init(text: String, source: ContextSourceKind, observedAt: Date = Date(), salience: Double = 1.0) {
        self.text = text
        self.source = source
        self.observedAt = observedAt
        self.salience = min(max(salience, 0), 1)
    }
}

/// A harvest source. Implementations must be cheap and never block on permissions.
public protocol ContextSource: Sendable {
    var kind: ContextSourceKind { get }
    func harvest(now: Date) -> [ContextEntry]
}

/// Shared term extraction used by text-bearing sources: keeps tokens that look like entities
/// (Capitalised, CamelCase, contain digits/-/_/. like `gpt-4o`, `kubectl`, `TeamViewer AG`)
/// and drops plain lowercase function words. Multi-word capitalised runs are kept whole.
public enum EntityExtractor {
    static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "i", "you", "it", "this", "that", "at", "by", "from", "as", "be", "we", "he", "she", "they"]

    /// Entity-like terms only (see `extractWeighted`).
    public static func extract(from text: String, maxTerms: Int = 2_000) -> [String] {
        extractWeighted(from: text, maxTerms: maxTerms).filter { $0.strength >= 1 }.map(\.term)
    }

    /// Entity-like terms at strength 1; plain lowercase words (≥ 4 chars, e.g. `kubectl`) at
    /// `plainStrength` so on-screen jargon is still biased but ranks below real entities.
    public static func extractWeighted(from text: String, maxTerms: Int = 2_000, plainStrength: Double = 0.35) -> [(term: String, strength: Double)] {
        var out: [(term: String, strength: Double)] = []
        var seen = Set<String>()
        var run: [String] = []
        func flushRun() {
            if run.count >= 2 {
                let phrase = run.joined(separator: " ")
                if seen.insert(phrase.lowercased()).inserted { out.append((phrase, 1)) }
            }
            run.removeAll()
        }
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "(" || $0 == ")" || $0 == "\"" || $0 == "“" || $0 == "”" }) {
            var w = String(raw)
            while let last = w.last, ".:!?".contains(last) { w.removeLast() }
            guard w.count >= 2, w.count <= 40, w.first!.isLetter else { flushRun(); continue }
            let isCap = w.first!.isUppercase
            if isCap { run.append(w) } else { flushRun() }
            if isEntityLike(w) {
                if seen.insert(w.lowercased()).inserted { out.append((w, 1)) }
            } else if w.count >= 4, !stop.contains(w.lowercased()), seen.insert(w.lowercased()).inserted {
                out.append((w, plainStrength))
            }
            if out.count >= maxTerms { break }
        }
        flushRun()
        return out
    }

    public static func isEntityLike(_ w: String) -> Bool {
        guard let first = w.first, first.isLetter else { return false }
        if stop.contains(w.lowercased()) { return false }
        if first.isUppercase { return true }
        if w.contains(where: { $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) { return true }
        // camelCase / mixed case
        if w.dropFirst().contains(where: { $0.isUppercase }) { return true }
        return false
    }
}
