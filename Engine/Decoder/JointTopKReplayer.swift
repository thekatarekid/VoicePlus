@preconcurrency import CoreML
import FluidAudio
import Foundation

/// V5 B3 — real N-best candidates from the Parakeet TDT joint.
///
/// Upstream's greedy decoder (`AsrManager`) reads the joint's `top_k_ids` / `top_k_logits` only for
/// its language filter and does not return them. This replays the *already chosen* token path
/// through the same CoreML models (`AsrModels` is shared, nothing is loaded twice): preprocessor +
/// encoder once over the utterance, then for each emitted token the prediction network on the
/// previous token and the joint at the token's emission frame — exactly the step at which greedy
/// chose it. The joint's top-K logits become full-vocabulary log-probabilities via the step's
/// argmax probability (`token_prob`): `logP(i) = ln p(argmax) + logit(i) − logit(argmax)`.
///
/// Cost: one extra encoder pass plus one decoder + one joint call per token. `FluidAudioTDTDecoder`
/// only asks for it on the final pass and only when some token is uncertain.
/// Joint models without top-K outputs (v2 `JointDecision`) are not supported → `init` returns nil.
public final class JointTopKReplayer: TokenAlternativesProviding, @unchecked Sendable {
    private let preprocessor: MLModel
    private let encoder: MLModel?
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: [Int: String]
    private let blankId: Int
    private let encoderHidden: Int
    private let decoderLayers: Int
    private let lock = NSLock()

    static let decoderHidden = ASRConstants.decoderHiddenSize
    static let samplesPerFrame = ASRConstants.samplesPerEncoderFrame
    static let frameSeconds = ASRConstants.secondsPerEncoderFrame
    /// Whole encoder frames per model window (240 000 samples is 187.5 frames).
    static let windowFrames = ASRConstants.maxModelSamples / ASRConstants.samplesPerEncoderFrame
    /// Upstream reports a token's start one frame before the frame that emitted it.
    static let emissionDelayFrames = 1

    public init?(models: AsrModels) {
        let outs = models.joint.modelDescription.outputDescriptionsByName
        guard outs["top_k_ids"] != nil, outs["top_k_logits"] != nil, outs["token_prob"] != nil else { return nil }
        preprocessor = models.preprocessor
        encoder = models.encoder
        decoder = models.decoder
        joint = models.joint
        vocabulary = models.vocabulary
        blankId = models.version.blankId
        encoderHidden = models.version.encoderHiddenSize
        decoderLayers = models.version.decoderLayers
    }

    public func alternatives(for tokens: [DecodedToken], samples: [Float], k: Int) async throws -> [[TokenAlternative]] {
        guard !tokens.isEmpty, k > 0, !samples.isEmpty else { return tokens.map { _ in [] } }
        return try lock.withLock { try replay(tokens: tokens, samples: samples, k: k) }
    }

    // MARK: - Replay

    private func replay(tokens: [DecodedToken], samples: [Float], k: Int) throws -> [[TokenAlternative]] {
        let windowSamples = Self.windowFrames * Self.samplesPerFrame
        var encoders: [Int: EncoderWindow] = [:]
        var state = try DecoderState(layers: decoderLayers)
        var previous = blankId
        var out: [[TokenAlternative]] = []
        out.reserveCapacity(tokens.count)
        for token in tokens {
            let decoderStep = try runDecoder(previous: previous, state: &state)
            previous = token.tokenId
            let globalFrame = max(0, Int((token.startTime / Self.frameSeconds).rounded()) + Self.emissionDelayFrames)
            let w = globalFrame / Self.windowFrames
            if encoders[w] == nil {
                let start = w * windowSamples
                guard start < samples.count else { out.append([]); continue }
                encoders[w] = try runEncoder(Array(samples[start..<min(samples.count, start + windowSamples)]))
            }
            guard let enc = encoders[w], enc.frames > 0 else { out.append([]); continue }
            let frame = min(globalFrame - w * Self.windowFrames, enc.frames - 1)
            out.append(try runJoint(encoder: enc, frame: frame, decoderStep: decoderStep,
                                    chosen: token.tokenId, k: k))
        }
        return out
    }

    private struct EncoderWindow {
        let array: MLMultiArray
        let frames: Int
        let timeStride: Int
        let hiddenStride: Int
    }

    private func runEncoder(_ window: [Float]) throws -> EncoderWindow {
        let aligned = (window.count + Self.samplesPerFrame - 1) / Self.samplesPerFrame * Self.samplesPerFrame
        let padded = max(ASRConstants.maxModelSamples, aligned)
        let audio = try MLMultiArray(shape: [1, NSNumber(value: padded)], dataType: .float32)
        let ptr = audio.dataPointer.bindMemory(to: Float.self, capacity: padded)
        ptr.initialize(repeating: 0, count: padded)
        window.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: window.count) }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: min(aligned, padded))
        let pre = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audio), "audio_length": MLFeatureValue(multiArray: length),
        ])
        let preOut = try preprocessor.prediction(from: pre)
        let encOut: MLFeatureProvider
        if let encoder {
            var features: [String: MLFeatureValue] = [:]
            for name in encoder.modelDescription.inputDescriptionsByName.keys {
                guard let v = preOut.featureValue(for: name) ?? pre.featureValue(for: name) else {
                    throw ReplayError.missing("encoder input \(name)")
                }
                features[name] = v
            }
            encOut = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        } else {
            encOut = preOut
        }
        guard let enc = encOut.featureValue(for: "encoder")?.multiArrayValue else { throw ReplayError.missing("encoder") }
        let valid = encOut.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue ?? Int.max
        let shape = enc.shape.map(\.intValue), strides = enc.strides.map(\.intValue)
        guard shape.count == 3, enc.dataType == .float32 else { throw ReplayError.layout("encoder \(shape)") }
        let hiddenAxis = shape[1] == encoderHidden ? 1 : (shape[2] == encoderHidden ? 2 : -1)
        guard hiddenAxis > 0 else { throw ReplayError.layout("encoder hidden \(shape)") }
        let timeAxis = hiddenAxis == 1 ? 2 : 1
        return EncoderWindow(array: enc, frames: min(valid, shape[timeAxis]),
                             timeStride: strides[timeAxis], hiddenStride: strides[hiddenAxis])
    }

    private struct DecoderState {
        var h: MLMultiArray
        var c: MLMultiArray
        init(layers: Int) throws {
            let shape: [NSNumber] = [NSNumber(value: layers), 1, NSNumber(value: JointTopKReplayer.decoderHidden)]
            h = try MLMultiArray(shape: shape, dataType: .float32)
            c = try MLMultiArray(shape: shape, dataType: .float32)
            for a in [h, c] {
                a.dataPointer.bindMemory(to: Float.self, capacity: a.count).initialize(repeating: 0, count: a.count)
            }
        }
    }

    /// Prediction network on `previous` → the decoder projection the joint consumes (contiguous [hidden]).
    private func runDecoder(previous: Int, state: inout DecoderState) throws -> [Float] {
        let target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        target[0] = NSNumber(value: previous)
        let targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: target), "target_length": MLFeatureValue(multiArray: targetLength),
            "h_in": MLFeatureValue(multiArray: state.h), "c_in": MLFeatureValue(multiArray: state.c),
        ]))
        guard let proj = out.featureValue(for: "decoder")?.multiArrayValue,
              let h = out.featureValue(for: "h_out")?.multiArrayValue,
              let c = out.featureValue(for: "c_out")?.multiArrayValue else { throw ReplayError.missing("decoder outputs") }
        state.h = h
        state.c = c
        return try Self.vector(proj, size: Self.decoderHidden)
    }

    private func runJoint(encoder enc: EncoderWindow, frame: Int, decoderStep: [Float], chosen: Int, k: Int) throws -> [TokenAlternative] {
        let inputs = joint.modelDescription.inputDescriptionsByName
        let encShape = inputs["encoder_step"]?.multiArrayConstraint?.shape ?? [1, NSNumber(value: encoderHidden), 1]
        let decShape = inputs["decoder_step"]?.multiArrayConstraint?.shape ?? [1, NSNumber(value: Self.decoderHidden), 1]
        let encStep = try MLMultiArray(shape: encShape, dataType: .float32)
        let decStep = try MLMultiArray(shape: decShape, dataType: .float32)
        let src = enc.array.dataPointer.bindMemory(to: Float.self, capacity: enc.array.count)
        let dst = encStep.dataPointer.bindMemory(to: Float.self, capacity: encStep.count)
        let base = frame * enc.timeStride
        for i in 0..<min(encoderHidden, encStep.count) { dst[i] = src[base + i * enc.hiddenStride] }
        let ddst = decStep.dataPointer.bindMemory(to: Float.self, capacity: decStep.count)
        for i in 0..<min(decoderStep.count, decStep.count) { ddst[i] = decoderStep[i] }
        let out = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encStep), "decoder_step": MLFeatureValue(multiArray: decStep),
        ]))
        guard let ids = out.featureValue(for: "top_k_ids")?.multiArrayValue,
              let logits = out.featureValue(for: "top_k_logits")?.multiArrayValue,
              let prob = out.featureValue(for: "token_prob")?.multiArrayValue else { throw ReplayError.missing("joint top-K") }
        let n = min(ids.count, logits.count)
        let pairs = (0..<n).map { (ids[$0].intValue, logits[$0].floatValue) }
        return Self.candidates(pairs: pairs, argmaxProbability: prob[0].floatValue, chosen: chosen,
                               blankId: blankId, vocabulary: vocabulary, k: k)
    }

    /// Top-K (id, logit) → full-vocabulary log-probabilities, excluding the chosen token and blank,
    /// best first, at most `k`. Exposed for unit tests.
    static func candidates(pairs: [(Int, Float)], argmaxProbability: Float, chosen: Int, blankId: Int,
                           vocabulary: [Int: String], k: Int) -> [TokenAlternative] {
        guard let maxLogit = pairs.map(\.1).max() else { return [] }
        let lp1 = log(min(max(argmaxProbability, Float.leastNormalMagnitude), 1))
        return pairs.sorted { $0.1 > $1.1 }
            .filter { $0.0 != chosen && $0.0 != blankId }
            .compactMap { id, logit in
                guard let text = vocabulary[id], !text.isEmpty else { return nil }
                return TokenAlternative(tokenId: id, text: text, logProb: min(0, lp1 + logit - maxLogit))
            }
            .prefix(k).map { $0 }
    }

    private static func vector(_ a: MLMultiArray, size: Int) throws -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        guard let axis = shape.firstIndex(of: size), a.dataType == .float32 else { throw ReplayError.layout("decoder \(shape)") }
        let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        return (0..<size).map { p[$0 * strides[axis]] }
    }

    enum ReplayError: Error, CustomStringConvertible {
        case missing(String)
        case layout(String)
        var description: String {
            switch self {
            case .missing(let s): return "JointTopKReplayer: missing \(s)"
            case .layout(let s): return "JointTopKReplayer: unexpected layout \(s)"
            }
        }
    }
}
