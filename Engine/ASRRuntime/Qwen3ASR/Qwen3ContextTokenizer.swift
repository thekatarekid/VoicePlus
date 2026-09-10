// VoicePlus original (task R5.1). Turns a plain-text context prompt into Qwen token ids.
//
// Qwen3-ASR biases on a context string carried in the system message. The port ships a decoder
// (ids -> text, byte-level BPE) but no encoder, and `vocab.json` next to the weights is exactly
// the table an encoder needs: token string -> id, with bytes escaped into printable scalars the
// GPT-2 way. So: bytes -> escaped scalars -> greedy longest match against the vocabulary.
//
// Greedy longest match is *not* BPE's merge order, so a context string may tokenize into more
// tokens than the reference tokenizer would produce. Every token is a real vocabulary entry and
// the sequence decodes back to the same bytes, which is what a bias prompt needs; the cost is a
// few extra tokens out of the context budget. Kept here, not in the ported files, so the port
// stays a faithful copy.
import Foundation

@available(macOS 15, *)
struct Qwen3ContextTokenizer: Sendable {
    /// Longest token in Qwen's vocabulary worth probing, in escaped scalars.
    private static let maxTokenLength = 24

    private let tokenToID: [String: Int32]

    /// Read `vocab.json` (token -> id, the file's own direction) straight off disk.
    ///
    /// Deliberately not taken from `Qwen3AsrModels.vocabulary`: that would mean loading the
    /// 1.2 GB model container a second time just to see a 2.7 MB table.
    init(vocabularyFile url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let table = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw RefinementError.weightsIncomplete(
                path: url.path, problems: ["vocab.json is not a token table"]
            )
        }
        var out = [String: Int32](minimumCapacity: table.count)
        for (token, id) in table where id <= Int(Int32.max) { out[token] = Int32(id) }
        self.tokenToID = out
    }

    /// Built from the vocabulary a loaded model container already holds (`[id: token]`).
    init(vocabulary: [Int: String]) {
        var table = [String: Int32](minimumCapacity: vocabulary.count)
        for (id, token) in vocabulary where id <= Int(Int32.max) {
            // Ids are unique, tokens are unique; on any duplicate keep the lower id (the older
            // merge), which is what a BPE vocabulary would resolve to.
            if let existing = table[token], existing <= Int32(id) { continue }
            table[token] = Int32(id)
        }
        self.tokenToID = table
    }

    /// GPT-2/Qwen byte-to-unicode escape: printable bytes map to themselves, the rest to U+0100…
    static let byteToUnicode: [UInt8: UnicodeScalar] = {
        var printable = [Int]()
        printable.append(contentsOf: 33...126)
        printable.append(contentsOf: 161...172)
        printable.append(contentsOf: 174...255)
        let printableSet = Set(printable)

        var mapping = [UInt8: UnicodeScalar]()
        for b in printable { mapping[UInt8(b)] = UnicodeScalar(UInt32(b))! }
        var extra: UInt32 = 256
        for b in 0...255 where !printableSet.contains(b) {
            mapping[UInt8(b)] = UnicodeScalar(extra)!
            extra += 1
        }
        return mapping
    }()

    /// Encode `text`, stopping at `limit` tokens (a whole token, never half of one).
    ///
    /// Returns `[]` for empty text or a zero budget, so "no context" costs nothing and produces
    /// byte-for-byte the prompt the upstream port builds.
    func encode(_ text: String, limit: Int) -> [Int32] {
        guard limit > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let escaped = Array(String(String.UnicodeScalarView(
            Array(trimmed.utf8).compactMap { Self.byteToUnicode[$0] }
        )))
        var tokens: [Int32] = []
        var i = 0
        while i < escaped.count, tokens.count < limit {
            var matched = false
            let maxLen = min(Self.maxTokenLength, escaped.count - i)
            var length = maxLen
            while length > 0 {
                let candidate = String(escaped[i..<(i + length)])
                if let id = tokenToID[candidate] {
                    tokens.append(id)
                    i += length
                    matched = true
                    break
                }
                length -= 1
            }
            // A scalar with no single-character token cannot be represented; drop it rather than
            // stall. Real Qwen vocabularies contain all 256 escaped bytes, so this is defensive.
            if !matched { i += 1 }
        }
        return tokens
    }
}
