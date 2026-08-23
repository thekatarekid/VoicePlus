import Foundation

/// Energy VAD with an adaptive noise floor and Silero-style hysteresis. Used when the Silero
/// CoreML model is not on disk (first run, offline CI). 20 ms frames.
/// Noise floor = minimum frame RMS over the last 4 s (minimum statistics), so a constant
/// background (fan, pink floor) is learned within one inter-word gap and never counted as speech.
/// Speech = frame RMS above floor by `onsetDB`; ends after `minSilence` below floor + `offsetDB`.
public final class EnergyVAD: VADProtocol, @unchecked Sendable {
    public let name = "energy"
    public let frameSize = 320
    public var onsetDB: Float
    public var offsetDB: Float
    public var minSpeech: TimeInterval
    public var minSilence: TimeInterval
    public var speechPadding: TimeInterval
    /// Absolute floor on the noise estimate so digital silence does not make everything "speech".
    public var minimumFloor: Float = 0.0005  // ≈ -66 dBFS

    /// Minimum-statistics noise floor: min frame RMS over the last `floorWindow` frames.
    private var history: [Float] = []
    private var floorWindow = 200   // 4 s of 20 ms frames
    private var floor: Float = 0.001
    private var frames = 0
    private var active = false
    private var aboveRun = 0
    private var belowRun = 0
    private var pendingStartFrame = 0

    public init(onsetDB: Float = 9, offsetDB: Float = 5, minSpeech: TimeInterval = 0.1, minSilence: TimeInterval = 0.4, speechPadding: TimeInterval = 0.05) {
        self.onsetDB = onsetDB; self.offsetDB = offsetDB
        self.minSpeech = minSpeech; self.minSilence = minSilence; self.speechPadding = speechPadding
    }

    private var frameDuration: TimeInterval { Double(frameSize) / Double(sampleRate) }

    public func reset() async {
        history.removeAll(); floor = 0.001; frames = 0; active = false; aboveRun = 0; belowRun = 0; pendingStartFrame = 0
    }

    public func process(frame: [Float]) async throws -> VADStep {
        var acc: Float = 0
        for s in frame { acc += s * s }
        let rms = (acc / Float(max(1, frame.count))).squareRoot()
        let now = Double(frames) * frameDuration
        frames += 1

        history.append(rms)
        if history.count > floorWindow { history.removeFirst() }
        floor = max((history.min() ?? rms) * 1.5, minimumFloor)
        let db = 20 * log10(max(rms, 1e-7) / floor)
        let probability = max(0, min(1, (db + 3) / (onsetDB + 6)))

        var event: VADEvent?
        if !active {
            if db >= onsetDB {
                if aboveRun == 0 { pendingStartFrame = frames - 1 }
                aboveRun += 1
                if Double(aboveRun) * frameDuration >= minSpeech {
                    active = true
                    belowRun = 0
                    event = .speechStart(at: max(0, Double(pendingStartFrame) * frameDuration - speechPadding))
                }
            } else {
                aboveRun = 0
            }
        } else {
            if db < offsetDB {
                belowRun += 1
                if Double(belowRun) * frameDuration >= minSilence {
                    active = false
                    aboveRun = 0
                    let endFrame = frames - belowRun
                    event = .speechEnd(at: Double(endFrame) * frameDuration + speechPadding)
                }
            } else {
                belowRun = 0
            }
        }
        _ = now
        return VADStep(probability: probability, isSpeech: active, event: event)
    }
}
