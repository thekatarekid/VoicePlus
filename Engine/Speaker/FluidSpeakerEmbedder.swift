import FluidAudio
import Foundation
import Shared

/// WeSpeaker embedding via the FluidAudio diarizer models (reuses `FluidSpeakerEmbedding` from
/// Engine/Meeting). Loads only models already on disk; never downloads — the download is
/// `ModelID.speakerEmbedding`, part of the speech stack since H3 (V4.50).
public final class FluidSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    public let name = "fluid-wespeaker"
    public let dimension = 256
    /// The one backend in the app that really identifies a speaker — and it only ever exists when
    /// the WeSpeaker weights are on disk (`load(from:)`), so this is never an empty claim.
    public let identifiesSpeakers = true
    private let backend: FluidSpeakerEmbedding

    /// Is a complete copy of the weights anywhere the factory looks?
    public static var isAvailable: Bool { SpeakerEmbedderFactory.locateModel() != nil }

    public static func loadIfAvailable() -> FluidSpeakerEmbedder? {
        SpeakerEmbedderFactory.locateModel().flatMap(load(from:))
    }

    /// Load the diarizer pair out of `directory` (a folder holding `pyannote_segmentation.mlmodelc`
    /// and `wespeaker_v2.mlmodelc`). The segmentation model is needed too: the embedder sizes its
    /// speaker mask from that model's output shape. nil when CoreML refuses them.
    public static func load(from directory: URL) -> FluidSpeakerEmbedder? {
        do {
            let models = try DiarizerModels.load(
                localSegmentationModel: directory.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
                localEmbeddingModel: directory.appendingPathComponent(ModelNames.Diarizer.embeddingFile))
            let manager = DiarizerManager(config: .default)
            manager.initialize(models: models)
            return FluidSpeakerEmbedder(backend: FluidSpeakerEmbedding(manager: manager))
        } catch {
            Log.engine.warning("speaker: WeSpeaker models at \(directory.path) did not load: \(error)")
            return nil
        }
    }

    init(backend: FluidSpeakerEmbedding) { self.backend = backend }

    public func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
        let v = try backend.embedding(for: samples)
        guard !v.isEmpty else { throw SpeakerError.backendUnavailable }
        return SpeakerEmbedding(vector: v, embedder: name)
    }
}

/// Picks the speaker embedder (H3). WeSpeaker when its weights are on disk — our own install first
/// (`ModelID.speakerEmbedding` under `ModelCatalog.modelsRoot()`), then FluidAudio's shared cache,
/// which upstream tools and the meeting diarizer fill — and the MFCC fallback otherwise.
///
/// The fallback keeps the pipeline running, but it cannot tell voices apart
/// (`identifiesSpeakers == false`), so wherever it is in use the app says
/// `SpeakerFilter.unavailableLabel` ("Voice filtering unavailable", recovery X03) and speaker
/// filtering stays off.
public enum SpeakerEmbedderFactory {
    /// Where the weights may be, in preference order.
    public static func modelDirectories(modelsRoot: URL = ModelCatalog.modelsRoot()) -> [URL] {
        [ModelCatalog.folder(for: .speakerEmbedding, in: modelsRoot), FluidSpeakerEmbedding.modelDirectory]
    }

    /// The first candidate holding a complete copy — every required bundle, each with its
    /// `coremldata.bin`, no interrupted-download debris (`ModelIntegrity`, the same test the model
    /// manager applies). A half-downloaded folder is never handed to CoreML.
    public static func locateModel(in candidates: [URL] = modelDirectories(),
                                   fileManager: FileManager = .default) -> URL? {
        let descriptor = ModelCatalog.descriptor(.speakerEmbedding)
        return candidates.first { ModelIntegrity.isComplete(descriptor, at: $0, fileManager: fileManager) }
    }

    /// FluidAudio WeSpeaker when the models are present and load, MFCC fallback otherwise. Never
    /// downloads. `load` is injectable so the choice can be tested without CoreML.
    public static func make(candidates: [URL] = modelDirectories(),
                            fileManager: FileManager = .default,
                            load: (URL) -> (any SpeakerEmbedder)? = { FluidSpeakerEmbedder.load(from: $0) }) -> any SpeakerEmbedder {
        if let directory = locateModel(in: candidates, fileManager: fileManager), let embedder = load(directory) {
            return embedder
        }
        Log.engine.info("speaker: WeSpeaker weights absent, using the MFCC fallback — \(SpeakerFilter.unavailableLabel)")
        return MFCCEmbedder()
    }
}
