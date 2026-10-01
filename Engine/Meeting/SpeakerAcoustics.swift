import Accelerate
import Foundation
import Shared

// V5 M13 — the acoustic half of a speaker's description, measured per labelled chunk while the
// meeting runs (computed locally, never sent anywhere, never stored as audio):
//   * level — speech level in dBFS (90th-percentile 20 ms frame);
//   * dynamics — how far the envelope dips between syllables (p90 − p20 of 20 ms frames, dB, dips floored 60 dB under the peak):
//     a close, dry voice dips deep (to the room's noise floor); reverberation fills the dips, so a
//     far voice reads low;
//   * F0 — median pitch of voiced 40 ms frames (normalised autocorrelation, 60–400 Hz).

/// One labelled chunk's measurements.
public struct ChunkAcoustics: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var channel: MeetingChannel
    /// Speech level, dBFS (nil for silence).
    public var levelDB: Float?
    /// Envelope depth, dB (nil for silence).
    public var dynamicsDB: Float?
    /// Median F0 over voiced frames, Hz (nil when nothing was voiced).
    public var f0Hz: Float?
    /// Voiced frames that produced `f0Hz`.
    public var voicedFrames: Int

    public init(start: TimeInterval, end: TimeInterval, channel: MeetingChannel, levelDB: Float?, dynamicsDB: Float?,
                f0Hz: Float?, voicedFrames: Int) {
        self.start = start; self.end = end; self.channel = channel; self.levelDB = levelDB
        self.dynamicsDB = dynamicsDB; self.f0Hz = f0Hz; self.voicedFrames = voicedFrames
    }
}

public enum SpeakerAcoustics {
    public static let sampleRate = 16_000

    public static func measure(_ samples: [Float], start: TimeInterval, channel: MeetingChannel) -> ChunkAcoustics {
        let (level, dyn) = levelAndDynamics(samples)
        let (f0, n) = medianF0(samples)
        return ChunkAcoustics(start: start, end: start + Double(samples.count) / Double(sampleRate), channel: channel,
                              levelDB: level, dynamicsDB: dyn, f0Hz: f0, voicedFrames: n)
    }

    /// 20 ms frame energies in dB.
    static func frameDB(_ samples: [Float]) -> [Float] {
        let frame = sampleRate / 50
        guard samples.count >= frame else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / frame)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i + frame <= p.count {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i, 1, &ms, vDSP_Length(frame))
                out.append(10 * log10(max(ms, 1e-12)))
                i += frame
            }
        }
        return out
    }

    /// (speech level, envelope depth) in dB; nil for silence (< −60 dBFS).
    public static func levelAndDynamics(_ samples: [Float]) -> (Float?, Float?) {
        let db = frameDB(samples).sorted()
        guard let top = db.last, top > -60 else { return (nil, nil) }
        let level = db[min(db.count - 1, (db.count * 9) / 10)]
        // Dips below 60 dB under the peak count as 60 dB (digital silence would read as infinite).
        let lo = max(db[(db.count * 2) / 10], top - 60)
        return (level, level - lo)
    }

    /// Median F0 of voiced 40 ms frames (every third 20 ms hop, enough for a median) and their count.
    public static func medianF0(_ samples: [Float], minHz: Float = 60, maxHz: Float = 400) -> (Float?, Int) {
        let frame = sampleRate / 25, hop = (sampleRate / 50) * 3
        let minLag = Int(Float(sampleRate) / maxHz), maxLag = Int(Float(sampleRate) / minHz)
        guard samples.count >= frame + maxLag else { return (nil, 0) }
        let loudest = frameDB(samples).max() ?? -120
        var f0s: [Float] = []
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i + frame + maxLag <= p.count {
                let base = p.baseAddress! + i
                var e0: Float = 0
                vDSP_svesq(base, 1, &e0, vDSP_Length(frame))
                let db = 10 * log10(max(e0 / Float(frame), 1e-12))
                if db > loudest - 25 {
                    var best: Float = 0, bestLag = 0
                    var prev: Float = 1, rising = false
                    for lag in minLag...maxLag {
                        var dot: Float = 0, el: Float = 0
                        vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(frame))
                        vDSP_svesq(base + lag, 1, &el, vDSP_Length(frame))
                        let r = dot / max((e0 * el).squareRoot(), 1e-9)
                        // First strong peak after the autocorrelation has dipped (avoids octave errors).
                        if r > prev { rising = true }
                        if rising, r > best { best = r; bestLag = lag }
                        if rising, best > 0.75, r < best - 0.2 { break }
                        prev = r
                    }
                    if best >= 0.5, bestLag > 0 { f0s.append(Float(sampleRate) / Float(bestLag)) }
                }
                i += hop
            }
        }
        guard !f0s.isEmpty else { return (nil, 0) }
        f0s.sort()
        return (f0s[f0s.count / 2], f0s.count)
    }
}
