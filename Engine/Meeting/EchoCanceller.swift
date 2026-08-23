import Foundation

/// Reference-aware AEC for dual capture: the system-audio channel is the far-end reference that
/// leaks into the mic through the speakers. Complements `Engine/Audio/Robustness` (whose stages
/// are mic-only) — there the OS does AEC inside the input unit; here we have the reference
/// explicitly, so a normalized-LMS adaptive filter is enough and needs no weights.
public protocol EchoCanceller: AnyObject {
    var name: String { get }
    /// `mic` and `reference` are time-aligned, equal-length 16 kHz blocks. Returns cleaned mic.
    func process(mic: [Float], reference: [Float]) -> [Float]
    func reset()
}

/// Passthrough (AEC off, or when Apple voice-processing already cancelled echo at the input unit).
public final class PassthroughEchoCanceller: EchoCanceller {
    public let name = "aec-off"
    public init() {}
    public func process(mic: [Float], reference: [Float]) -> [Float] { mic }
    public func reset() {}
}

/// Normalized LMS echo canceller. `taps` samples of reference history (default 512 = 32 ms at
/// 16 kHz, enough for the acoustic path of a laptop speaker → mic). Clean-room textbook NLMS.
public final class NLMSEchoCanceller: EchoCanceller {
    public let name = "aec-nlms"
    public let taps: Int
    public var stepSize: Float
    private var weights: [Float]
    private var history: [Float]   // circular, length = taps
    private var head = 0
    private let epsilon: Float = 1e-6

    public init(taps: Int = 512, stepSize: Float = 0.5) {
        self.taps = max(1, taps); self.stepSize = stepSize
        weights = [Float](repeating: 0, count: self.taps)
        history = [Float](repeating: 0, count: self.taps)
    }

    public func reset() {
        weights = [Float](repeating: 0, count: taps)
        history = [Float](repeating: 0, count: taps)
        head = 0
    }

    public func process(mic: [Float], reference: [Float]) -> [Float] {
        let n = min(mic.count, reference.count)
        var out = [Float](repeating: 0, count: mic.count)
        var power: Float = history.reduce(0) { $0 + $1 * $1 }
        for i in 0..<n {
            // Push reference sample (update running power incrementally).
            let old = history[head]
            history[head] = reference[i]
            power += reference[i] * reference[i] - old * old
            if power < 0 { power = 0 }
            // Estimate echo = w · x (x = last `taps` reference samples, newest first).
            var estimate: Float = 0
            var idx = head
            for k in 0..<taps {
                estimate += weights[k] * history[idx]
                idx = idx == 0 ? taps - 1 : idx - 1
            }
            let err = mic[i] - estimate
            out[i] = err
            let mu = stepSize / (power + epsilon)
            idx = head
            for k in 0..<taps {
                weights[k] += mu * err * history[idx]
                idx = idx == 0 ? taps - 1 : idx - 1
            }
            head = (head + 1) % taps
        }
        if n < mic.count { for i in n..<mic.count { out[i] = mic[i] } }
        return out
    }
}
