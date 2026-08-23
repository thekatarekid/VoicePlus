import Foundation

/// Label matching for click-by-name and phrase→catalog resolution. Pure, deterministic, no model.
public enum FuzzyMatch {
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func tokens(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    static let stopwords: Set<String> = ["the", "a", "an", "please", "my", "this"]
    /// Normalized with filler words removed (matching only — never applied to captured arguments).
    static func core(_ s: String) -> String {
        let t = tokens(s).filter { !stopwords.contains($0) }
        return t.isEmpty ? normalize(s) : t.joined(separator: " ")
    }

    /// Optimal-string-alignment distance (Levenshtein + adjacent transposition, so "cancle"→"cancel" costs 1).
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var pp = [Int](repeating: 0, count: b.count + 1), p = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(p[j] + 1, cur[j - 1] + 1, p[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], pp[j - 2] + 1) }
            }
            (pp, p, cur) = (p, cur, pp)
        }
        return p[b.count]
    }

    /// 0…1 similarity: exact 1.0; prefix / token containment high; otherwise normalized Levenshtein.
    public static func score(query: String, candidate: String) -> Double {
        if normalize(query) == normalize(candidate) { return 1 }
        let q = core(query), c = core(candidate)
        if q.isEmpty || c.isEmpty { return 0 }
        if q == c { return 0.98 }
        let ratio = Double(min(q.count, c.count)) / Double(max(q.count, c.count))
        let qt = Set(tokens(q)), ct = Set(tokens(c))
        var best = 0.0
        if qt.isSubset(of: ct) || ct.isSubset(of: qt) { best = 0.75 + 0.2 * Double(min(qt.count, ct.count)) / Double(max(qt.count, ct.count)) }
        if min(q.count, c.count) >= 3, c.hasPrefix(q) || q.hasPrefix(c) { best = max(best, 0.78 + 0.2 * ratio) }
        let overlap = Double(qt.intersection(ct).count) / Double(qt.union(ct).count)
        best = max(best, overlap * 0.85)
        // Edit distance only where it can plausibly matter: similar lengths, and not two multi-word phrases sharing no token.
        if ratio < 0.4 || (overlap == 0 && qt.count > 1 && ct.count > 1) { return best }
        return max(best, 1 - Double(levenshtein(q, c)) / Double(max(q.count, c.count)))
    }

    public static let defaultThreshold = 0.72

    /// Best candidate above threshold; ties broken by shortest candidate (most specific).
    public static func best<T>(_ query: String, in items: [T], label: (T) -> String, threshold: Double = defaultThreshold) -> (item: T, score: Double)? {
        var bestItem: T?, bestScore = threshold - .ulpOfOne, bestLen = Int.max
        for item in items {
            let l = label(item), s = score(query: query, candidate: l)
            if s > bestScore || (s == bestScore && l.count < bestLen) { bestItem = item; bestScore = s; bestLen = l.count }
        }
        guard let item = bestItem else { return nil }
        return (item, bestScore)
    }
}
