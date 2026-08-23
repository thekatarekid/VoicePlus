import Foundation

/// Per-step candidate set a decoder exposes (top-K from the joint).
public struct StepCandidates: Sendable {
    public var ids: [Int]
    public var logits: [Float]
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public init(ids: [Int], logits: [Float], startTime: TimeInterval, endTime: TimeInterval) {
        self.ids = ids; self.logits = logits; self.startTime = startTime; self.endTime = endTime
    }
    public func logSoftmax() -> [Float] {
        let m = logits.max() ?? 0
        let z = log(logits.reduce(0) { $0 + exp($1 - m) }) + m
        return logits.map { $0 - z }
    }
}

/// Decoders that can expose per-step candidates — required for real (in-loop) biasing and
/// the narrow beam. `FluidAudioTDTDecoder` gains this once the fork hook lands.
public protocol StepwiseDecoder: Decoder {
    /// Candidates for the next emission given the prefix; nil when the utterance is exhausted.
    func candidates(step: Int, prefix: [Int], frames: EncoderFrames) -> StepCandidates?
    func pieceText(for tokenId: Int) -> String
}

/// Scripted fake decoder: a fixed list of top-K logit steps with a true re-argmax after
/// biasing. Exercises the full per-step `LogitBiaser` contract (unlike `MockDecoder`, which
/// can only rescore). The chosen token's `logProb` stays the unbiased probability (Bet 9).
public final class ScriptedLogitDecoder: StepwiseDecoder, @unchecked Sendable {
    public let name = "scripted-logits"
    public let steps: [StepCandidates]
    public let vocabulary: BiasVocabulary
    private let lock = NSLock()
    private var _biaser: LogitBiaser?
    private var prefix: [Int] = []
    private var cursor = 0

    public var biaser: LogitBiaser? {
        get { lock.withLock { _biaser } }
        set { lock.withLock { _biaser = newValue } }
    }

    public init(steps: [StepCandidates], vocabulary: BiasVocabulary) {
        self.steps = steps
        self.vocabulary = vocabulary
    }

    public func candidates(step: Int, prefix: [Int], frames: EncoderFrames) -> StepCandidates? {
        step < steps.count ? steps[step] : nil
    }

    public func pieceText(for tokenId: Int) -> String {
        tokenId >= 0 && tokenId < vocabulary.pieces.count ? vocabulary.pieces[tokenId] : "<unk>"
    }

    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        decodeSync(encoderFrames)
    }

    private func decodeSync(_ encoderFrames: EncoderFrames) -> DecodeResult {
        lock.lock(); defer { lock.unlock() }
        var out: [DecodedToken] = []
        while let step = candidates(step: cursor, prefix: prefix, frames: encoderFrames) {
            cursor += 1
            let state = PrefixState(tokenIds: prefix, text: out.renderedText, frameIndex: cursor)
            let bonus = _biaser?.boost(tokenIds: step.ids, prefixState: state) ?? [:]
            var bestIdx = 0
            var bestScore = -Float.infinity
            for (i, id) in step.ids.enumerated() {
                let s = step.logits[i] + (bonus[id] ?? 0)
                if s > bestScore { bestScore = s; bestIdx = i }
            }
            let id = step.ids[bestIdx]
            let lp = step.logSoftmax()[bestIdx]
            out.append(DecodedToken(tokenId: id, text: pieceText(for: id), logProb: lp, startTime: step.startTime, endTime: step.endTime))
            prefix.append(id)
        }
        return DecodeResult(tokens: out)
    }

    public func reset() async { lock.withLock { prefix.removeAll(); cursor = 0 } }

    /// Builds steps where `truth` is the intended token path but the acoustics prefer
    /// `confusable` at the given step indices by `margin` logits. Used by the Lab's synthetic suite.
    public static func script(truth: [Int], confusions: [Int: (wrongId: Int, margin: Float)], distractors: [Int] = [], stepDuration: TimeInterval = 0.08) -> [StepCandidates] {
        truth.enumerated().map { i, id in
            var ids = [id]
            var logits: [Float] = [5]
            if let c = confusions[i] {
                ids.append(c.wrongId); logits.append(5 + c.margin)
            }
            for d in distractors.prefix(3) where !ids.contains(d) { ids.append(d); logits.append(0) }
            return StepCandidates(ids: ids, logits: logits, startTime: Double(i) * stepDuration, endTime: Double(i + 1) * stepDuration)
        }
    }
}
