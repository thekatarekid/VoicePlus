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

    public init(noiseSuppression: Bool = false, noiseSuppressionStrength: Float = 0.6,
                aec: AECMode = .off, prerollSeconds: Double = 0.5) {
        self.noiseSuppression = noiseSuppression
        self.noiseSuppressionStrength = noiseSuppressionStrength
        self.aec = aec
        self.prerollSeconds = prerollSeconds
    }

    /// **The shipping capture chain: a plain tap and nothing else. No spectral gate, no echo
    /// cancellation — only the pre-roll.**
    ///
    /// **Chosen by measurement, R1.4, 2026-09-11**, on `Fixtures/real-room/builtin`: twenty real-room
    /// dictations of `Fixtures/real-room/script.md`, the owner's voice on the built-in microphone,
    /// scored through Parakeet TDT 0.6B v3. The gate lost on the quiet pass (corpus WER 0.1182 vs
    /// **0.1000** for the plain tap) *and* at every point of a pink-noise room-floor sweep from
    /// 30 dB down to 0 dB SNR — 0 of 7 points to the gate. It was given every chance to earn its
    /// place in a noisy room and did not. Per-file table and caveats:
    /// `Engine/Audio/Robustness/SUITES.md`; the measurement itself:
    /// `Tests/EngineTests/CaptureDefaultsWERTests.swift`.
    ///
    /// Note this **reverses** the 2026-09-08 finding recorded in the same file, where the gate beat
    /// the plain tap on twelve synthetic `say`-generated fixtures. Real voice through a real
    /// microphone is the corpus that decides a capture default, so this one wins — but the margin
    /// here is ~6 words in 220 and two sentences carry most of it, so re-run the suite before
    /// trusting it against a larger corpus. `.gate` is one line away if it flips back.
    ///
    /// `aec` used to read `.appleVoiceProcessing` here, which was a claim and not a fact: the
    /// engine wraps `CoreAudioCaptureSource`, whose graph line says `vp=false`, so every one of the
    /// twenty manifests recorded `aec=appleVoiceProcessing` next to `vp=false`. Voice processing is
    /// a property of the *capture unit*, not of this profile — it lives in
    /// `VoiceProcessingCaptureSource` — so the profile now names what the shipping graph does.
    /// Use `.voiceProcessing` when the voice-processing source is the one being wrapped.
    public static let `default` = RobustnessProfile()
    /// The spectral gate, kept as a named profile rather than a bare `init` flag: it is what the
    /// gate suites (`AcousticChainWERTests`, `RobustnessTests`) measure, and what `.default` would
    /// become again if a larger corpus reversed the R1.4 table. Not wired anywhere in production.
    public static let gate = RobustnessProfile(noiseSuppression: true)
    /// No DSP *and* no pre-roll: the evaluation bypass, and the `.raw` column of the R1.4 table.
    /// Differs from `.default` only in `prerollSeconds`, which is a capture concern, not a DSP one.
    public static let raw = RobustnessProfile(noiseSuppression: false, aec: .off, prerollSeconds: 0)
    /// The gate on top of Apple's voice-processing I/O — column (c) of the R1.4 table, which stayed
    /// `hardware-verified pending`. Only correct when the wrapped source is
    /// `VoiceProcessingCaptureSource` (`--mic-selftest-vp`); measuring it needs live hardware.
    public static let voiceProcessing = RobustnessProfile(noiseSuppression: true, aec: .appleVoiceProcessing)
    /// V5 C1 — Apple voice-processing I/O alone: what Settings › Voice "Noise and echo reduction
    /// (Apple)" runs (`CaptureGraphPlan`). No spectral gate on top: R1.4 measured the gate losing on
    /// every point of the sweep, and VP-IO already suppresses noise in the capture unit. Only correct
    /// with `VoiceProcessingCaptureSource` wrapped.
    public static let voiceProcessingOnly = RobustnessProfile(noiseSuppression: false, aec: .appleVoiceProcessing)
    /// V5 C1b — LocalVQE (neural AEC + NS + dereverb) as the sample-level AEC slot, plain tap
    /// underneath, no spectral gate. Passes audio through when no LocalVQE stage is plugged in.
    public static let localVQE = RobustnessProfile(noiseSuppression: false, aec: .neural)
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
