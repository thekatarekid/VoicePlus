import Foundation
import Shared

/// V5 F1 — the persona auto-draft loop. Every landing whose observation window closed (accepted
/// verbatim or edited by the user) teaches the app's `StyleProfile` through `StyleLearner`; the
/// app's persona is then re-drafted by `PersonaManager` **only while it is still auto-drafted**.
/// A persona the user edited is never overwritten. Everything stays on the Mac.
public struct PersonaLearningLoop: Sendable {
    public let personas: PersonaManager
    public var learner: StyleLearner
    /// Field values longer than this (in words) are not aligned; the landing counts as accepted.
    public static let maxAlignWords = 5000
    /// Dictations longer than this (in words) are not aligned either.
    public static let maxOriginalWords = 300

    public struct Update: Equatable, Sendable {
        public var profile: StyleProfile
        public var persona: Persona
        /// The text that was learned from (the user's version of the dictation).
        public var learnedText: String
        public var edited: Bool
    }

    public init(personas: PersonaManager) {
        self.personas = personas
        self.learner = StyleLearner(store: personas.styles)
    }

    /// One closed landing. `fieldValue` is the field's text after the user's edits (nil when the
    /// field was not edited). Returns nil when there is nothing to learn (no app, empty text).
    @discardableResult
    public func observe(original: String, fieldValue: String?, bundleID: String) -> Update? {
        guard !bundleID.isEmpty, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let learned = fieldValue.map { Self.editedSegment(original: original, fieldValue: $0) } ?? original
        do {
            let profile = try learner.ingest(original: original, edited: learned, bundleID: bundleID)
            let persona = try personas.persona(for: bundleID)
            return Update(profile: profile, persona: persona, learnedText: learned,
                          edited: Self.norm(original) != Self.norm(learned))
        } catch {
            Log.pipeline.error("persona learning failed for \(bundleID): \(error)")
            return nil
        }
    }

    /// Landings learned from for this app (0 before the first one).
    public func learnedCount(for bundleID: String) -> Int {
        ((try? personas.styles.profile(for: bundleID)) ?? nil)?.dictationCount ?? 0
    }

    // MARK: - Alignment

    /// The part of `fieldValue` that is the user's version of `original`. The field usually holds
    /// more than the dictation (the rest of the message or document), so the word window whose
    /// edit distance to the dictation is smallest is returned, with its original line breaks.
    /// Falls back to `original` when no window resembles it.
    public static func editedSegment(original: String, fieldValue: String) -> String {
        let orig = tokens(original), field = tokens(fieldValue)
        let n = orig.count
        guard n > 0, !field.isEmpty else { return original }
        if field.count <= n + 3 { return fieldValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard field.count <= maxAlignWords, n <= maxOriginalWords else { return original }
        let o = orig.map(\.key)
        // Candidate starts: near a field word that matches one of the dictation's first words.
        let heads = Set(o.prefix(4))
        var starts = Set<Int>()
        for (p, t) in field.enumerated() where heads.contains(t.key) {
            for s in max(0, p - 3)...min(field.count - 1, p) { starts.insert(s) }
        }
        var best: (distance: Double, start: Int, end: Int)?
        for start in starts.sorted() {
            for length in max(1, n - 3)...(n + 3) where start + length <= field.count {
                let d = distance(o, field[start..<(start + length)].map(\.key))
                if best == nil || d < best!.distance { best = (d, start, start + length) }
            }
        }
        // More than half the words changed: this is not the dictation any more.
        guard let best, best.distance * 2 <= Double(n) else { return original }
        let lower = field[best.start].range.lowerBound, upper = field[best.end - 1].range.upperBound
        return String(fieldValue[lower..<upper])
    }

    struct Token { var key: String; var range: Range<String.Index> }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace || s[i].isNewline {
                if let st = start { out.append(Token(key: key(s[st..<i]), range: st..<i)); start = nil }
            } else if start == nil { start = i }
            i = s.index(after: i)
        }
        if let st = start { out.append(Token(key: key(s[st..<s.endIndex]), range: st..<s.endIndex)) }
        return out
    }

    static func key(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Word-level edit distance; substituting a word that starts with the same letter costs half
    /// ("i will" → "ill"), so the window that really is the user's rewrite wins ties.
    static func distance(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty { return Double(b.count) }
        if b.isEmpty { return Double(a.count) }
        var prev = (0...b.count).map(Double.init), cur = [Double](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = Double(i)
            for j in 1...b.count {
                let x = a[i - 1], y = b[j - 1]
                let sub: Double = x == y ? 0 : (x.first != nil && x.first == y.first ? 0.5 : 1)
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + sub)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
