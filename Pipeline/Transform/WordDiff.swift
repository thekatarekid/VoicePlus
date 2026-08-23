import Foundation

/// Word-level diff (LCS) between old and new text; drives the inline morph animation
/// (old words collapse, new words expand). Spaces are normalised, newlines are tokens of their
/// own (a "two lines" rewrite must not diff as identity); tokens keep punctuation.
public struct WordDiff: Equatable, Sendable {
    public enum Op: Equatable, Sendable { case equal(String), delete(String), insert(String) }
    public var ops: [Op]

    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            if ch.isNewline { if !cur.isEmpty { out.append(cur); cur = "" }; out.append("\n") }
            else if ch.isWhitespace { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func compute(old: String, new: String) -> WordDiff {
        let a = tokens(old), b = tokens(new)
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { ops.append(.equal(a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.delete(a[i])); i += 1 }
            else { ops.append(.insert(b[j])); j += 1 }
        }
        while i < a.count { ops.append(.delete(a[i])); i += 1 }
        while j < b.count { ops.append(.insert(b[j])); j += 1 }
        return WordDiff(ops: ops)
    }

    public var deleted: Int { ops.reduce(0) { if case .delete = $1 { return $0 + 1 }; return $0 } }
    public var inserted: Int { ops.reduce(0) { if case .insert = $1 { return $0 + 1 }; return $0 } }
    public var unchanged: Int { ops.reduce(0) { if case .equal = $1 { return $0 + 1 }; return $0 } }
    public var isIdentity: Bool { deleted == 0 && inserted == 0 }
    /// 0 = identical, 1 = nothing shared. Used to pick the morph style (small edit vs full swap).
    public var changeRatio: Double {
        let total = deleted + inserted + unchanged
        return total == 0 ? 0 : Double(deleted + inserted) / Double(total)
    }
}
