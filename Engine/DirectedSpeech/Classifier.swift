import Foundation

/// P5.1 — logistic regression over `DirectedSpeechFeatures`. Weights are hand-initialised (no training
/// corpus of real users exists) and nudged online by "not you" corrections. Lives in RAM only.
public final class DirectedSpeechClassifier: @unchecked Sendable {
    public private(set) var weights: [Double]
    public private(set) var bias: Double
    public var threshold: Double
    public var learningRate: Double
    public private(set) var correctionCount = 0
    private let lock = NSLock()

    /// Order matches `DirectedSpeechFeatures.names`.
    public static let handInitialisedWeights: [Double] = [
        1.0,   // snrDB — near-field, clean speech
        2.0,   // meanLevelDB — louder = closer (far-field is ~-9 dB)
        0.0,   // energyContourSlope — neutral until learned
        1.0,   // voicedRatio — overheard / far-field / white noise loses harmonic structure
        -0.9,  // zeroCrossingRate — broadband noise
        0.2,   // speakingRate
        2.6,   // keywordScore — leading verb / address form (strongest cue on the corpus)
        -1.5,  // previewEmpty — no words recognised
        0.9,   // isTextFieldFocused
        1.2,   // addressedRecently
    ]
    public static let handInitialisedBias = -2.85

    public init(weights: [Double] = DirectedSpeechClassifier.handInitialisedWeights, bias: Double = DirectedSpeechClassifier.handInitialisedBias,
                threshold: Double = 0.5, learningRate: Double = 0.15) {
        precondition(weights.count == DirectedSpeechFeatures.names.count)
        self.weights = weights; self.bias = bias; self.threshold = threshold; self.learningRate = learningRate
    }

    public func probability(_ f: DirectedSpeechFeatures) -> Double {
        lock.lock(); defer { lock.unlock() }
        let z = zip(weights, f.vector).reduce(bias) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-z))
    }

    public func isDirected(_ f: DirectedSpeechFeatures) -> Bool { probability(f) >= threshold }

    /// Online SGD step. `directed == false` is the "not you" correction; `true` is an explicit
    /// "yes, that was me" (e.g. the user re-issued via hotkey right after a miss).
    public func update(_ f: DirectedSpeechFeatures, directed: Bool) {
        let p = probability(f)
        lock.lock(); defer { lock.unlock() }
        let err = (directed ? 1.0 : 0.0) - p
        for (i, x) in f.vector.enumerated() { weights[i] += learningRate * err * x }
        bias += learningRate * err
        correctionCount += 1
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        weights = Self.handInitialisedWeights; bias = Self.handInitialisedBias; correctionCount = 0
    }
}
