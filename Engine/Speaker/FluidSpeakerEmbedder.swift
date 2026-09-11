import Foundation
import Shared

/// WeSpeaker embedding via the FluidAudio diarizer models (reuses `FluidSpeakerEmbedding` from
/// Engine/Meeting). Loads only when the models are already on disk; never downloads.
public final class FluidSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    public let name = "fluid-wespeaker"
    public let dimension = 256
    /// The one backend in the app that really identifies a speaker — and it only ever exists when
    /// the WeSpeaker weights are on disk (`loadIfAvailable`), so this is never an empty claim.
    public let identifiesSpeakers = true
    private let backend: FluidSpeakerEmbedding

    public static var isAvailable: Bool { FluidSpeakerEmbedding.areModelsPresent }
    public static func loadIfAvailable() -> FluidSpeakerEmbedder? {
        FluidSpeakerEmbedding.loadIfAvailable().map { FluidSpeakerEmbedder(backend: $0) }
    }
    init(backend: FluidSpeakerEmbedding) { self.backend = backend }

    public func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
        let v = try backend.embedding(for: samples)
        guard !v.isEmpty else { throw SpeakerError.backendUnavailable }
        return SpeakerEmbedding(vector: v, embedder: name)
    }
}

public enum SpeakerEmbedderFactory {
    /// FluidAudio WeSpeaker when models are present, MFCC fallback otherwise.
    public static func make() -> any SpeakerEmbedder {
        if let f = FluidSpeakerEmbedder.loadIfAvailable() { return f }
        Log.engine.info("speaker: diarizer models absent, using MFCC fallback embedder")
        return MFCCEmbedder()
    }
}
