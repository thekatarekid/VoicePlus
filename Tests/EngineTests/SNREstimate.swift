import Foundation

/// Test-only (V5 X19: no production caller). Energy-based SNR estimate used by the robustness tests: 90th-percentile frame RMS
/// over 10th-percentile frame RMS (20 ms frames), in dB, over a whole clip, with an optional
/// speech/noise split when a reference is known. `MicQualityAnalyzer` v2 (V4.18) no longer uses this
/// statistic: its floor comes from the pre-speech window and its signal from the first second of speech.
enum SNREstimate {
    static func percentileSNR(_ samples: [Float], sampleRate: Int = 16_000, frameMs: Int = 20) -> Float {
        let frame = max(1, sampleRate * frameMs / 1000)
        var rms: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var acc: Float = 0
            for j in i..<i + frame { acc += samples[j] * samples[j] }
            rms.append((acc / Float(frame)).squareRoot())
            i += frame
        }
        guard rms.count >= 2 else { return 0 }
        rms.sort()
        let floor = max(rms[Int(Double(rms.count - 1) * 0.1)], 1e-6)
        let signal = max(rms[Int(Double(rms.count - 1) * 0.9)], 1e-6)
        return 20 * log10(signal / floor)
    }

    /// True SNR against a clean reference (same length / alignment): 10 log10(Σref² / Σ(x-ref)²).
    static func referenceSNR(_ processed: [Float], reference: [Float]) -> Float {
        let n = min(processed.count, reference.count)
        guard n > 0 else { return 0 }
        var sig: Float = 0, err: Float = 0
        for i in 0..<n { sig += reference[i] * reference[i]; let d = processed[i] - reference[i]; err += d * d }
        return 10 * log10(max(sig, 1e-9) / max(err, 1e-9))
    }
}
