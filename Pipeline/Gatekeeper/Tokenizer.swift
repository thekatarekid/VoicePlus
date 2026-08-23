import Foundation

enum GatekeeperTokenizer {
    /// Lower-cased word tokens; punctuation stripped except inside words (e.g. "gpt-4o").
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "-" || scalar == "_" {
                cur.unicodeScalars.append(scalar)
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Unigram + bigram features with a leading `^` boundary token so "start of utterance" cues
    /// ("^ no", "^ make") are learnable.
    static func features(_ words: [String]) -> [String] {
        guard !words.isEmpty else { return [] }
        var f = words
        let padded = ["^"] + words + ["$"]
        for i in 0..<(padded.count - 1) { f.append(padded[i] + " " + padded[i + 1]) }
        return f
    }
}
