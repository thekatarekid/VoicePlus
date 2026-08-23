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
    public static var modelFileURL: URL { modelDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile) }
    public static var isModelDownloaded: Bool { FileManager.default.fileExists(atPath: modelFileURL.path) }

    /// Loads from disk only; never triggers a download (that is the Providers/onboarding job).
    public static func loadIfAvailable(threshold: Float = 0.5) async -> SileroVAD? {
        guard isModelDownloaded else { return nil }
        do {
            let manager = try await VadManager(config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuAndNeuralEngine))
            return await SileroVAD(manager: manager)
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
    public static func make(preferSilero: Bool = true) async -> any VADProtocol {
        if preferSilero, let silero = await SileroVAD.loadIfAvailable() {
            Log.engine.info("vad: using silero")
            return silero
        }
        Log.engine.info("vad: using energy fallback (silero model not downloaded)")
        return EnergyVAD()
    }
}
