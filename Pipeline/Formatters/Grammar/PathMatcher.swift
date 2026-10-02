import Foundation
import Shared

/// N13 (F26) — matches spoken folder/file names against the focused shell's current folder
/// (`ShellContext.entries`, one level, listed only after the user's Settings OK).
///
/// Silent only when close: the spoken words equal an entry once case, spaces, dashes,
/// underscores and dots are ignored ("documents" → `Documents/`, "voice plus" → `VoicePlus/`),
/// or differ from exactly one entry by a single edit on a long name. Anything looser keeps the
/// spoken words and attaches the entry as a suggestion (`Alternate`, source `.biasing`). No
/// entries (no permission, unreadable folder) → no matching at all.
public enum PathMatcher {
    public enum Match: Equatable, Sendable {
        /// Close enough to replace the words without asking.
        case silent(ShellContext.Entry)
        /// Plausible but not certain: keep the words, offer this entry.
        case suggest(ShellContext.Entry)
    }

    /// Score attached to a suggestion alternate.
    public static let suggestionScore: Float = 0.5

    /// Lowercased letters and digits only: "Voice-Plus_2.0" → "voiceplus20".
    public static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Best entry for `spoken` (one or more words), or nil when nothing is near.
    public static func match(_ spoken: String, in entries: [ShellContext.Entry]) -> Match? {
        let k = key(spoken)
        guard k.count >= 2, !entries.isEmpty else { return nil }
        let keyed = entries.map { ($0, key($0.name)) }.filter { !$0.1.isEmpty }

        // 1. Exact after normalisation. Prefer a folder, then the shortest name.
        let exact = keyed.filter { $0.1 == k }.map(\.0)
        if let best = exact.sorted(by: rank).first { return .silent(best) }

        // 2. One edit away from exactly one entry, on a long enough name → silent.
        let distances = keyed.map { ($0.0, editDistance(k, $0.1)) }
        let oneOff = distances.filter { $0.1 == 1 }.map(\.0)
        if k.count >= 6, oneOff.count == 1, !distances.contains(where: { $0.1 == 2 }) { return .silent(oneOff[0]) }

        // 3. Suggest: within a third of the length.
        let budget = max(1, k.count / 3)
        let near = distances.filter { $0.1 <= budget }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : rank($0.0, $1.0) }
        if let best = near.first { return .suggest(best.0) }
        // 4. Suggest: the spoken words abbreviate exactly one name ("docs" → Documents,
        //    same first letter, letters in order).
        let abbreviates = keyed.filter { k.count >= 3 && $0.1.first == k.first && isSubsequence(k, of: $0.1) }.map(\.0)
        if abbreviates.count == 1 { return .suggest(abbreviates[0]) }
        return nil
    }

    static func isSubsequence(_ a: String, of b: String) -> Bool {
        var it = b.makeIterator()
        return a.allSatisfy { c in while let x = it.next() { if x == c { return true } }; return false }
    }

    static func rank(_ a: ShellContext.Entry, _ b: ShellContext.Entry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.count != b.name.count ? a.name.count < b.name.count : a.name < b.name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
