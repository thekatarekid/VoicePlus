import AVFoundation
import Foundation
import Shared

// Acoustic echo cancellation (P1.4 T1).
//
// Pattern ported from Muesli (MIT, https://github.com/Muesli-HQ/muesli): a primary neural AEC
// (LocalVQE) with DTLN as fallback, selected at runtime by weight availability. Attribution:
// Muesli-HQ/muesli, MIT License — design of the AEC selection chain only; no Muesli source is copied.
//
// License verification (2026-08-23): LocalVQE code (github.com/localai-org/LocalVQE) and weights
// (huggingface.co/LocalAI-io/LocalVQE, `localvqe-v1.2-1.3M-f32.gguf`) are Apache-2.0 — usable.
// Training data: Microsoft DNS/AEC Challenge (CC BY 4.0). Caveat from the model card: DNSMOS
// filtering may attenuate distressed speech; not for safety-critical use.
// Inference needs the GGML C runtime (`liblocalvqe`), which is not a SwiftPM dependency of this
// package. Adding a C target is out of this item's scope, so the neural slots below are *protocol
// slots without weights*: they report `isAvailable == false` and pass audio through. The default
// AEC path is Apple's voice-processing I/O (`VoiceProcessingCaptureSource`), which is always
// present on macOS 14 and needs no weights.

/// Neural AEC slot. Conforms to `AcousticStage`; `isAvailable` only when a backend is plugged in.
public protocol NeuralAECBackend: AnyObject {
    func process(_ samples: [Float]) -> [Float]
    func reset()
}

/// LocalVQE slot (Apache-2.0 weights; GGML runtime not bundled). Passthrough until a backend is set.
/// Superseded for shipping by V5 C1b's `LocalVQEStage` (CoreML via FluidAudio `LocalVqeManager`);
/// kept as the GGML slot the P1.4 tests describe.
public final class LocalVQEAEC: AcousticStage {
    public let name = "localvqe-aec"
    public static let weightsFileName = "localvqe-v1.2-1.3M-f32.gguf"
    public var backend: (any NeuralAECBackend)?
    public let weightsURL: URL?
    public var isAvailable: Bool { backend != nil }
    public var weightsPresent: Bool { weightsURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    public init(weightsURL: URL? = nil, backend: (any NeuralAECBackend)? = nil) { self.weightsURL = weightsURL; self.backend = backend }
    public func process(_ samples: [Float]) -> [Float] { backend?.process(samples) ?? samples }
    public func flush() -> [Float] { [] }
    public func reset() { backend?.reset() }
}

/// DTLN-AEC slot (Westhausen & Meyer, MIT code; weights not bundled). Same contract as LocalVQE.
public final class DTLNAEC: AcousticStage {
    public let name = "dtln-aec"
    public var backend: (any NeuralAECBackend)?
    public var isAvailable: Bool { backend != nil }
    public init(backend: (any NeuralAECBackend)? = nil) { self.backend = backend }
    public func process(_ samples: [Float]) -> [Float] { backend?.process(samples) ?? samples }
    public func flush() -> [Float] { [] }
    public func reset() { backend?.reset() }
}

/// Picks the neural AEC the way Muesli does: LocalVQE if it can run, else DTLN, else nil (the
/// caller then relies on Apple voice processing).
public enum AECSelector {
    public static func select(localVQE: LocalVQEAEC, dtln: DTLNAEC) -> (any AcousticStage)? {
        if localVQE.isAvailable { return localVQE }
        if dtln.isAvailable { return dtln }
        return nil
    }
}

/// Apple voice-processing I/O: AEC + NS + AGC inside the input AudioUnit. Clean-room; availability
/// is checked rather than assumed because some aggregate/virtual devices refuse the mode.
public enum AppleVoiceProcessing {
    /// Whether the platform offers `setVoiceProcessingEnabled` (macOS 10.15+; always on our target).
    public static var isSupported: Bool {
        if #available(macOS 10.15, *) { return true } else { return false }
    }

    /// Enables voice processing on an engine's input node. Must be called before the engine is
    /// started or any tap is installed. Returns false if the device refused.
    @discardableResult
    public static func enable(on engine: AVAudioEngine, enabled: Bool = true) -> Bool {
        do { try engine.inputNode.setVoiceProcessingEnabled(enabled); return true }
        catch { Log.engine.error("aec: voice processing \(enabled ? "enable" : "disable") failed: \(error)"); return false }
    }
}
