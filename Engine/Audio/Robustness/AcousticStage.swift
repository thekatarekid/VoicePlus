import Foundation
import Shared

/// A sample-level stage in the acoustic front end: 16 kHz mono in, 16 kHz mono out, streaming
/// (may buffer internally; `flush()` returns whatever is still held). Runs on the capture thread
/// before the ring buffer, so it must be allocation-light and never block.
public protocol AcousticStage: AnyObject {
    var name: String { get }
    /// Whether the stage can do real work on this machine (weights present, OS API available).
    var isAvailable: Bool { get }
    func process(_ samples: [Float]) -> [Float]
    func flush() -> [Float]
    func reset()
}

/// Per-profile switches for the acoustic front end (PRODUCT-SPEC Bet 1). Profiles (e.g. "desk",
/// "café", "AirPods") are owned by settings; the engine only needs the resolved flags.
public struct RobustnessProfile: Codable, Equatable, Sendable {
    public enum AECMode: String, Codable, Sendable {
        /// No echo cancellation.
        case off
        /// Apple's built-in voice-processing I/O (AEC + NS + AGC), applied at the capture unit.
        case appleVoiceProcessing
        /// Neural AEC slot (LocalVQE / DTLN); falls back to `appleVoiceProcessing` when no weights.
        case neural
    }
    public var noiseSuppression: Bool
    /// 0…1, how aggressively the spectral gate attenuates noise bins (0.6 is a safe default).
    public var noiseSuppressionStrength: Float
    public var aec: AECMode
    /// Pre-roll captured during `prewarm()` and flushed at `start()`, so the first word survives
    /// slow-opening transports (Bluetooth SCO). Seconds.
    public var prerollSeconds: Double

    public init(noiseSuppression: Bool = true, noiseSuppressionStrength: Float = 0.6,
                aec: AECMode = .appleVoiceProcessing, prerollSeconds: Double = 0.5) {
        self.noiseSuppression = noiseSuppression
        self.noiseSuppressionStrength = noiseSuppressionStrength
        self.aec = aec
        self.prerollSeconds = prerollSeconds
    }

    public static let `default` = RobustnessProfile()
    public static let raw = RobustnessProfile(noiseSuppression: false, aec: .off, prerollSeconds: 0)
}

/// Ordered list of stages; builds from a profile. Stages that report `isAvailable == false` are
/// skipped (passthrough) rather than failing, so a missing model never breaks capture.
public final class AcousticChain: AcousticStage {
    public let name = "chain"
    public var isAvailable: Bool { stages.contains { $0.isAvailable } }
    private(set) public var stages: [any AcousticStage]

    public init(stages: [any AcousticStage]) { self.stages = stages }

    /// Sample-level chain for a profile: AEC slot (neural only — Apple VP lives in the capture
    /// unit, see `VoiceProcessingCaptureSource`) then noise suppression, ahead of the VAD.
    public convenience init(profile: RobustnessProfile, aec: (any AcousticStage)? = nil) {
        var s: [any AcousticStage] = []
        if profile.aec == .neural, let aec { s.append(aec) }
        if profile.noiseSuppression { s.append(SpectralGateNoiseSuppressor(strength: profile.noiseSuppressionStrength)) }
        self.init(stages: s)
    }

    public func process(_ samples: [Float]) -> [Float] {
        var x = samples
        for st in stages where st.isAvailable { x = st.process(x) }
        return x
    }

    public func flush() -> [Float] {
        var x: [Float] = []
        for st in stages where st.isAvailable { x = st.process(x) + st.flush() }
        return x
    }

    public func reset() { stages.forEach { $0.reset() } }
}
