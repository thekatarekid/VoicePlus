import Foundation
import Shared

/// V5 C1 / C1b — which capture-side enhancement runs: none (the R1.4 plain tap), Apple's
/// voice-processing I/O (AEC + NS + AGC in the capture unit), or LocalVQE (neural AEC + NS +
/// dereverb, a sample-level stage). Settings › Voice "Noise and echo reduction" picks it; the engine
/// reads it once per engine build (`EngineFactory.make`).
///
/// **Default `.off`, pending the V1 gate.** C1's rule: an enhancement may become the default only
/// when the V1 harness shows it helps on VOiCES + MUSAN-mixed without degrading clean WER by more
/// than 0.3. Apple VP-IO lives in the capture unit, so it cannot be replayed offline through V1 —
/// it needs live hardware (T1). LocalVQE can be (see `LocalVQEStage`), and `CaptureEnhancementGate`
/// is the arithmetic both are judged by. Both stay selectable whichever wins.
public enum CaptureEnhancement: String, Codable, CaseIterable, Sendable {
    case off
    case appleVoiceProcessing
    case localVQE

    public static let defaultsKey = "voice.captureEnhancement"
    /// Developer override, e.g. `VOICEPLUS_CAPTURE_ENHANCEMENT=appleVoiceProcessing`.
    public static let environmentKey = "VOICEPLUS_CAPTURE_ENHANCEMENT"
    /// What ships until the V1 gate picks a winner (T1).
    public static let shippingDefault: CaptureEnhancement = .off

    public static func current(defaults: UserDefaults = .standard,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> CaptureEnhancement {
        if let raw = environment[environmentKey], let e = CaptureEnhancement(rawValue: raw) { return e }
        if let raw = defaults.string(forKey: defaultsKey), let e = CaptureEnhancement(rawValue: raw) { return e }
        return shippingDefault
    }

    /// Posted after `set` changed the stored value; the app rebuilds its capture graph.
    public static let didChangeNotification = Notification.Name("VoicePlus.CaptureEnhancement.didChange")

    public static func set(_ value: CaptureEnhancement, defaults: UserDefaults = .standard) {
        let changed = defaults.string(forKey: defaultsKey) != value.rawValue
        defaults.set(value.rawValue, forKey: defaultsKey)
        if changed { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// Settings copy.
    public var title: String {
        switch self {
        case .off: return "Off"
        case .appleVoiceProcessing: return "Noise and echo reduction (Apple)"
        case .localVQE: return "Noise and echo reduction (LocalVQE)"
        }
    }
}

/// V5 C1 — everything the capture graph needs to agree with one enhancement choice. The source and
/// the profile must move together (see `AcousticCaptureSource.effectiveAEC`), so they are decided in
/// one place.
public struct CaptureGraphPlan: Equatable, Sendable {
    public var enhancement: CaptureEnhancement
    public var profile: RobustnessProfile
    /// Wrap `VoiceProcessingCaptureSource` rather than `CoreAudioCaptureSource`.
    public var usesVoiceProcessingSource: Bool
    /// A neural AEC stage (LocalVQE) is part of the sample-level chain.
    public var usesNeuralStage: Bool
    /// Level-based warnings ignore this much audio after start (AGC is still adapting).
    public var levelWarmup: TimeInterval
    /// Log how long the AGC took to settle (`AGCAdaptationTracker`).
    public var tracksAGC: Bool

    /// AGC ramps the gain over the first few hundred ms; a floor/level read there is the AGC, not the room.
    public static let agcLevelWarmup: TimeInterval = 0.3

    /// `localVQEAvailable`: LocalVQE weights resolved. When they did not, `.localVQE` degrades to the
    /// plain tap — never to a capture that fails.
    public static func plan(for enhancement: CaptureEnhancement, localVQEAvailable: Bool = true) -> CaptureGraphPlan {
        switch enhancement {
        case .off:
            return CaptureGraphPlan(enhancement: .off, profile: .default, usesVoiceProcessingSource: false,
                                    usesNeuralStage: false, levelWarmup: 0, tracksAGC: false)
        case .appleVoiceProcessing:
            return CaptureGraphPlan(enhancement: .appleVoiceProcessing, profile: .voiceProcessingOnly,
                                    usesVoiceProcessingSource: true, usesNeuralStage: false,
                                    levelWarmup: agcLevelWarmup, tracksAGC: true)
        case .localVQE:
            guard localVQEAvailable else { return plan(for: .off) }
            return CaptureGraphPlan(enhancement: .localVQE, profile: .localVQE, usesVoiceProcessingSource: false,
                                    usesNeuralStage: true, levelWarmup: 0, tracksAGC: false)
        }
    }

    /// The capture source for this plan. Sources are built lazily so only the chosen one is touched.
    public func makeCaptureSource(plainTap: () -> any AudioCaptureSource,
                                  voiceProcessing: () -> any AudioCaptureSource,
                                  neuralStage: (any AcousticStage)? = nil,
                                  installsRecordingHooks: Bool = false) -> AcousticCaptureSource {
        let inner = usesVoiceProcessingSource ? voiceProcessing() : plainTap()
        let source = AcousticCaptureSource(wrapping: inner, profile: profile, aec: usesNeuralStage ? neuralStage : nil)
        // V5 F3 — every dictation is stored: the switch (on by default), the landed turn's text into
        // its sidecar, and the age + disk-cap sweep once per engine build (launch, engine rebuild).
        source.isRecordingEnabled = { UtteranceRecorder.isEnabled() }
        if installsRecordingHooks {
            UtteranceRecorder.installLandingAnnotator()
            DispatchQueue.global(qos: .utility).async { UtteranceRecorder().sweep() }
        }
        return source
    }

    /// Pipeline options carrying this plan's level warm-up and AGC tracking.
    public func apply(to options: AudioPipeline.Options) -> AudioPipeline.Options {
        var o = options
        o.levelWarmup = levelWarmup
        o.tracksAGC = tracksAGC
        return o
    }

    public var logLine: String {
        "capture: enhancement=\(enhancement.rawValue) source=\(usesVoiceProcessingSource ? "voiceProcessing" : "plainTap")"
            + " aec=\(profile.aec.rawValue) gate=\(profile.noiseSuppression) levelWarmup=\(Int(levelWarmup * 1000))ms"
    }
}

/// V5 C1/C1b — the V1 gate as arithmetic: an enhancement may become the default only when it does
/// not degrade clean WER by more than 0.3 percentage points and lowers WER on the noisy sets
/// (VOiCES + MUSAN-mixed). Inputs are V1 harness results (`Lab/results`), WER as a fraction.
public enum CaptureEnhancementGate {
    /// 0.3 percentage points of WER.
    public static let maxCleanRegression = 0.003

    public struct Result: Equatable, Sendable {
        public var cleanBaseline: Double, cleanCandidate: Double
        public var noisyBaseline: Double, noisyCandidate: Double
        public init(cleanBaseline: Double, cleanCandidate: Double, noisyBaseline: Double, noisyCandidate: Double) {
            self.cleanBaseline = cleanBaseline; self.cleanCandidate = cleanCandidate
            self.noisyBaseline = noisyBaseline; self.noisyCandidate = noisyCandidate
        }
    }

    public static func passes(_ r: Result) -> Bool {
        r.cleanCandidate - r.cleanBaseline <= maxCleanRegression && r.noisyCandidate < r.noisyBaseline
    }

    /// Of the candidates that pass, the one with the lowest noisy WER; nil keeps `.off`.
    public static func winner(_ results: [CaptureEnhancement: Result]) -> CaptureEnhancement? {
        results.filter { $0.key != .off && passes($0.value) }
            .min { $0.value.noisyCandidate < $1.value.noisyCandidate }?.key
    }
}
