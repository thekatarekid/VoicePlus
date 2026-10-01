import Foundation

/// Model output for one utterance: per-frame log-probabilities over the vocabulary (blank = 0).
public struct CTCOutput: Equatable, Sendable {
    public var logProbs: [[Float]]
    /// Seconds per output frame (Auto-AVSR: 40 ms — one video frame).
    public var frameDuration: TimeInterval
    public init(logProbs: [[Float]], frameDuration: TimeInterval) {
        self.logProbs = logProbs; self.frameDuration = frameDuration
    }
}

/// SentencePiece-style vocabulary: index 0 is the CTC blank, `▁` starts a word.
public struct AVSRVocabulary: Equatable, Sendable {
    public var tokens: [String]
    public static let wordMarker = "\u{2581}"
    public init(tokens: [String]) { self.tokens = tokens }

    /// `tokens.txt`: one token per line, optionally followed by a space and an index (k2/ESPnet style).
    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        tokens = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.split(separator: " ").first ?? "") }
        while tokens.last == "" { tokens.removeLast() }
    }

    public func piece(_ id: Int) -> String { id >= 0 && id < tokens.count ? tokens[id] : "" }
}

/// One decoded token: id, the frame where it peaked, and its log-probability there.
public struct CTCToken: Equatable, Sendable {
    public var id: Int
    public var frame: Int
    public var logProb: Float
}

/// CTC prefix beam search on the CPU (LR2 — Auto-AVSR's encoder runs in CoreML, the search here).
public struct CTCPrefixBeamSearch: Sendable {
    public var beamWidth: Int
    /// Tokens per frame considered (top-k pruning).
    public var tokensPerFrame: Int
    public var blank: Int

    public init(beamWidth: Int = 10, tokensPerFrame: Int = 12, blank: Int = 0) {
        self.beamWidth = beamWidth; self.tokensPerFrame = tokensPerFrame; self.blank = blank
    }

    private struct Beam {
        var pBlank: Float      // log P(prefix, ending in blank)
        var pNonBlank: Float   // log P(prefix, ending in its last token)
        var tokens: [CTCToken]
        /// Probability of the path whose token alignment `tokens` records (the strongest contributor).
        var alignmentScore: Float = -.infinity
        var total: Float { ctcLogAdd(pBlank, pNonBlank) }
    }

    /// Best hypothesis (token ids with peak frames) and its total log-probability.
    public func decode(_ output: CTCOutput) -> (tokens: [CTCToken], logProb: Float) {
        var beams: [[Int]: Beam] = [[]: Beam(pBlank: 0, pNonBlank: -.infinity, tokens: [])]
        for (t, frame) in output.logProbs.enumerated() {
            let candidates = frame.indices.sorted { frame[$0] > frame[$1] }.prefix(tokensPerFrame)
            var next: [[Int]: Beam] = [:]
            func add(_ key: [Int], blank: Float, nonBlank: Float, tokens: [CTCToken]) {
                let contribution = ctcLogAdd(blank, nonBlank)
                if var b = next[key] {
                    b.pBlank = ctcLogAdd(b.pBlank, blank); b.pNonBlank = ctcLogAdd(b.pNonBlank, nonBlank)
                    if contribution > b.alignmentScore { b.tokens = tokens; b.alignmentScore = contribution }
                    next[key] = b
                } else {
                    next[key] = Beam(pBlank: blank, pNonBlank: nonBlank, tokens: tokens, alignmentScore: contribution)
                }
            }
            for (prefix, beam) in beams {
                for c in candidates {
                    let p = frame[c]
                    if c == blank {
                        add(prefix, blank: beam.total + p, nonBlank: -.infinity, tokens: beam.tokens)
                        continue
                    }
                    let last = prefix.last
                    var extended = prefix; extended.append(c)
                    var tokens = beam.tokens; tokens.append(CTCToken(id: c, frame: t, logProb: p))
                    if c == last {
                        // Repeat without a blank between collapses into the same prefix…
                        var same = beam.tokens
                        if var lastTok = same.last, p > lastTok.logProb {
                            lastTok.frame = t; lastTok.logProb = p; same[same.count - 1] = lastTok
                        }
                        add(prefix, blank: -.infinity, nonBlank: beam.pNonBlank + p, tokens: same)
                        // …only a blank in between starts a new token.
                        add(extended, blank: -.infinity, nonBlank: beam.pBlank + p, tokens: tokens)
                    } else {
                        add(extended, blank: -.infinity, nonBlank: beam.total + p, tokens: tokens)
                    }
                }
            }
            beams = Dictionary(uniqueKeysWithValues: next.sorted { $0.value.total > $1.value.total }
                .prefix(beamWidth).map { ($0.key, $0.value) })
        }
        guard let best = beams.max(by: { $0.value.total < $1.value.total }) else { return ([], -.infinity) }
        return (best.value.tokens, best.value.total)
    }
}

@inline(__always) func ctcLogAdd(_ a: Float, _ b: Float) -> Float {
    if a == -.infinity { return b }
    if b == -.infinity { return a }
    let m = max(a, b)
    return m + log(exp(a - m) + exp(b - m))
}
