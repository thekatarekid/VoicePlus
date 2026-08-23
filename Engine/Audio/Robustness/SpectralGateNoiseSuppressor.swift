import Accelerate
import Foundation

/// Single-channel spectral-gating noise suppressor (Wiener-style gain with a decision-directed
/// a-priori SNR, minimum-statistics noise floor). 512-point FFT, 256 hop, sqrt-Hann analysis +
/// synthesis windows (perfect reconstruction). Algorithmic latency = one hop (16 ms); compute is a
/// handful of vDSP calls per frame, far below 20 ms per 100 ms of audio on any Apple Silicon.
/// Clean-room; no third-party code.
public final class SpectralGateNoiseSuppressor: AcousticStage {
    public let name = "spectral-gate-ns"
    public let isAvailable = true
    public static let fftSize = 512
    public static let hop = 256
    private let bins = fftSize / 2 + 1

    /// 0…1. Scales the maximum attenuation: floor gain = 10^(-strength * 2) ≈ -12 dB at 0.6 → -24 dB at 1.0.
    public let strength: Float
    private let gainFloor: Float
    private let alpha: Float = 0.92          // decision-directed smoothing
    private let noiseAdapt: Float = 0.05     // noise PSD tracking rate on non-speech bins
    private let noiseRise: Float = 1.02      // min-statistics: allow floor to creep up slowly

    private var pending: [Float] = []        // not-yet-framed input
    private var overlap: [Float]             // synthesis overlap tail (fftSize - hop)
    private var window: [Float]
    private var noisePSD: [Float]
    private var prevCleanPSD: [Float]
    private var framesSeen = 0
    private let setup: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var re: [Float], im: [Float], outRe: [Float], outIm: [Float], frame: [Float], mag2: [Float], gain: [Float]

    public init(strength: Float = 0.6) {
        self.strength = max(0, min(1, strength))
        gainFloor = powf(10, -self.strength * 2)
        let n = Self.fftSize
        window = (0..<n).map { sqrtf(0.5 * (1 - cosf(2 * .pi * Float($0) / Float(n)))) }
        overlap = [Float](repeating: 0, count: n - Self.hop)
        noisePSD = [Float](repeating: 1e-6, count: bins)
        prevCleanPSD = [Float](repeating: 0, count: bins)
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        re = [Float](repeating: 0, count: n); im = re; outRe = re; outIm = re; frame = re
        mag2 = [Float](repeating: 0, count: bins); gain = mag2
    }

    deinit { vDSP_DFT_DestroySetup(setup); vDSP_DFT_DestroySetup(inverse) }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        for i in overlap.indices { overlap[i] = 0 }
        for i in 0..<bins { noisePSD[i] = 1e-6; prevCleanPSD[i] = 0 }
        framesSeen = 0
    }

    public func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        while pending.count >= Self.fftSize {
            out.append(contentsOf: processFrame(Array(pending[0..<Self.fftSize])))
            pending.removeFirst(Self.hop)
        }
        return out
    }

    /// Emits the tail held in the overlap buffer (zero-pads so every pending sample is output).
    public func flush() -> [Float] {
        guard !pending.isEmpty else { return [] }
        var out = process([Float](repeating: 0, count: Self.fftSize))
        out.append(contentsOf: overlap.prefix(Self.hop))
        pending.removeAll(keepingCapacity: true)
        for i in overlap.indices { overlap[i] = 0 }
        return out
    }

    private func processFrame(_ x: [Float]) -> [Float] {
        let n = Self.fftSize
        vDSP_vmul(x, 1, window, 1, &frame, 1, vDSP_Length(n))
        for i in 0..<n { im[i] = 0 }
        vDSP_DFT_Execute(setup, frame, im, &re, &outIm)
        // magnitude^2 over the non-redundant half
        for k in 0..<bins { mag2[k] = re[k] * re[k] + outIm[k] * outIm[k] }

        framesSeen += 1
        if framesSeen <= 6 {                      // first ~100 ms seeds the noise floor
            for k in 0..<bins { noisePSD[k] = framesSeen == 1 ? mag2[k] : 0.7 * noisePSD[k] + 0.3 * mag2[k] }
        }
        for k in 0..<bins {
            let noise = max(noisePSD[k], 1e-10)
            let post = mag2[k] / noise                                    // a-posteriori SNR
            let prio = alpha * (prevCleanPSD[k] / noise) + (1 - alpha) * max(post - 1, 0)
            var g = prio / (1 + prio)                                     // Wiener gain
            if g < gainFloor { g = gainFloor }
            gain[k] = g
            prevCleanPSD[k] = g * g * mag2[k]
            // noise tracking: update on bins that look like noise, let the floor rise slowly otherwise
            if post < 2.5 { noisePSD[k] = (1 - noiseAdapt) * noisePSD[k] + noiseAdapt * mag2[k] }
            else { noisePSD[k] = min(noisePSD[k] * noiseRise, mag2[k]) }
        }
        // apply gain to full spectrum (mirror for negative frequencies)
        for k in 0..<bins { re[k] *= gain[k]; outIm[k] *= gain[k] }
        for k in bins..<n { let m = n - k; re[k] = re[m]; outIm[k] = -outIm[m] }
        vDSP_DFT_Execute(inverse, re, outIm, &outRe, &im)
        var scale = 1 / Float(n)
        vDSP_vsmul(outRe, 1, &scale, &frame, 1, vDSP_Length(n))
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
        // overlap-add: emit `hop` samples
        let hop = Self.hop
        var out = [Float](repeating: 0, count: hop)
        for i in 0..<hop { out[i] = overlap[i] + frame[i] }
        let tail = n - hop
        for i in 0..<tail { overlap[i] = (i + hop < tail ? overlap[i + hop] : 0) + frame[i + hop] }
        return out
    }
}
