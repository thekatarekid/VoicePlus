import Accelerate
import Foundation

/// Produces a fixed-length speaker embedding from 16 kHz mono samples.
/// Implementations: `MFCCEmbedder` (offline, vDSP), `FluidSpeakerEmbedder` (WeSpeaker via FluidAudio).
public protocol SpeakerEmbedder: AnyObject, Sendable {
    var name: String { get }
    var dimension: Int { get }
    func embed(_ samples: [Float]) throws -> SpeakerEmbedding
    /// R3.3 — does this backend actually identify a speaker? Only a trained embedding model does.
    /// The default is `false`, so a fallback embedder can never be mistaken for identification:
    /// `SpeakerFilter` reads this to decide between "not you" and the honest
    /// "speaker model unavailable" (V3 §2.3 — the WeSpeaker weights are absent on this machine).
    var identifiesSpeakers: Bool { get }
}

public extension SpeakerEmbedder {
    var identifiesSpeakers: Bool { false }
}

/// Speaker vector. Two metrics share one type so gates/profiles are backend-agnostic:
/// - `.cosine`: L2-normalised neural embedding (WeSpeaker), similarity = cosine.
/// - `.gaussian`: `vector = means(d) + stds(d)` of frame features; similarity = 1 / (1 + D/D₀)
///   where D is the variance-normalised mean distance (Mahalanobis-style). Scale-free, so short
///   utterances and level changes do not collapse onto the same direction like raw MFCC means do.
public struct SpeakerEmbedding: Codable, Equatable, Sendable {
    public enum Metric: String, Codable, Sendable { case cosine, gaussian }
    public var vector: [Float]
    public var embedder: String
    public var metric: Metric
    /// Distance at which gaussian similarity = 0.5 (tuned on the fixture corpus, see SpeakerRejectionTests).
    public static let gaussianScale: Float = 0.08

    public init(vector: [Float], embedder: String, metric: Metric = .cosine) {
        self.embedder = embedder; self.metric = metric
        if metric == .cosine {
            var n: Float = 0
            vDSP_svesq(vector, 1, &n, vDSP_Length(vector.count))
            var s = n > 0 ? 1 / n.squareRoot() : 1
            var out = [Float](repeating: 0, count: vector.count)
            vDSP_vsmul(vector, 1, &s, &out, 1, vDSP_Length(vector.count))
            self.vector = out
        } else {
            self.vector = vector
        }
    }
    public var isEmpty: Bool { vector.isEmpty }
    public var dimension: Int { metric == .gaussian ? vector.count / 2 : vector.count }

    /// Similarity in roughly 0…1 (cosine may go negative). Symmetric.
    public func similarity(_ other: SpeakerEmbedding) -> Float {
        guard metric == other.metric, vector.count == other.vector.count, !vector.isEmpty else { return 0 }
        switch metric {
        case .cosine:
            var d: Float = 0
            vDSP_dotpr(vector, 1, other.vector, 1, &d, vDSP_Length(vector.count))
            return max(-1, min(1, d))
        case .gaussian:
            let d = dimension
            var acc: Float = 0
            for k in 0..<d {
                let diff = vector[k] - other.vector[k]
                let v = (vector[d + k] * vector[d + k] + other.vector[d + k] * other.vector[d + k]) / 2
                acc += diff * diff / max(v, 1e-4)
            }
            return 1 / (1 + (acc / Float(d)) / Self.gaussianScale)
        }
    }
    /// Alias kept for readers used to cosine gates.
    public func cosine(_ other: SpeakerEmbedding) -> Float { similarity(other) }

    /// Mean of several embeddings (cosine: re-normalised; gaussian: mean of means, RMS of stds).
    public static func centroid(_ embs: [SpeakerEmbedding]) -> SpeakerEmbedding? {
        guard let first = embs.first,
              embs.allSatisfy({ $0.vector.count == first.vector.count && $0.metric == first.metric }) else { return nil }
        let n = Float(embs.count)
        var sum = [Float](repeating: 0, count: first.vector.count)
        if first.metric == .gaussian {
            let d = first.dimension
            for e in embs { for k in 0..<d { sum[k] += e.vector[k] / n; sum[d + k] += e.vector[d + k] * e.vector[d + k] / n } }
            for k in 0..<d { sum[d + k] = sum[d + k].squareRoot() }
        } else {
            for e in embs { vDSP_vadd(sum, 1, e.vector, 1, &sum, 1, vDSP_Length(sum.count)) }
        }
        return SpeakerEmbedding(vector: sum, embedder: first.embedder, metric: first.metric)
    }
    /// Weighted blend `self*(1-w) + other*w` in the native space (used for slow profile adaptation).
    public func blended(with other: SpeakerEmbedding, weight w: Float) -> SpeakerEmbedding {
        guard other.vector.count == vector.count, other.metric == metric else { return self }
        let v = zip(vector, other.vector).map { $0 * (1 - w) + $1 * w }
        return SpeakerEmbedding(vector: v, embedder: embedder, metric: metric)
    }
}

public enum SpeakerError: Error, Equatable { case tooShort(samples: Int), backendUnavailable }

/// Offline fallback embedder: per-frame MFCC c1…c(n-1) + deltas over voiced frames (512-pt DFT,
/// 40 mel filters, 10 ms hop) summarised as a diagonal Gaussian (`.gaussian` metric). No models
/// required; pure vDSP. c0 (energy) is dropped so microphone gain does not shape identity.
public final class MFCCEmbedder: SpeakerEmbedder, @unchecked Sendable {
    public let name = "mfcc-mean"
    public let sampleRate: Float
    public let numCoeffs: Int
    public let numFilters: Int
    public let frameSize = 512
    public let hop = 160
    public var dimension: Int { (numCoeffs - 1) * 2 }
    public static let minSamples = 16_000 / 4   // 250 ms

    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private let filterBank: [[Float]]    // numFilters x (frameSize/2+1)
    private let dct: [Float]             // numCoeffs x numFilters, row-major

    public init(sampleRate: Float = 16_000, numCoeffs: Int = 30, numFilters: Int = 40) {
        self.sampleRate = sampleRate; self.numCoeffs = numCoeffs; self.numFilters = numFilters
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD)!
        var w = [Float](repeating: 0, count: frameSize)
        vDSP_hamm_window(&w, vDSP_Length(frameSize), 0)
        window = w
        filterBank = MFCCEmbedder.melFilterBank(filters: numFilters, fftSize: frameSize, sampleRate: sampleRate)
        var d = [Float](repeating: 0, count: numCoeffs * numFilters)
        for k in 0..<numCoeffs {
            for n in 0..<numFilters {
                d[k * numFilters + n] = cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(numFilters))
            }
        }
        dct = d
    }
    deinit { vDSP_DFT_DestroySetup(setup) }

    public func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
        guard samples.count >= MFCCEmbedder.minSamples else { throw SpeakerError.tooShort(samples: samples.count) }
        let raw = mfccFrames(samples)
        guard raw.count >= 2 else { throw SpeakerError.tooShort(samples: samples.count) }
        let c = numCoeffs - 1, d = dimension
        var mean = [Float](repeating: 0, count: d), sq = [Float](repeating: 0, count: d)
        for i in 1..<raw.count {
            for k in 0..<c {
                let x = raw[i][k + 1], dx = x - raw[i - 1][k + 1]
                mean[k] += x; sq[k] += x * x
                mean[c + k] += dx; sq[c + k] += dx * dx
            }
        }
        let n = Float(raw.count - 1)
        var v = [Float](repeating: 0, count: d * 2)
        for k in 0..<d {
            let m = mean[k] / n
            v[k] = m
            v[d + k] = max(1e-2, sq[k] / n - m * m).squareRoot()
        }
        return SpeakerEmbedding(vector: v, embedder: name, metric: .gaussian)
    }

    /// Per-frame MFCC vectors for frames whose energy is above a fraction of the utterance's loud frames.
    public func mfccFrames(_ samples: [Float]) -> [[Float]] {
        let n = frameSize, bins = n / 2 + 1
        guard samples.count >= n else { return [] }
        var frame = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n)
        var all: [(energy: Float, mfcc: [Float])] = []
        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            vDSP_DFT_Execute(setup, frame, im, &re, &outIm)
            vDSP_vsq(re, 1, &power, 1, vDSP_Length(bins))
            var imsq = [Float](repeating: 0, count: bins)
            vDSP_vsq(outIm, 1, &imsq, 1, vDSP_Length(bins))
            vDSP_vadd(power, 1, imsq, 1, &power, 1, vDSP_Length(bins))
            var energies = [Float](repeating: 0, count: numFilters)
            for (i, fb) in filterBank.enumerated() {
                var e: Float = 0
                vDSP_dotpr(power, 1, fb, 1, &e, vDSP_Length(bins))
                energies[i] = log(e + 1e-8)
            }
            var mfcc = [Float](repeating: 0, count: numCoeffs)
            vDSP_mmul(dct, 1, energies, 1, &mfcc, 1, vDSP_Length(numCoeffs), 1, vDSP_Length(numFilters))
            var en: Float = 0
            vDSP_sve(power, 1, &en, vDSP_Length(bins))
            all.append((en, mfcc))
            start += hop
        }
        let sorted = all.map(\.energy).sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let gate = loud * 0.01   // -20 dB below the 90th-percentile frame
        let voiced = all.filter { $0.energy >= gate }.map(\.mfcc)
        return voiced.isEmpty ? all.map(\.mfcc) : voiced
    }

    static func melFilterBank(filters: Int, fftSize: Int, sampleRate: Float) -> [[Float]] {
        let bins = fftSize / 2 + 1
        func mel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
        func hz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(min(7600, sampleRate / 2))
        let points = (0..<(filters + 2)).map { i -> Int in
            let f = hz(lo + (hi - lo) * Float(i) / Float(filters + 1))
            return Int((Float(fftSize) * f / sampleRate).rounded())
        }
        return (0..<filters).map { m in
            var fb = [Float](repeating: 0, count: bins)
            let a = points[m], b = points[m + 1], c = points[m + 2]
            if b > a { for k in a..<b { fb[k] = Float(k - a) / Float(b - a) } }
            if c > b { for k in b..<c { fb[k] = Float(c - k) / Float(c - b) } }
            if b < bins { fb[b] = 1 }
            return fb
        }
    }
}
