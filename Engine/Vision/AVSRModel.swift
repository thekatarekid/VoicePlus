import CoreML
import Foundation
import Shared

// V5 LR2 — Auto-AVSR (mpc001/auto_avsr) converted to CoreML: visual front-end (3D conv + ResNet-18)
// and, for the fused model, the raw-waveform audio front-end, Conformer encoder and fusion MLP, with
// the CTC head — exported as one program per variant. The joint CTC/attention decoder's beam search
// is replaced by CTC prefix beam search on the CPU (`CTCPrefixBeamSearch`).
//
// Licence (LR4, owner decision 1 Oct): the code is Apache-2.0, the LRS3-trained **weights are
// non-commercial research only**. VoicePlus is non-commercial, so they are used; recorded in
// `Packaging/model-notices/auto-avsr-NOTICE.txt` as the one non-commercial dependency.
//
// Never downloaded by the app; `tools/avsr/README.md` is the conversion recipe. Loaded only through
// `ModelResidency` (§10).

/// What one recognition call feeds the model.
public struct AVSRInput: Sendable {
    /// 16 kHz mono; nil for lips-only.
    public var audio: [Float]?
    /// 88×88 gray mouth crops at 25 fps (dense — gaps already filled).
    public var video: [[UInt8]]
    public init(audio: [Float]?, video: [[UInt8]]) { self.audio = audio; self.video = video }
}

public enum AVSRVariant: String, Sendable, CaseIterable {
    /// Audio + video fused (LR2).
    case audioVisual = "avsr"
    /// Video only (LR3 lips-only).
    case visualOnly = "vsr"
}

/// The model behind `AVSRRecognizer` (CoreML in the app, a mock in tests).
public protocol AVSRModelRunning: AnyObject, Sendable {
    var vocabulary: AVSRVocabulary { get }
    func run(_ input: AVSRInput, variant: AVSRVariant) async throws -> CTCOutput
    /// Whether `variant` is installed.
    func isAvailable(_ variant: AVSRVariant) -> Bool
}

public enum AVSRError: Error, Equatable, Sendable {
    case modelNotInstalled(AVSRVariant)
    /// Lips-only with no face in front of the camera.
    case noFaceTracked
    case badOutput(String)
}

/// Where the converted model lives. Never downloads.
public struct AVSRModelLocator: Sendable {
    public static let folderName = "auto-avsr"
    public static let vocabularyFile = "tokens.txt"
    public var root: URL

    public init(root: URL? = nil) {
        self.root = root ?? ModelCatalogRoot.models().appendingPathComponent(Self.folderName)
    }

    public func modelURL(_ variant: AVSRVariant) -> URL { root.appendingPathComponent("auto-avsr-\(variant.rawValue).mlmodelc") }
    public var vocabularyURL: URL { root.appendingPathComponent(Self.vocabularyFile) }

    public func isInstalled(_ variant: AVSRVariant, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: modelURL(variant).path) && fileManager.fileExists(atPath: vocabularyURL.path)
    }
}

/// Indirection so this file does not depend on where the ASR catalog keeps its root.
enum ModelCatalogRoot {
    static func models() -> URL { ModelCatalog.modelsRoot() }
}

/// Catalog facts used for residency registration and the Models page.
public enum AVSRCatalog {
    /// fp16 CoreML, Conformer-L (~250 M params) + front-ends.
    public static func estimatedBytes(_ v: AVSRVariant) -> Int64 {
        switch v {
        case .audioVisual: return 620_000_000
        case .visualOnly: return 520_000_000
        }
    }
    public static func residencyKey(_ v: AVSRVariant) -> String { "vision.auto-avsr.\(v.rawValue)" }
    public static let licence = "Auto-AVSR weights: non-commercial research only (LRS3). Code: Apache-2.0."
    /// Auto-AVSR's video normalisation (after /255).
    public static let videoMean: Float = 0.421
    public static let videoStd: Float = 0.165
    /// Audio samples per video frame (16 kHz / 25 fps).
    public static let samplesPerFrame = 640
}

/// CoreML Auto-AVSR. Each variant is registered with `ModelResidency` as `.onDemand` and used inside
/// `withModel`, so it is pinned while it runs and idles out afterwards.
public final class CoreMLAVSRModel: AVSRModelRunning, @unchecked Sendable {
    public let vocabulary: AVSRVocabulary
    private let locator: AVSRModelLocator
    private let residency: ModelResidency
    private let lock = NSLock()
    private var models: [AVSRVariant: MLModel] = [:]
    private var registered: Set<AVSRVariant> = []

    public init?(locator: AVSRModelLocator = AVSRModelLocator(), residency: ModelResidency = .shared) {
        guard let vocab = try? AVSRVocabulary(contentsOf: locator.vocabularyURL), vocab.tokens.count > 1 else { return nil }
        self.vocabulary = vocab
        self.locator = locator
        self.residency = residency
    }

    public func isAvailable(_ variant: AVSRVariant) -> Bool { locator.isInstalled(variant) }

    private func registerIfNeeded(_ v: AVSRVariant) async {
        guard lock.withLock({ registered.insert(v).inserted }) else { return }
        let url = locator.modelURL(v)
        await residency.register(AVSRCatalog.residencyKey(v), tier: .onDemand, estimatedBytes: AVSRCatalog.estimatedBytes(v),
                                 owner: "vision.auto-avsr",
                                 load: { [weak self] in
                                     let config = MLModelConfiguration()
                                     config.computeUnits = .cpuAndNeuralEngine
                                     let model = try MLModel(contentsOf: url, configuration: config)
                                     self?.lock.withLock { self?.models[v] = model }
                                 },
                                 unload: { [weak self] in self?.lock.withLock { self?.models[v] = nil } })
    }

    public func run(_ input: AVSRInput, variant: AVSRVariant) async throws -> CTCOutput {
        guard isAvailable(variant) else { throw AVSRError.modelNotInstalled(variant) }
        await registerIfNeeded(variant)
        return try await residency.withModel(AVSRCatalog.residencyKey(variant)) {
            guard let model = lock.withLock({ models[variant] }) else { throw AVSRError.modelNotInstalled(variant) }
            return try Self.predict(model, input: input, variant: variant)
        }
    }

    static func predict(_ model: MLModel, input: AVSRInput, variant: AVSRVariant) throws -> CTCOutput {
        let t = input.video.count, side = MouthCropper.side
        let video = try MLMultiArray(shape: [1, NSNumber(value: t), NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let vp = video.dataPointer.assumingMemoryBound(to: Float.self)
        for (i, frame) in input.video.enumerated() {
            for (j, px) in frame.enumerated() {
                vp[i * side * side + j] = (Float(px) / 255 - AVSRCatalog.videoMean) / AVSRCatalog.videoStd
            }
        }
        var features: [String: MLFeatureValue] = ["video": MLFeatureValue(multiArray: video)]
        if variant == .audioVisual {
            let n = t * AVSRCatalog.samplesPerFrame
            let audio = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
            let ap = audio.dataPointer.assumingMemoryBound(to: Float.self)
            let src = input.audio ?? []
            for i in 0..<n { ap[i] = i < src.count ? src[i] : 0 }
            features["audio"] = MLFeatureValue(multiArray: audio)
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let logits = out.featureValue(for: "ctc_log_probs")?.multiArrayValue, logits.shape.count == 3 else {
            throw AVSRError.badOutput("missing ctc_log_probs")
        }
        let frames = logits.shape[1].intValue, vocab = logits.shape[2].intValue
        var rows: [[Float]] = []
        rows.reserveCapacity(frames)
        if logits.dataType == .float32 {
            let lp = logits.dataPointer.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { rows.append(Array(UnsafeBufferPointer(start: lp + f * vocab, count: vocab))) }
        } else {
            for f in 0..<frames { rows.append((0..<vocab).map { logits[f * vocab + $0].floatValue }) }
        }
        return CTCOutput(logProbs: rows, frameDuration: 1 / VisualClip.modelFPS)
    }
}
