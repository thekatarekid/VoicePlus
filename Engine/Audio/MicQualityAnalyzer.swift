import Foundation
import Shared

/// Publishes one `MicQuality` from the first `windowDuration` (300 ms) of *signal*. Leading
/// silence (the beat before the user starts talking) is skipped, so the verdict is about the mic,
/// not the pause; if nothing above the low-level threshold arrives within `deadline` (1.5 s) the
/// verdict is `lowLevel` / `.bad`. `flush()` forces a verdict on whatever was collected.
/// SNR = 90th-percentile frame RMS over 10th-percentile frame RMS (10 ms frames), in dB.
/// Clipping = fraction of samples at |x| >= 0.985. Low level = peak below -40 dBFS.
public final class MicQualityAnalyzer: @unchecked Sendable {
    public static let windowDuration: TimeInterval = 0.3
    public static let clipThreshold: Float = 0.985
    public static let lowLevelPeakDB: Float = -40
    public static let sampleRate = 16_000
    public static let deadline: TimeInterval = 1.5
    private static let activityThreshold: Float = 0.01   // -40 dBFS peak

    private var buffer: [Float] = []
    private var skipped = 0
    private let windowSamples = Int(windowDuration * Double(sampleRate))
    private(set) public var result: MicQuality?

    public init() {}

    public func reset() { buffer.removeAll(keepingCapacity: true); result = nil; skipped = 0 }

    /// Feed samples; returns the verdict exactly once, when the window is full.
    @discardableResult
    public func feed(_ samples: [Float]) -> MicQuality? {
        guard result == nil else { return nil }
        var slice = samples[...]
        if buffer.isEmpty {
            if let first = slice.firstIndex(where: { abs($0) >= Self.activityThreshold }) {
                skipped += first - slice.startIndex
                slice = slice[first...]
            } else {
                skipped += slice.count
                let deadlineSamples = Int(Self.deadline * Double(Self.sampleRate))
                guard skipped >= deadlineSamples else { return nil }
                buffer.append(contentsOf: samples.suffix(min(samples.count, windowSamples)))
                let q = Self.analyze(buffer)
                result = q
                return q
            }
        }
        buffer.append(contentsOf: slice.prefix(windowSamples - buffer.count))
        guard buffer.count >= windowSamples else { return nil }
        let q = Self.analyze(buffer)
        result = q
        return q
    }

    /// Force a verdict on whatever has been collected (utterance shorter than 300 ms).
    public func flush() -> MicQuality? {
        guard result == nil, !buffer.isEmpty else { return result }
        result = Self.analyze(buffer)
        return result
    }

    public static func analyze(_ samples: [Float]) -> MicQuality {
        guard !samples.isEmpty else { return MicQuality(snr: 0, clipping: 0, lowLevel: true, verdict: .bad) }
        var peak: Float = 0
        var clipped = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            if a >= clipThreshold { clipped += 1 }
        }
        let frame = sampleRate / 100
        var rms: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var acc: Float = 0
            for j in i..<i + frame { acc += samples[j] * samples[j] }
            rms.append((acc / Float(frame)).squareRoot())
            i += frame
        }
        if rms.isEmpty { rms = [((samples.reduce(0) { $0 + $1 * $1 }) / Float(samples.count)).squareRoot()] }
        rms.sort()
        let floor = max(rms[Int(Double(rms.count - 1) * 0.1)], 1e-6)
        let signal = max(rms[Int(Double(rms.count - 1) * 0.9)], 1e-6)
        let snr = 20 * log10(signal / floor)
        let peakDB = 20 * log10(max(peak, 1e-6))
        let clipping = Float(clipped) / Float(samples.count)
        let lowLevel = peakDB < lowLevelPeakDB
        let verdict: MicQuality.Verdict
        if lowLevel || clipping > 0.02 { verdict = .bad }
        else if clipping > 0.002 || snr < 6 { verdict = .poor }
        else { verdict = .good }
        return MicQuality(snr: snr, clipping: clipping, lowLevel: lowLevel, verdict: verdict)
    }
}
