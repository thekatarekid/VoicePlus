import CoreML
import FluidAudio
import Foundation
import Shared

/// FluidAudio `VadManager` (Silero, CoreML) behind `VADProtocol`. 256 ms frames.
/// Only constructed when the model is already on disk — see `VADFactory`.
public final class SileroVAD: VADProtocol, @unchecked Sendable {
    public let name = "silero"
    public let frameSize = VadManager.chunkSize
    private let manager: VadManager
    private let config: VadSegmentationConfig
    private var state: VadStreamState
    private var processedSamples = 0

    public init(manager: VadManager, segmentation: VadSegmentationConfig = SileroVAD.defaultSegmentation) async {
        self.manager = manager
        self.config = segmentation
        self.state = await manager.makeStreamState()
    }

    public static let defaultSegmentation = VadSegmentationConfig(
        minSpeechDuration: 0.15, minSilenceDuration: 0.5, maxSpeechDuration: 30, speechPadding: 0.1,
        silenceThresholdForSplit: 0.3, negativeThreshold: nil, negativeThresholdOffset: 0.15)

    /// Directory FluidAudio uses for the Silero model.
    public static var modelDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .vad) }
    /// The file the pinned FluidAudio asks for (v6.2.1 since J6).
    public static var modelFileURL: URL { modelDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile) }
    /// True when any resolvable copy exists (ours, the bundle's, FluidAudio's cache, or the checked-in one).
    public static var isModelDownloaded: Bool { SileroModelLocator.resolve() != nil }

    /// V5 C6 — the seam every Silero load goes through. Default: compile-free `MLModel(contentsOf:)`
    /// on the located `.mlmodelc`. **HW1 integration point:** once `ModelResidency` lands, swap this
    /// for its loader so the VAD is accounted like every other model.
    public typealias ModelLoader = @Sendable (_ modelFile: URL, _ computeUnits: MLComputeUnits) throws -> MLModel
    public static let coreMLLoader: ModelLoader = { url, units in
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try MLModel(contentsOf: url, configuration: config)
    }

    /// Loads from disk only; never triggers a download (that is the stack installer's job).
    ///
    /// Resolution (`SileroModelLocator`): `ModelManager.locate(.sileroVAD)` when a manager is given
    /// (our folder, then its external caches), then our folder, the app bundle's copy, FluidAudio's
    /// cache, and last the copy checked into the source tree (`Packaging/vad/`, so `swift test` and
    /// `swift run` get Silero too — K17). The model is handed to `VadManager(config:vadModel:)`
    /// directly: `VadManager(config:)` would go through `ModelHub`, which downloads when the exact
    /// pinned file is missing.
    public static func loadIfAvailable(threshold: Float = 0.5, manager: ModelManager? = nil,
                                       locator: SileroModelLocator = SileroModelLocator(),
                                       loader: ModelLoader = SileroVAD.coreMLLoader) async -> SileroVAD? {
        var located: URL?
        if let manager, let folder = await manager.locate(.sileroVAD) { located = locator.modelFile(in: folder) }
        guard let file = located ?? locator.resolve() else { return nil }
        do {
            let config = VadConfig(defaultThreshold: threshold, computeUnits: .cpuAndNeuralEngine)
            let model = try loader(file, config.computeUnits)
            Log.engine.info("vad: silero model \(file.lastPathComponent) from \(file.deletingLastPathComponent().path)")
            return await SileroVAD(manager: VadManager(config: config, vadModel: model))
        } catch {
            Log.engine.warning("vad: silero load failed, using energy VAD: \(error)")
            return nil
        }
    }

    public func reset() async {
        state = await manager.makeStreamState()
        processedSamples = 0
    }

    public func process(frame: [Float]) async throws -> VADStep {
        let result = try await manager.processStreamingChunk(frame, state: state, config: config, returnSeconds: true)
        state = result.state
        processedSamples += frame.count
        var event: VADEvent?
        if let e = result.event {
            let t = e.time ?? Double(e.sampleIndex) / Double(sampleRate)
            event = e.isStart ? .speechStart(at: t) : .speechEnd(at: t)
        }
        return VADStep(probability: result.probability, isSpeech: state.triggered, event: event)
    }
}

public enum VADFactory {
    /// Silero when its model is on disk, otherwise the energy VAD. Never downloads.
    public static func make(preferSilero: Bool = true, manager: ModelManager? = nil,
                            locator: SileroModelLocator = SileroModelLocator()) async -> any VADProtocol {
        if preferSilero, let silero = await SileroVAD.loadIfAvailable(manager: manager, locator: locator) {
            Log.engine.info("vad: using silero")
            return silero
        }
        Log.engine.info("vad: using energy fallback (silero model not found)")
        return EnergyVAD()
    }
}
