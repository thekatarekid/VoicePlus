import Foundation
import Shared
import KeyboardCore

/// Slot for the small Parakeet CoreML model (FluidAudio fork compiled for iOS). Not wired yet:
/// the FluidAudio package is macOS-only in this repo's Package.swift, so this reports
/// unavailable and `ASRSelector` falls through to `SpeechRecognizerASR`. When the iOS model
/// bundle lands, implement `start/stop` by feeding 16 kHz mono frames to the TDT decoder and
/// mapping its token timestamps + logprobs onto `TranscriptSpan` (confidence = exp(mean logprob)).
public final class ParakeetCoreMLASR: KeyboardASR, @unchecked Sendable {
    public let modelURL: URL?
    public init(modelURL: URL? = nil) { self.modelURL = modelURL }
    public var isAvailable: Bool { modelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    public func start(onPartial: @escaping @Sendable (String) -> Void,
                      onFinal: @escaping @Sendable (Result<[TranscriptSpan], Error>) -> Void) throws {
        throw KeyboardASRError.unavailable
    }
    public func stop() {}
}

/// Picks the first available on-device recognizer: Parakeet (when shipped) → SFSpeech on-device.
public enum ASRSelector {
    public static func make() -> any KeyboardASR {
        let parakeet = ParakeetCoreMLASR(modelURL: Bundle.main.url(forResource: "parakeet-tdt-0.6b", withExtension: "mlmodelc"))
        if parakeet.isAvailable { return parakeet }
        #if canImport(Speech)
        return SpeechRecognizerASR()
        #else
        return parakeet
        #endif
    }
}
