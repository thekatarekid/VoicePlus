import Foundation

/// Hands-free fix (RC3) — the part of a latch segment's audio the speaker check should hear: the
/// voice, not the silence, room tone and keyboard clicks around it.
///
/// A hands-free segment's audio runs from the previous segment's close to this one's, so it can hold
/// many seconds of a quiet room and Option-chord typing around a few seconds of speech. Embedding
/// all of it pulled the owner's own voice below the similarity threshold ("another voice") and sent
/// his words to Notes. This keeps only voiced stretches:
///
/// * 20 ms frames, RMS energy per frame;
/// * a frame is loud when it is within `dynamicRange` of the loudest frame and above `floor`;
/// * loud runs shorter than `minimumRunFrames` are dropped (a key click is one or two frames; a
///   syllable is four or more);
/// * the remaining runs are widened by `hangoverFrames` on each side so word edges are kept.
///
/// Too little voice left (under `minimumSeconds`) returns the audio unchanged: the check then
/// behaves exactly as before rather than embedding a sliver.
public enum SpeakerSegmentAudio {
    public static let sampleRate = 16_000
    public static let frameSamples = 320            // 20 ms
    public static let floor: Float = 0.003          // ≈ −50 dBFS
    public static let dynamicRange: Float = 0.06    // ≈ −24 dB below the loudest frame
    public static let minimumRunFrames = 4          // 80 ms
    public static let hangoverFrames = 2            // 40 ms each side
    public static let minimumSeconds: Double = 0.5

    /// The voiced part of `samples`, or `samples` itself when too little voice is found.
    public static func voiced(_ samples: [Float]) -> [Float] {
        let frames = samples.count / frameSamples
        guard frames > 0 else { return samples }
        var energy = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            let base = f * frameSamples
            for i in base..<(base + frameSamples) { sum += samples[i] * samples[i] }
            energy[f] = (sum / Float(frameSamples)).squareRoot()
        }
        let peak = energy.max() ?? 0
        let threshold = max(floor, peak * dynamicRange)
        guard peak >= floor else { return samples }
        var loud = energy.map { $0 >= threshold }
        // Drop short bursts (clicks, taps).
        var f = 0
        while f < frames {
            guard loud[f] else { f += 1; continue }
            var end = f
            while end < frames, loud[end] { end += 1 }
            if end - f < minimumRunFrames { for i in f..<end { loud[i] = false } }
            f = end
        }
        // Widen what is left so consonants at word edges stay in.
        var keep = loud
        for i in 0..<frames where loud[i] {
            for j in max(0, i - hangoverFrames)...min(frames - 1, i + hangoverFrames) { keep[j] = true }
        }
        var out: [Float] = []
        out.reserveCapacity(keep.filter { $0 }.count * frameSamples)
        for i in 0..<frames where keep[i] {
            out.append(contentsOf: samples[(i * frameSamples)..<((i + 1) * frameSamples)])
        }
        guard Double(out.count) / Double(sampleRate) >= minimumSeconds else { return samples }
        return out
    }
}
