import Foundation

// FROZEN INTERFACE (P1.3 T1). See Engine/Decoder/README.md before changing anything here.
// P1.5 (biasing) implements `LogitBiaser`; P1.6 (beam/alternates) implements `Decoder`.

/// One decoded sub-word token with its acoustic position and score.
public struct DecodedToken: Equatable, Hashable, Sendable, Codable {
    /// Vocabulary id (SentencePiece id for Parakeet; blank tokens are never emitted).
    public var tokenId: Int
    /// Token text as the tokenizer renders it. Word starts carry a leading "▁" (U+2581)
    /// for SentencePiece models; `isWordStart` normalises this.
    public var text: String
    /// Natural log of the probability of the chosen token (≤ 0). `log(1) == 0`.
    public var logProb: Float
    /// Seconds from utterance start (80 ms quantised for Parakeet TDT).
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(tokenId: Int, text: String, logProb: Float, startTime: TimeInterval, endTime: TimeInterval) {
        self.tokenId = tokenId
        self.text = text
        self.logProb = logProb
        self.startTime = startTime
        self.endTime = min(max(endTime, startTime), .greatestFiniteMagnitude)
    }

    /// Linear probability, clamped to 0…1.
    public var probability: Float { min(max(exp(logProb), 0), 1) }

    /// True if this token begins a new word (SentencePiece "▁" prefix or leading whitespace).
    public var isWordStart: Bool {
        text.hasPrefix("\u{2581}") || text.first?.isWhitespace == true
    }

    /// Text with the SentencePiece word marker / leading whitespace stripped.
    public var strippedText: String {
        var s = text
        if s.hasPrefix("\u{2581}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Encoder output for one utterance (or one streaming chunk). Layout is row-major
/// `[frames][hiddenSize]`; `frameDuration` converts frame index → seconds.
public struct EncoderFrames: Sendable {
    public var values: [Float]
    public var frameCount: Int
    public var hiddenSize: Int
    /// Seconds per encoder frame (0.08 for Parakeet TDT).
    public var frameDuration: TimeInterval
    /// Offset (seconds) of frame 0 relative to the utterance start — non-zero for chunked decoding.
    public var timeOffset: TimeInterval

    public init(values: [Float], frameCount: Int, hiddenSize: Int, frameDuration: TimeInterval = 0.08, timeOffset: TimeInterval = 0) {
        self.values = values
        self.frameCount = frameCount
        self.hiddenSize = hiddenSize
        self.frameDuration = frameDuration
        self.timeOffset = timeOffset
    }

    public func frame(_ index: Int) -> ArraySlice<Float> {
        values[(index * hiddenSize)..<((index + 1) * hiddenSize)]
    }
}

/// Prefix-dependent state a `LogitBiaser` can inspect (what has been decoded so far).
public struct PrefixState: Sendable {
    /// Token ids emitted so far in this utterance, oldest first.
    public var tokenIds: [Int]
    /// Rendered text so far (tokenizer-joined, word markers stripped).
    public var text: String
    /// Current encoder frame index.
    public var frameIndex: Int

    public init(tokenIds: [Int] = [], text: String = "", frameIndex: Int = 0) {
        self.tokenIds = tokenIds
        self.text = text
        self.frameIndex = frameIndex
    }
}

/// Decode-time bias hook (Bet 2). The decoder calls `boost` once per emission step with the
/// candidate token ids the joint network exposed (top-K). Return additive log-prob bonuses
/// keyed by token id; absent ids get 0. Implementations must be cheap (called per step).
public protocol LogitBiaser: Sendable {
    /// - Parameters:
    ///   - tokenIds: candidate ids at this step (top-K from the joint; never includes blank).
    ///   - prefixState: what has been decoded so far.
    /// - Returns: `[tokenId: bonus]` in natural-log units; positive boosts, negative suppresses.
    func boost(tokenIds: [Int], prefixState: PrefixState) -> [Int: Float]
}

/// Decoder output: tokens plus the overall sequence score.
public struct DecodeResult: Equatable, Sendable {
    public var tokens: [DecodedToken]
    /// Sum of token log-probs (≤ 0).
    public var score: Float

    public init(tokens: [DecodedToken], score: Float? = nil) {
        self.tokens = tokens
        self.score = score ?? tokens.reduce(0) { $0 + $1.logProb }
    }

    /// Plain text: word-start tokens are space-separated, continuation tokens concatenated.
    public var text: String { tokens.renderedText }
}

/// The frozen decoder contract. `FluidAudioTDTDecoder` wraps the upstream greedy TDT;
/// P1.6 adds a beam decoder behind the same protocol. Decoders are stateful per utterance
/// (`reset()` between utterances); chunks of one utterance are passed in order.
public protocol Decoder: AnyObject, Sendable {
    /// Human-readable name for logs / Lab reports.
    var name: String { get }
    /// Installed bias hook, or nil. Set before `decode`.
    var biaser: LogitBiaser? { get set }
    /// Decode one batch of encoder frames. Tokens are absolute-time (offset applied).
    func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult
    /// Clear per-utterance state (decoder LSTM state, prefix).
    func reset() async
}

public extension Array where Element == DecodedToken {
    /// Tokenizer-joined text (SentencePiece aware).
    var renderedText: String {
        var out = ""
        for t in self {
            let piece = t.strippedText
            if piece.isEmpty { continue }
            if t.isWordStart && !out.isEmpty { out += " " }
            out += piece
        }
        return out
    }
}
