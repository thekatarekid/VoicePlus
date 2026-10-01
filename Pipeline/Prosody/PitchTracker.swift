import Foundation

// V5 K8 phase 2 — terminal F0 rise. A small YIN pitch tracker (de Cheveigné & Kawahara 2002) over the
// last ~0.4 s before a sentence boundary: if the voiced pitch at the end sits clearly above the pitch
// just before it, the sentence ends rising. Pure Swift on 16 kHz mono; no model, nothing stored.

public enum PitchTracker {
    /// One F0 estimate per hop; nil = unvoiced / no clear period.
    public static func track(_ samples: [Float], sampleRate: Double = 16_000, frame: Int = 640, hop: Int = 160,
                             minF0: Double = 70, maxF0: Double = 400, threshold: Float = 0.15) -> [Double?] {
        guard samples.count >= frame else { return [] }
        let minLag = max(2, Int(sampleRate / maxF0))
        let maxLag = min(frame / 2, Int(sampleRate / minF0))
        guard maxLag > minLag else { return [] }
        var out: [Double?] = []
        var start = 0
        var diff = [Float](repeating: 0, count: maxLag + 1)
        while start + frame <= samples.count {
            // Energy gate: silence has no pitch.
            var energy: Float = 0
            for i in start..<(start + frame) { energy += samples[i] * samples[i] }
            if energy / Float(frame) < 1e-6 { out.append(nil); start += hop; continue }
            let w = frame / 2
            for lag in 1...maxLag {
                var s: Float = 0
                for i in 0..<w {
                    let d = samples[start + i] - samples[start + i + lag]
                    s += d * d
                }
                diff[lag] = s
            }
            // Cumulative mean normalised difference; first dip under the threshold.
            var running: Float = 0
            var cmnd = [Float](repeating: 1, count: maxLag + 1)
            for lag in 1...maxLag {
                running += diff[lag]
                cmnd[lag] = running > 0 ? diff[lag] * Float(lag) / running : 1
            }
            var picked: Int?
            var lag = minLag
            while lag <= maxLag {
                if cmnd[lag] < threshold {
                    while lag + 1 <= maxLag, cmnd[lag + 1] < cmnd[lag] { lag += 1 }
                    picked = lag
                    break
                }
                lag += 1
            }
            if let p = picked {
                // Parabolic interpolation for a sub-sample period.
                var period = Double(p)
                if p > 1, p < maxLag {
                    let a = Double(cmnd[p - 1]), b = Double(cmnd[p]), c = Double(cmnd[p + 1])
                    let denom = a - 2 * b + c
                    if abs(denom) > 1e-12 { period += 0.5 * (a - c) / denom }
                }
                out.append(sampleRate / period)
            } else {
                out.append(nil)
            }
            start += hop
        }
        return out
    }

    /// Semitone change between the median voiced F0 of the final `tail` seconds and that of the
    /// `tail` seconds before it, over `samples` ending at the boundary. nil = too little voicing.
    public static func terminalSlope(_ samples: [Float], sampleRate: Double = 16_000, tail: Double = 0.2) -> Double? {
        let hopSeconds = 160 / sampleRate
        let f0 = track(samples, sampleRate: sampleRate)
        let n = max(1, min(Int(tail / hopSeconds), f0.count / 2))
        guard n >= 5 else { return nil }
        let late = f0.suffix(n).compactMap { $0 }
        let early = f0.dropLast(n).suffix(n).compactMap { $0 }
        guard late.count >= n / 3, early.count >= n / 3, let a = median(early), let b = median(late) else { return nil }
        return 12 * log2(b / a)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// The prosody facts the K8 stage reads, carried in `StageContext.extra` (Shared stays unchanged).
public struct ProsodyCues: Equatable, Sendable {
    /// Utterance-relative times (seconds) of sentence ends whose pitch rises.
    public var risingEnds: [TimeInterval]

    public init(risingEnds: [TimeInterval]) { self.risingEnds = risingEnds }

    public static let extraKey = "prosody.risingEnds"
    /// Semitones of terminal rise that count as a question contour.
    public static let riseSemitones = 2.0

    public var encoded: String { risingEnds.map { String(format: "%.3f", $0) }.joined(separator: ",") }

    public init?(encoded: String?) {
        guard let encoded else { return nil }
        risingEnds = encoded.split(separator: ",").compactMap { Double($0) }
    }

    public func rises(at t: TimeInterval, tolerance: TimeInterval = 0.3) -> Bool {
        risingEnds.contains { abs($0 - t) <= tolerance }
    }

    /// Analyse the utterance's audio at every candidate sentence end (a ≥ 600 ms pause, and the
    /// last word): the 0.4 s of audio ending at the word's end. Producer side of phase 2.
    public static func analyze(samples: [Float], sampleRate: Double = 16_000, spans: [(text: String, range: ClosedRange<TimeInterval>)],
                               pause: TimeInterval = ProsodyPunctuationStage.sentencePause) -> ProsodyCues {
        var ends: [TimeInterval] = []
        for (i, s) in spans.enumerated() {
            let isEnd = i == spans.count - 1 || spans[i + 1].range.lowerBound - s.range.upperBound >= pause
            guard isEnd else { continue }
            let hi = min(samples.count, Int(s.range.upperBound * sampleRate))
            let lo = max(0, hi - Int(0.4 * sampleRate))
            guard hi - lo >= Int(0.3 * sampleRate) else { continue }
            if let slope = PitchTracker.terminalSlope(Array(samples[lo..<hi]), sampleRate: sampleRate), slope >= riseSemitones {
                ends.append(s.range.upperBound)
            }
        }
        return ProsodyCues(risingEnds: ends)
    }
}
