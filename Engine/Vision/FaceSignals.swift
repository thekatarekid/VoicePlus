import Foundation

// MARK: - V5 LR1 · Camera signals without a lip model
//
// Apple Vision face landmarks only (licence-clean, no lip-reading model). Three signals:
//
// * **Lip activity** — is the mouth moving *in time with* the audio? Mouth-open variance over a
//   short window is correlated with the audio energy envelope (Pearson). The user's own speech moves
//   their mouth in step with the mic; a TV or a colleague does not. This is the second vote in the
//   O-b rubric rule 3 ("only the user's voice may start a capability").
// * **Facing the screen** — head yaw near zero → likely addressed to the computer (O-d / O5 context).
// * **Presence** — a face in front of the laptop at all.
//
// Everything here is scalar: a `FaceFrame` is a timestamp and four numbers, derived from a camera
// frame that the caller has already let go of (LR5 — no pixel buffer is ever stored by this module).

/// One camera frame reduced to the numbers LR1 needs. Times are seconds on the same clock as the
/// audio fed to `FaceSignals.noteAudio` (the capture session's clock).
public struct FaceFrame: Equatable, Sendable {
    public var time: TimeInterval
    public var facePresent: Bool
    /// Inner-lip opening ÷ mouth width, 0 (closed) … ~1 (wide open). 0 when no face.
    public var mouthOpen: Double
    /// Head yaw in radians (0 = facing the camera/screen), nil when Vision did not report one.
    public var yaw: Double?

    public init(time: TimeInterval, facePresent: Bool, mouthOpen: Double = 0, yaw: Double? = nil) {
        self.time = time; self.facePresent = facePresent; self.mouthOpen = mouthOpen; self.yaw = yaw
    }

    public static func noFace(at time: TimeInterval) -> FaceFrame { FaceFrame(time: time, facePresent: false) }
}

/// What the lips say about who spoke over a window.
public enum LipVerdict: String, Sendable, Equatable, Codable {
    /// Mouth moves with the audio: the person at the screen is the one speaking.
    case userSpeaking
    /// Face visible, audio has speech, but the mouth is still or moves out of step: someone else.
    case notUser
    /// No (or too little) face in the window: lips cannot vote.
    case noFace
    /// Not enough audio or frames to judge.
    case unknown
}

/// Lip activity over one window.
public struct LipActivity: Equatable, Sendable {
    /// Pearson correlation of mouth-open variance with audio energy, −1 … 1 (0 when unjudged).
    public var correlation: Double
    /// Mean mouth-open variance over the window (how much the mouth moved at all).
    public var mouthMotion: Double
    /// Fraction of frames in the window with a face.
    public var faceCoverage: Double
    public var verdict: LipVerdict

    public init(correlation: Double, mouthMotion: Double, faceCoverage: Double, verdict: LipVerdict) {
        self.correlation = correlation; self.mouthMotion = mouthMotion
        self.faceCoverage = faceCoverage; self.verdict = verdict
    }

    public static let unjudged = LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: 0, verdict: .unknown)

    /// O5 — the 0…1 value `DecisionState.lipActivity` carries ("lips moving" when ≥ 0.5); nil when the
    /// lips cannot vote (no face, nobody speaking).
    public var decisionScore: Double? {
        let r = min(1, max(0, correlation))
        switch verdict {
        case .userSpeaking: return 0.5 + 0.5 * r
        case .notUser: return 0.49 * r
        case .noFace, .unknown: return nil
        }
    }
}

/// The camera's contribution to the O5 decision context, read at decision time.
public struct FaceSignalsSnapshot: Equatable, Sendable {
    /// A face is in front of the screen (≥ `presenceMinCoverage` of the last `presenceWindow`).
    public var present: Bool
    /// The face is turned toward the screen (|yaw| ≤ `facingYawMax`).
    public var facingScreen: Bool
    /// Lip activity over the recent window.
    public var lips: LipActivity

    public init(present: Bool, facingScreen: Bool, lips: LipActivity) {
        self.present = present; self.facingScreen = facingScreen; self.lips = lips
    }

    public static let cameraOff = FaceSignalsSnapshot(present: false, facingScreen: false, lips: .unjudged)
}

/// Rolling LR1 tracker. A value type fed in time order from two streams (camera frames, audio
/// blocks); it keeps only scalars for `historySeconds`.
public struct FaceSignals: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Scalars older than this are dropped.
        public var historySeconds: TimeInterval = 10
        /// Window used by `snapshot(now:)` for lips.
        public var lipWindow: TimeInterval = 2
        /// Window used for presence / facing.
        public var presenceWindow: TimeInterval = 1
        /// Fraction of frames that must contain a face for `present` / for lips to vote.
        public var presenceMinCoverage: Double = 0.5
        /// |yaw| at or below this counts as facing the screen (~20°).
        public var facingYawMax: Double = 0.35
        /// Frames (with a face) a lip judgement needs.
        public var minFrames: Int = 12
        /// Mouth-open variance is measured over this many consecutive frames (6 at 15 fps = 0.4 s,
        /// about one syllable-and-a-gap, so talking vs pausing shows up as high vs low variance).
        public var varianceFrames: Int = 6
        /// Correlation at or above this, with the mouth actually moving → `.userSpeaking`.
        public var speakingCorrelation: Double = 0.3
        /// Mean mouth variance below this while the audio carries speech → the mouth is still.
        public var stillMouthMotion: Double = 0.0004
        /// Audio RMS above this (≈ −40 dBFS) counts as speech energy.
        public var speechRMS: Float = 0.01
        /// Fraction of frames whose audio must carry speech energy before lips are judged at all.
        public var minSpeechFraction: Double = 0.25
        public init() {}
    }

    public var config: Config
    public private(set) var frames: [FaceFrame] = []
    /// (block end time, block RMS).
    public private(set) var audio: [(time: TimeInterval, rms: Float)] = []

    public init(config: Config = Config()) { self.config = config }

    public static func == (a: FaceSignals, b: FaceSignals) -> Bool {
        a.config == b.config && a.frames == b.frames
            && a.audio.map(\.time) == b.audio.map(\.time) && a.audio.map(\.rms) == b.audio.map(\.rms)
    }

    // MARK: Feed

    public mutating func noteFrame(_ frame: FaceFrame) {
        frames.append(frame)
        trim(now: frame.time)
    }

    /// Feed one audio block (16 kHz mono); `position` is the time of the block's **start**.
    public mutating func noteAudio(_ samples: [Float], position: TimeInterval, sampleRate: Double = 16_000) {
        guard !samples.isEmpty else { return }
        // 20 ms sub-blocks so the envelope keeps syllable-rate detail even for 50 ms+ blocks.
        let step = max(1, Int(sampleRate * 0.02))
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + step)
            var acc: Float = 0
            for j in i..<end { acc += samples[j] * samples[j] }
            let rms = (acc / Float(end - i)).squareRoot()
            audio.append((position + Double(end) / sampleRate, rms))
            i = end
        }
        trim(now: position + Double(samples.count) / sampleRate)
    }

    /// Forget everything (camera turned off).
    public mutating func reset() { frames.removeAll(); audio.removeAll() }

    private mutating func trim(now: TimeInterval) {
        let cutoff = now - config.historySeconds
        if let first = frames.firstIndex(where: { $0.time >= cutoff }), first > 0 { frames.removeFirst(first) }
        if let first = audio.firstIndex(where: { $0.time >= cutoff }), first > 0 { audio.removeFirst(first) }
    }

    // MARK: Read

    public func snapshot(now: TimeInterval) -> FaceSignalsSnapshot {
        let recent = frames.filter { $0.time > now - config.presenceWindow && $0.time <= now }
        let withFace = recent.filter(\.facePresent)
        let coverage = recent.isEmpty ? 0 : Double(withFace.count) / Double(recent.count)
        let present = coverage >= config.presenceMinCoverage
        let yaws = withFace.compactMap(\.yaw)
        let facing = present && (yaws.isEmpty || abs(yaws.reduce(0, +) / Double(yaws.count)) <= config.facingYawMax)
        return FaceSignalsSnapshot(present: present, facingScreen: facing,
                                   lips: lipActivity(from: now - config.lipWindow, to: now))
    }

    /// Lip activity over `[from, to]` — e.g. an utterance's wall-clock range.
    public func lipActivity(from: TimeInterval, to: TimeInterval) -> LipActivity {
        let window = frames.filter { $0.time >= from && $0.time <= to }
        guard !window.isEmpty else { return .unjudged }
        let withFace = window.filter(\.facePresent)
        let coverage = Double(withFace.count) / Double(window.count)
        guard coverage >= config.presenceMinCoverage, withFace.count >= config.minFrames else {
            return LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: coverage, verdict: .noFace)
        }
        // Mouth-open variance over a sliding window of `varianceFrames`, and the audio energy over
        // the same span, one pair per frame.
        var motion: [Double] = [], energy: [Double] = []
        let k = max(2, config.varianceFrames)
        var speechFrames = 0
        for i in (k - 1)..<withFace.count {
            let slice = withFace[(i - k + 1)...i].map(\.mouthOpen)
            let mean = slice.reduce(0, +) / Double(k)
            let variance = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(k)
            let rms = meanRMS(from: withFace[i - k + 1].time, to: withFace[i].time)
            guard let rms else { continue }
            if rms >= config.speechRMS { speechFrames += 1 }
            motion.append(variance); energy.append(Double(rms))
        }
        guard motion.count >= config.minFrames - k + 1, !motion.isEmpty else {
            return LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: coverage, verdict: .unknown)
        }
        let meanMotion = motion.reduce(0, +) / Double(motion.count)
        let speechFraction = Double(speechFrames) / Double(motion.count)
        guard speechFraction >= config.minSpeechFraction else {
            // Nobody is speaking: lips have nothing to vote on.
            return LipActivity(correlation: 0, mouthMotion: meanMotion, faceCoverage: coverage, verdict: .unknown)
        }
        let r = Self.pearson(motion, energy)
        let verdict: LipVerdict
        if meanMotion < config.stillMouthMotion {
            verdict = .notUser                       // speech in the room, mouth still
        } else if r >= config.speakingCorrelation {
            verdict = .userSpeaking
        } else {
            verdict = .notUser                       // mouth moving out of step (chewing, another voice)
        }
        return LipActivity(correlation: r, mouthMotion: meanMotion, faceCoverage: coverage, verdict: verdict)
    }

    private func meanRMS(from: TimeInterval, to: TimeInterval) -> Float? {
        // Audio blocks whose end time falls in (from − 20 ms, to].
        let blocks = audio.filter { $0.time > from - 0.02 && $0.time <= to + 1e-9 }
        guard !blocks.isEmpty else { return nil }
        return blocks.map(\.rms).reduce(0, +) / Float(blocks.count)
    }

    /// Pearson correlation; 0 when either series is constant.
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n >= 2 else { return 0 }
        let mx = x.prefix(n).reduce(0, +) / Double(n), my = y.prefix(n).reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 1e-15, syy > 1e-15 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}

/// Anything that can report the camera's current view of the user (O5 context; the arbiter of lane
/// 5b reads this when it lands — until then `UserVoiceVote` is the consumer).
public protocol FaceSignalsProviding: AnyObject, Sendable {
    /// nil while the camera is off.
    func faceSignals(now: TimeInterval) -> FaceSignalsSnapshot?
    /// Lip activity over an utterance's range on the capture clock; nil while the camera is off.
    func lipActivity(from: TimeInterval, to: TimeInterval) -> LipActivity?
}
