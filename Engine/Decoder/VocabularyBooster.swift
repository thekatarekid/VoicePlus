import Foundation
import Shared

// V5 B1 — CTC vocabulary boosting on the final pass.
//
// The old decode-time `LogitBiaser` path could only re-score the token the greedy decoder had
// already chosen (FluidAudio exposes no per-step hook), so it never changed a word: the Lab
// measured 0 entity-recall gain (V5 X3/X5/A1). Boosting now happens *after* the TDT final pass,
// with acoustic evidence: a separate CTC model (`parakeet-ctc-110m`) spots the vocabulary terms in
// the same audio, and FluidAudio's constrained rescorer swaps a TDT word for a term only when the
// CTC evidence beats it. The preview pass is never boosted (two `AsrManager`s, see
// `FluidAudioTDTDecoder`).
//
// This file is the model-free part: the protocol a booster implements and the pure mapping from a
// rescored transcript back onto `[DecodedToken]` so confidence / timing / provenance survive.

/// What one boosted final pass changed.
public struct BoostOutcome: Sendable, Equatable {
    /// Tokens after boosting. Unchanged words keep their original tokens bit-for-bit.
    public var tokens: [DecodedToken]
    /// `(original, replacement)` word pairs actually applied, in order.
    public var replacements: [Replacement]
    /// Vocabulary terms the CTC spotter found in the audio (whether or not anything was replaced).
    public var detectedTerms: [String]

    public struct Replacement: Sendable, Equatable {
        public var original: String
        public var replacement: String
        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }

    public init(tokens: [DecodedToken], replacements: [Replacement] = [], detectedTerms: [String] = []) {
        self.tokens = tokens
        self.replacements = replacements
        self.detectedTerms = detectedTerms
    }

    public var wasModified: Bool { !replacements.isEmpty }
}

/// Final-pass vocabulary booster. Built once per utterance from that utterance's vocabulary
/// (the boost list is rebuilt at hotkey-down; see `BoostingController`).
///
/// Contract: never throws and never makes things worse by failing — any internal error returns
/// `nil`, and the caller keeps the unboosted tokens. `samples` are 16 kHz mono on the same clock as
/// the tokens' times (time zero = first sample).
public protocol VocabularyBooster: Sendable {
    /// Terms this booster was built for (already capped and deduplicated).
    var terms: [String] { get }
    func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome?
}

/// A decoder that can take a final-pass booster. Additive to the frozen `Decoder` protocol.
public protocol VocabularyBoostable: AnyObject {
    /// Installed booster for the *final* pass, or nil. The preview pass ignores it.
    var booster: VocabularyBooster? { get set }
}

/// A decoder with a separate, never-boosted preview pass (B1: the streaming manager).
public protocol PreviewDecoding: AnyObject {
    func decodePreview(encoderFrames: EncoderFrames) async throws -> DecodeResult
}

/// Maps a rescored transcript back onto the original tokens.
///
/// The CTC rescorer works on words and returns text; this aligns that text with the original
/// words (LCS on case-folded words) so that every word the rescorer did not touch keeps its original
/// tokens — confidence, audio range and ids intact — and each replaced run becomes one token per new
/// word spread over the audio of the words it replaced.
///
/// A replacement word's `logProb` is the *lowest* token log-prob of the words it replaced (N11:
/// boosted words are lower-confidence, never more certain than the hypothesis they replaced, Bet 9).
/// Its `tokenId` is `-1` (not a TDT id), which `BoostTag` turns into the `.boosted` span tag.
public enum BoostAlignment {
    public static let replacementTokenId = -1

    struct Word {
        var tokens: [DecodedToken]
        var text: String { tokens.renderedText }
        var key: String { Self.key(text) }
        static func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
    }

    static func words(_ tokens: [DecodedToken]) -> [Word] {
        var out: [Word] = []
        for t in tokens {
            if t.isWordStart || out.isEmpty { out.append(Word(tokens: [t])) } else { out[out.count - 1].tokens.append(t) }
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// Re-token `rescoredText` against `tokens`. Returns `tokens` unchanged when the texts agree.
    ///
    /// `accept(original, replacement)` vets each replaced run (texts of the old words joined by a
    /// space, and of the new words); a rejected run keeps its original tokens bit-for-bit. Case /
    /// punctuation-only changes of one word are always accepted.
    public static func apply(rescoredText: String, to tokens: [DecodedToken],
                             accept: (String, String) -> Bool = { _, _ in true }) -> [DecodedToken] {
        let old = words(tokens)
        let new = rescoredText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !new.isEmpty, !old.isEmpty else { return tokens }
        if old.map(\.text) == new { return tokens }

        // LCS over normalised keys (punctuation/case-insensitive), so "Kothari," still anchors.
        let a = old.map(\.key), b = new.map(Word.key)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = (a[i] == b[j] && !a[i].isEmpty) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [DecodedToken] = []
        var i = 0, j = 0
        var pendingOld: [Word] = [], pendingNew: [String] = []
        func flush() {
            defer { pendingOld.removeAll(); pendingNew.removeAll() }
            guard !pendingNew.isEmpty else { return }   // pure deletion: the rescorer merged words away
            let original = pendingOld.map(\.text).joined(separator: " ")
            if !pendingOld.isEmpty, !accept(original, pendingNew.joined(separator: " ")),
               Word.key(original) != Word.key(pendingNew.joined()) {
                out.append(contentsOf: pendingOld.flatMap(\.tokens))
                return
            }
            let span = pendingOld.flatMap(\.tokens)
            let prevEnd = out.last?.endTime ?? span.first?.startTime ?? 0
            let start = span.first?.startTime ?? prevEnd
            let end = span.last?.endTime ?? start
            // N11: a swapped word takes the LOWER confidence — the CTC evidence chose the word, but
            // the word is still uncertain; later stages and the UI treat it as such (tag `.boosted`).
            let lp = span.map(\.logProb).min() ?? 0
            let step = (end - start) / Double(pendingNew.count)
            for (k, w) in pendingNew.enumerated() {
                let s = start + step * Double(k)
                out.append(DecodedToken(tokenId: replacementTokenId, text: "\u{2581}" + w, logProb: min(0, lp),
                                        startTime: s, endTime: s + step))
            }
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j], !a[i].isEmpty {
                flush()
                if old[i].text == new[j] {
                    out.append(contentsOf: old[i].tokens)
                } else {
                    // Same word, different casing/punctuation (the rescorer restored "Kothari").
                    pendingOld = [old[i]]; pendingNew = [new[j]]; flush()
                }
                i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                pendingNew.append(new[j]); j += 1
            } else {
                pendingOld.append(old[i]); i += 1
            }
        }
        flush()
        return out
    }
}

/// V5 B1 — the last word on whether a CTC rescue is applied.
///
/// FluidAudio's rescorer anchors a term where the CTC spotter scored it and swaps the TDT word(s)
/// there when the acoustic score wins; its string-similarity floors are applied to a *candidate
/// span* it picks itself, so on the entity fixtures it still rewrote an ordinary spoken word for an
/// unspoken list term ("stores" → "Postgres": the spotter matched the "-st…res" sound across
/// "stores transcripts"). A real mishearing of a term sounds like the term; an ordinary word that
/// merely sits where the spotter fired does not. So a replacement is kept only when the words it
/// replaces are close to the term in spelling **or** in a coarse phonetic key, and the bar is higher
/// when the replaced text is a single common English word (those are the words TDT gets right).
public enum BoostGuard {
    /// Minimum similarity (0…1, normalised edit distance) between replaced text and term.
    public static let minSimilarity = 0.6
    /// Higher bar when the replaced text is one common English word.
    public static let minSimilarityCommonWord = 0.8

    public static func accepts(original: String, replacement: String) -> Bool {
        let a = letters(original), b = letters(replacement)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }   // spacing / case / punctuation only ("Team viewer" → "TeamViewer")
        let sim = max(similarity(a, b), similarity(phonetic(a), phonetic(b)))
        let words = original.split(whereSeparator: { $0.isWhitespace })
        let common = words.count == 1 && commonWords.contains(a)
        return sim >= (common ? minSimilarityCommonWord : minSimilarity)
    }

    static func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// 1 − Levenshtein / max length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var prev = Array(0...y.count), cur = prev
        for i in 1...max(x.count, 1) where !x.isEmpty {
            cur[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let d = x.isEmpty ? y.count : prev[y.count]
        return 1 - Double(d) / Double(max(x.count, y.count))
    }

    /// Coarse sound key: c/k/q→k, z→s, ph→f, every vowel run → "a", doubled letters collapsed.
    /// ("sklite" and "sqlite" agree; "stores" and "postgres" do not.)
    static func phonetic(_ s: String) -> String {
        var out: [Character] = []
        let chars = Array(s.replacingOccurrences(of: "ph", with: "f"))
        for c in chars {
            let m: Character
            switch c {
            case "c", "k", "q": m = "k"
            case "z": m = "s"
            case "a", "e", "i", "o", "u", "y": m = "a"
            default: m = c
            }
            if out.last != m { out.append(m) }
        }
        return String(out)
    }

    /// The most frequent English words (function words + very common content words). A single one
    /// of these being rewritten into a list term is almost always a false insertion.
    static let commonWords: Set<String> = Set("""
    a about after again all also always an and any are around as ask at back be because been before being best \
    between big both but by call came can case change come could day did different do does done down each early \
    end even every fact far feel few find first for found from get give go going good got great group had hand \
    has have he help her here high him his home how i if important in into is it its just keep kind know large \
    last late least left less let life like line little long look made make man many may me might more most move \
    much must my need never new next no not now number of off old on once one only open or other our out over \
    own part people place point post problem public put right run said same saw say see seem set she should show \
    side since small so some start state still store stores story such sure system take tell than that the their \
    them then there these they thing think this those though three through time to today too took two under until \
    up us use used very want was water way we week well went were what when where which while who why will with \
    word work world would write year yes yet you your
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}

/// A booster that replaces scripted words — for tests and the Lab, where no CTC model is loaded.
/// `rewrites` maps a lower-cased hypothesis word to the vocabulary term that should replace it,
/// and only fires when that term is in `terms` (so an empty vocabulary is an identity).
public struct ScriptedVocabularyBooster: VocabularyBooster {
    public let terms: [String]
    public let rewrites: [String: String]
    public init(terms: [String], rewrites: [String: String]) {
        self.terms = terms
        self.rewrites = rewrites
    }

    public func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? {
        let allowed = Set(terms.map { $0.lowercased() })
        var replaced: [BoostOutcome.Replacement] = []
        let words = BoostAlignment.words(tokens).map { w -> String in
            if let r = rewrites[w.key], allowed.contains(r.lowercased()) {
                replaced.append(.init(original: w.text, replacement: r))
                return r
            }
            return w.text
        }
        guard !replaced.isEmpty else { return nil }
        return BoostOutcome(tokens: BoostAlignment.apply(rescoredText: words.joined(separator: " "), to: tokens),
                            replacements: replaced, detectedTerms: replaced.map(\.replacement))
    }
}

extension StageID {
    /// N11 — a word the vocabulary booster swapped in. Lower confidence; treat as uncertain.
    public static let boosted: StageID = "asr.boosted"
}

/// N11 — tags boosted words on the way from tokens to spans.
public enum BoostTag {
    /// `WordConfidence.spans`, plus `.boosted` in the provenance of every word that contains a
    /// booster replacement token. Confidence / audio range / alternates are untouched.
    public static func spans(from tokens: [DecodedToken], timeOffset: TimeInterval = 0) -> [TranscriptSpan] {
        let words = WordConfidence.aggregate(tokens)
        var spans = WordConfidence.spans(from: tokens, timeOffset: timeOffset)
        guard words.count == spans.count else { return spans }
        for i in spans.indices where words[i].tokens.contains(where: { $0.tokenId == BoostAlignment.replacementTokenId }) {
            if !spans[i].provenance.contains(.boosted) { spans[i].provenance.append(.boosted) }
        }
        return spans
    }

    public static func isBoosted(_ span: TranscriptSpan) -> Bool { span.provenance.contains(.boosted) }
}
