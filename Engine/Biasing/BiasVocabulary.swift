import Foundation

/// SentencePiece-style piece vocabulary with a greedy longest-match encoder. The frozen
/// `Decoder` exposes no tokenizer API, so this loads the model's vocab file directly:
/// FluidAudio `parakeet_vocab.json` (`{"id": "piece"}`), a JSON array, or a SentencePiece
/// `.vocab` TSV (`piece<TAB>score`, id = line number).
public struct BiasVocabulary: Sendable {
    public static let wordMarker: Character = "\u{2581}"
    public let pieces: [String]
    public let ids: [String: Int]
    public let maxPieceLength: Int

    public init(pieces: [String]) {
        self.pieces = pieces
        var m: [String: Int] = [:]
        for (i, p) in pieces.enumerated() where m[p] == nil { m[p] = i }
        self.ids = m
        self.maxPieceLength = pieces.map(\.count).max() ?? 1
    }

    public enum LoadError: Error { case unsupportedFormat(String) }

    public static func load(from url: URL) throws -> BiasVocabulary {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                var arr = [String](repeating: "", count: (dict.keys.compactMap { Int($0) }.max() ?? -1) + 1)
                for (k, v) in dict { if let i = Int(k), i >= 0 { arr[i] = v } }
                return BiasVocabulary(pieces: arr)
            }
            if let arr = try? JSONDecoder().decode([String].self, from: data) { return BiasVocabulary(pieces: arr) }
            throw LoadError.unsupportedFormat(url.lastPathComponent)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LoadError.unsupportedFormat(url.lastPathComponent) }
        let pieces = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            String(line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        return BiasVocabulary(pieces: pieces.last == "" ? Array(pieces.dropLast()) : pieces)
    }

    /// Looks for the Parakeet vocab in the app's model dir or FluidAudio's cache.
    public static func discoverParakeet() -> BiasVocabulary? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let candidates = [
            support.appendingPathComponent("VoicePlus/Models/parakeet-tdt-0.6b-v3-coreml/parakeet_vocab.json"),
            support.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3/parakeet_vocab.json"),
        ]
        for c in candidates where fm.fileExists(atPath: c.path) { return try? load(from: c) }
        return nil
    }

    /// Encodes one word (no spaces) as `▁`-prefixed pieces, greedy longest match.
    /// Returns nil if some character has no piece (then the term can't be biased).
    public func encodeWord(_ word: String) -> [Int]? {
        let chars = Array(String(Self.wordMarker) + word)
        var out: [Int] = []
        var i = 0
        while i < chars.count {
            var matched = false
            let maxLen = min(maxPieceLength, chars.count - i)
            var len = maxLen
            while len >= 1 {
                let piece = String(chars[i..<(i + len)])
                if let id = ids[piece] { out.append(id); i += len; matched = true; break }
                len -= 1
            }
            if !matched {
                // `▁` alone may be a piece; otherwise skip the marker and retry the bare char.
                if chars[i] == Self.wordMarker { i += 1; continue }
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Encodes a multi-word term as one token sequence.
    public func encode(_ term: String) -> [Int]? {
        var out: [Int] = []
        for w in term.split(whereSeparator: { $0.isWhitespace }) {
            guard let ids = encodeWord(String(w)) else { return nil }
            out += ids
        }
        return out.isEmpty ? nil : out
    }

    /// Small synthetic vocab for tests and the Lab: word-marked and bare single characters
    /// plus a few multi-char pieces. Ids are stable for a given piece list.
    public static func synthetic(extraPieces: [String] = []) -> BiasVocabulary {
        var pieces = ["<blank>", "<unk>"]
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        for c in letters { pieces.append(String(c)); pieces.append(String(wordMarker) + String(c)) }
        pieces += ["▁the", "▁get", "▁pods", "▁cube", "▁control", "▁kube", "ctl", "▁Kot", "hari", "▁Ko", "tari", "▁gpt", "4", "o",
                   "▁Team", "Viewer", "▁AG", "▁team", "▁viewer", "▁meeting", "▁with", "▁call", "▁please", "▁run"]
        pieces += extraPieces
        var seen = Set<String>()
        return BiasVocabulary(pieces: pieces.filter { seen.insert($0).inserted })
    }
}
