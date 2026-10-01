import Accelerate
import CoreML
import Foundation
import Shared

// V5 C4 — Smart Turn endpointing.
//
// Smart Turn v3 (pipecat-ai/smart-turn-v3, BSD-2-Clause — licence verified on the model card and
// the pipecat-ai/smart-turn repository; attribution goes in Packaging/model-notices when the
// CoreML export ships) is a ~8 MB Whisper-tiny-encoder classifier: given the last ≤ 8 s of 16 kHz
// audio ending in a short silence, it returns the probability that the speaker has finished their
// turn. `Endpointer` asks it once per pause, only after ≥ 400 ms of trailing silence, and ends the
// segment early when it says "complete". Missing model → never asked → the plain silence timeout.
//
// The upstream release is ONNX only; the CoreML export (`smart-turn-v3.mlmodelc`, input
// `input_features` [1, 80, 800] Float32, one scalar output) is produced offline and installed
// under `Models/smart-turn-v3/`. Until then `SmartTurnModel.loadIfAvailable()` returns nil.

/// "Has the speaker finished?" for a stretch of 16 kHz mono audio ending at the current moment.
/// Returns a probability in 0...1, or nil when it cannot tell (treated as "not complete").
public protocol TurnCompletionPredicting: Sendable {
    func probabilityComplete(_ audio16k: [Float]) -> Float?
}

/// Whisper-style log-mel features exactly as Smart Turn v3 was trained on them
/// (`WhisperFeatureExtractor`: n_fft 400, hop 160, 80 Slaney mels, log10, max−8 floor, (x+4)/4),
/// over the last 8 s of audio, zero-mean/unit-variance normalised and left-padded with zeros.
public struct SmartTurnFeatures: Sendable {
    public static let sampleRate = 16_000
    public static let seconds = 8
    public static let nFFT = 400
    public static let hop = 160
    public static let melBins = 80
    public static let frames = 800
    public static var windowSamples: Int { sampleRate * seconds }
    static let bins = nFFT / 2 + 1

    /// [bins × melBins], row-major.
    private let melFilterT: [Float]
    /// [nFFT × bins] real/imaginary DFT bases with the Hann window folded in, row-major.
    private let cosBasis: [Float]
    private let sinBasis: [Float]

    public init() {
        melFilterT = Self.slaneyMelFilterT()
        var c = [Float](repeating: 0, count: Self.nFFT * Self.bins)
        var s = c
        for n in 0..<Self.nFFT {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.nFFT))   // periodic Hann
            for k in 0..<Self.bins {
                let phase = 2 * Double.pi * Double(k * n) / Double(Self.nFFT)
                c[n * Self.bins + k] = Float(w * cos(phase))
                s[n * Self.bins + k] = Float(-w * sin(phase))
            }
        }
        cosBasis = c; sinBasis = s
    }

    /// The last 8 s, normalised, left-padded to exactly 8 s.
    public static func prepare(_ audio: [Float]) -> [Float] {
        let tail = audio.count > windowSamples ? Array(audio.suffix(windowSamples)) : audio
        guard !tail.isEmpty else { return [Float](repeating: 0, count: windowSamples) }
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(tail, 1, nil, 1, &mean, &std, vDSP_Length(tail.count))
        let scale = 1 / (std * std + 1e-7).squareRoot()
        var normalized = tail.map { ($0 - mean) * scale }
        if normalized.count < windowSamples {
            normalized = [Float](repeating: 0, count: windowSamples - normalized.count) + normalized
        }
        return normalized
    }

    /// Log-mel features, [melBins × frames] row-major (the model's [1, 80, 800] without the batch axis).
    public func features(_ audio: [Float]) -> [Float] {
        let x = Self.prepare(audio)
        // center=True: reflect-pad n_fft/2 on both sides.
        let pad = Self.nFFT / 2
        var padded = [Float](repeating: 0, count: x.count + 2 * pad)
        for i in 0..<pad {
            padded[pad - 1 - i] = x[i + 1]
            padded[pad + x.count + i] = x[x.count - 2 - i]
        }
        padded.replaceSubrange(pad..<(pad + x.count), with: x)

        // Frames [frames × nFFT] (the 801st frame is dropped, as Whisper does).
        let F = Self.frames, N = Self.nFFT, B = Self.bins, M = Self.melBins
        var framed = [Float](repeating: 0, count: F * N)
        padded.withUnsafeBufferPointer { src in
            framed.withUnsafeMutableBufferPointer { dst in
                for f in 0..<F {
                    let start = f * Self.hop
                    dst.baseAddress!.advanced(by: f * N).update(from: src.baseAddress!.advanced(by: start), count: N)
                }
            }
        }
        var re = [Float](repeating: 0, count: F * B), im = re
        vDSP_mmul(framed, 1, cosBasis, 1, &re, 1, vDSP_Length(F), vDSP_Length(B), vDSP_Length(N))
        vDSP_mmul(framed, 1, sinBasis, 1, &im, 1, vDSP_Length(F), vDSP_Length(B), vDSP_Length(N))
        var power = [Float](repeating: 0, count: F * B)
        vDSP_vmma(re, 1, re, 1, im, 1, im, 1, &power, 1, vDSP_Length(F * B))
        var mel = [Float](repeating: 0, count: F * M)   // [frames × mels]
        vDSP_mmul(power, 1, melFilterT, 1, &mel, 1, vDSP_Length(F), vDSP_Length(M), vDSP_Length(B))

        var logMel = mel.map { log10(max($0, 1e-10)) }
        let peak = logMel.max() ?? 0
        for i in logMel.indices { logMel[i] = (max(logMel[i], peak - 8) + 4) / 4 }
        // Transpose to [mels × frames].
        var out = [Float](repeating: 0, count: M * F)
        vDSP_mtrans(logMel, 1, &out, 1, vDSP_Length(M), vDSP_Length(F))
        return out
    }

    /// librosa `mel(sr=16000, n_fft=400, n_mels=80, htk=False, norm="slaney")`, transposed.
    static func slaneyMelFilterT() -> [Float] {
        func hzToMel(_ f: Double) -> Double {
            let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27
            return f < minLogHz ? f / fSp : minLogMel + log(f / minLogHz) / logStep
        }
        func melToHz(_ m: Double) -> Double {
            let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27
            return m < minLogMel ? m * fSp : minLogHz * exp(logStep * (m - minLogMel))
        }
        let M = melBins, B = bins
        let lo = hzToMel(0), hi = hzToMel(Double(sampleRate) / 2)
        let melF = (0..<(M + 2)).map { melToHz(lo + (hi - lo) * Double($0) / Double(M + 1)) }
        let fftF = (0..<B).map { Double($0) * Double(sampleRate) / Double(nFFT) }
        var w = [Float](repeating: 0, count: B * M)
        for m in 0..<M {
            let d0 = melF[m + 1] - melF[m], d1 = melF[m + 2] - melF[m + 1]
            let enorm = 2 / (melF[m + 2] - melF[m])
            for k in 0..<B {
                let lower = (fftF[k] - melF[m]) / d0
                let upper = (melF[m + 2] - fftF[k]) / d1
                w[k * M + m] = Float(max(0, min(lower, upper)) * enorm)
            }
        }
        return w
    }
}

/// Where the CoreML export of Smart Turn lives. Never downloads.
public struct SmartTurnModelLocator: Sendable {
    public static let folderName = "smart-turn-v3"
    public static let fileName = "smart-turn-v3.mlmodelc"
    public var candidates: [URL]

    public init(candidates: [URL]? = nil) {
        self.candidates = candidates ?? {
            var urls = [ModelCatalog.modelsRoot().appendingPathComponent(Self.folderName).appendingPathComponent(Self.fileName)]
            if let res = Bundle.main.resourceURL {
                urls.append(res.appendingPathComponent("Models").appendingPathComponent(Self.folderName).appendingPathComponent(Self.fileName))
            }
            return urls
        }()
    }

    public func resolve(fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// Smart Turn v3 over CoreML. Loaded through `ModelResidency` (§10), `.onDemand` (8 MB, idle-unloadable;
/// re-acquired before every prediction).
public final class SmartTurnModel: TurnCompletionPredicting, @unchecked Sendable {
    public static let approxBytes: Int64 = 8_700_000
    private let features = SmartTurnFeatures()
    private let box: SmartTurnBox
    private let residency: ModelResidency?
    private let key: String
    private let lock = NSLock()

    deinit {
        if let residency { let key = key; Task { await residency.unregister(key) } }
    }

    private init(box: SmartTurnBox, residency: ModelResidency?, key: String) {
        self.box = box; self.residency = residency; self.key = key
    }

    public static func loadIfAvailable(locator: SmartTurnModelLocator = SmartTurnModelLocator(),
                                       residency: ModelResidency? = .shared) async -> SmartTurnModel? {
        guard let file = locator.resolve() else {
            Log.engine.info("smart-turn: model not installed; endpointing on silence only")
            return nil
        }
        let box = SmartTurnBox()
        let load: @Sendable () throws -> Void = {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            box.set(try MLModel(contentsOf: file, configuration: config))
        }
        let key = "vad.smart-turn#\(UUID().uuidString.prefix(8))"
        do {
            if let residency {
                await residency.register(key, tier: .onDemand, estimatedBytes: approxBytes * 2, owner: "vad.smart-turn",
                                         load: { try load() }, unload: { box.set(nil) })
                try await residency.acquire(key)
            } else {
                try load()
            }
        } catch {
            Log.engine.warning("smart-turn: load failed, endpointing on silence only: \(error)")
            if let residency { await residency.unregister(key) }
            return nil
        }
        Log.engine.info("smart-turn: model \(file.lastPathComponent) loaded")
        return SmartTurnModel(box: box, residency: residency, key: key)
    }

    public func probabilityComplete(_ audio16k: [Float]) -> Float? {
        guard let model = box.get() else {
            // Idle-unloaded by the residency: reload in the background, answer "unknown" this pause.
            if let residency { let key = key; Task { try? await residency.acquire(key) } }
            return nil
        }
        let feats = features.features(audio16k)
        lock.lock(); defer { lock.unlock() }
        do {
            let shape: [NSNumber] = [1, NSNumber(value: SmartTurnFeatures.melBins), NSNumber(value: SmartTurnFeatures.frames)]
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            feats.withUnsafeBufferPointer { src in
                array.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: feats.count)
            }
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input_features"
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            let out = try model.prediction(from: input)
            guard let name = model.modelDescription.outputDescriptionsByName.keys.sorted().first,
                  let value = out.featureValue(for: name)?.multiArrayValue, value.count > 0 else { return nil }
            return SmartTurnScore.probability(fromRaw: value[0].floatValue)
        } catch {
            Log.engine.warning("smart-turn: prediction failed: \(error)")
            return nil
        }
    }
}

enum SmartTurnScore {
    /// The ONNX export ends in a sigmoid; a CoreML export of the bare classifier gives a logit.
    static func probability(fromRaw raw: Float) -> Float {
        (0...1).contains(raw) ? raw : 1 / (1 + exp(-raw))
    }
}

private final class SmartTurnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var model: MLModel?
    func set(_ m: MLModel?) { lock.lock(); model = m; lock.unlock() }
    func get() -> MLModel? { lock.lock(); defer { lock.unlock() }; return model }
}

/// The pipeline's side of Smart Turn: the last 8 s of audio and the decision threshold.
/// Worker-only (not thread-safe), like the rest of `AudioPipeline`'s processing state.
public struct SmartTurnGate: Sendable {
    public let predictor: any TurnCompletionPredicting
    /// Probability at or above which a pause ends the turn (Smart Turn's own default).
    public var threshold: Float
    private(set) var audio: [Float] = []
    /// The last answer, for logging and tests.
    public private(set) var lastProbability: Float?

    public init(predictor: any TurnCompletionPredicting, threshold: Float = 0.5) {
        self.predictor = predictor
        self.threshold = threshold
    }

    public mutating func append(_ samples: [Float]) {
        audio.append(contentsOf: samples)
        let cap = SmartTurnFeatures.windowSamples
        if audio.count > cap * 2 { audio.removeFirst(audio.count - cap) }
    }

    public mutating func reset() { audio.removeAll(keepingCapacity: true); lastProbability = nil }

    /// True when the model says the turn is complete; nil when it could not tell.
    public mutating func isComplete() -> Bool? {
        let window = audio.count > SmartTurnFeatures.windowSamples ? Array(audio.suffix(SmartTurnFeatures.windowSamples)) : audio
        guard let p = predictor.probabilityComplete(window) else { lastProbability = nil; return nil }
        lastProbability = p
        return p >= threshold
    }
}
