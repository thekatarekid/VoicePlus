import Foundation

// V5 V3 — noise mixing (owner-approved, V5 §V): clean public speech + noise at fixed SNRs,
// deterministic per (seed, item, noise, SNR), every mixed item tagged `snr-<dB>` + `noise-<kind>`
// so the V1 report breaks WER down by condition.
//
// SNR definition: whole-utterance power ratio, 10·log10(P_speech / P_noise), as Kaldi / MUSAN
// augmentation does. Noise shorter than the speech is tiled; longer noise starts at a seeded offset.
// When the mix would clip, the whole mix (speech and noise together) is scaled down, which keeps
// the SNR exact.

/// SplitMix64 — tiny, deterministic across runs and platforms (Swift's default generator is not).
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Where the noise comes from.
public enum NoiseSource: Sendable, Equatable {
    /// Synthetic Gaussian white noise.
    case white
    /// Synthetic pink (1/f) noise — closer to fan / HVAC / road than white.
    case pink
    /// N other talkers from the same public set (different speaker), summed at equal level.
    case babble(talkers: Int)
    /// Recorded noise files (MUSAN `noise/` from the FluidInference mirror, or any WAV/FLAC dir);
    /// one file is picked per item by the seed.
    case recordings(name: String, files: [URL])

    public var kind: String {
        switch self {
        case .white: return "white"
        case .pink: return "pink"
        case .babble: return "babble"
        case .recordings(let name, _): return name
        }
    }
    public var tag: String { "noise-\(kind)" }
}

public enum NoiseMixer {
    public static func snrTag(_ snr: Double) -> String { "snr-\(formatDB(snr))" }
    static func formatDB(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    public static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for s in x { acc += Double(s) * Double(s) }
        return (acc / Double(x.count)).squareRoot()
    }

    public static func white(count: Int, rng: inout SeededRandom) -> [Float] {
        (0..<count).map { _ in Float(rng.gaussian() * 0.1) }
    }

    /// Paul Kellet's refined pink filter over seeded white noise.
    public static func pink(count: Int, rng: inout SeededRandom) -> [Float] {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let w = rng.gaussian()
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            out[i] = Float((b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.02)
            b6 = w * 0.115926
        }
        return out
    }

    /// `count` samples of `noise`: tiled when short, from a seeded offset when long.
    public static func fit(_ noise: [Float], count: Int, rng: inout SeededRandom) -> [Float] {
        guard !noise.isEmpty, count > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        let start = noise.count > count ? Int(rng.next() % UInt64(noise.count - count + 1)) : 0
        if noise.count - start >= count { return Array(noise[start..<start + count]) }
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count { out.append(contentsOf: noise.prefix(count - out.count)) }
        return out
    }

    /// Sum of clips, each fitted to `count` and normalised to the same RMS.
    public static func babble(_ clips: [[Float]], count: Int, rng: inout SeededRandom) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for clip in clips {
            let part = fit(clip, count: count, rng: &rng)
            let r = rms(part)
            guard r > 0 else { continue }
            let g = Float(0.1 / r)
            for i in 0..<count { out[i] += part[i] * g }
        }
        return out
    }

    public struct Mix: Sendable {
        public var samples: [Float]
        /// Gain applied to the noise before summing.
        public var noiseGain: Double
        /// Anti-clip gain applied to the sum (1 when no clipping).
        public var outputGain: Double
        /// The SNR actually achieved (equals the target unless the noise or speech was silent).
        public var achievedSNR: Double
    }

    /// speech + g·noise with 10·log10(P_s / P_{g·n}) = `snrDB`; `noise` must be speech-length.
    public static func mix(speech: [Float], noise: [Float], snrDB: Double, peakLimit: Float = 0.99) -> Mix {
        precondition(noise.count == speech.count, "fit the noise first")
        let ps = rms(speech), pn = rms(noise)
        guard ps > 0, pn > 0 else { return Mix(samples: speech, noiseGain: 0, outputGain: 1, achievedSNR: .infinity) }
        let g = ps / (pn * pow(10, snrDB / 20))
        var out = [Float](repeating: 0, count: speech.count)
        var peak: Float = 0
        for i in 0..<speech.count {
            out[i] = speech[i] + Float(g) * noise[i]
            peak = max(peak, abs(out[i]))
        }
        var og = 1.0
        if peak > peakLimit {
            og = Double(peakLimit / peak)
            for i in 0..<out.count { out[i] *= Float(og) }
        }
        let achieved = 20 * log10(ps / (g * pn))
        return Mix(samples: out, noiseGain: g, outputGain: og, achievedSNR: achieved)
    }

    /// Per-(seed, item, noise, SNR) generator, independent of the order items are processed in.
    public static func rng(seed: UInt64, item: String, source: NoiseSource, snr: Double) -> SeededRandom {
        SeededRandom(seed: seed ^ StableHash.fnv1a("\(item)|\(source.kind)|\(formatDB(snr))"))
    }

    /// Noise for one item, speech-length.
    public static func noise(for source: NoiseSource, count: Int, rng: inout SeededRandom,
                             babblePool: [[Float]], load: (URL) throws -> [Float]) throws -> [Float] {
        switch source {
        case .white: return white(count: count, rng: &rng)
        case .pink: return pink(count: count, rng: &rng)
        case .babble(let talkers):
            guard !babblePool.isEmpty else { throw EvalError.stageUnsupported("babble needs other utterances in the set") }
            var picks: [[Float]] = []
            var used = Set<Int>()
            while picks.count < min(talkers, babblePool.count) {
                let i = Int(rng.next() % UInt64(babblePool.count))
                if used.insert(i).inserted { picks.append(babblePool[i]) }
            }
            return babble(picks, count: count, rng: &rng)
        case .recordings(_, let files):
            guard !files.isEmpty else { throw EvalError.stageUnsupported("no noise recordings") }
            let file = files[Int(rng.next() % UInt64(files.count))]
            return fit(try load(file), count: count, rng: &rng)
        }
    }
}

/// Turns a public set into `<set>-noisy`: the clean items (tag `snr-clean`) plus every
/// (noise × SNR) mixture, written as 16-bit WAVs under `<cache>/<set>-noisy/audio/` with
/// `<cache>/<set>-noisy/manifest.json` beside them. Never committed (eval cache).
public struct NoisySetBuilder: Sendable {
    public var paths: EvalPaths
    public var snrs: [Double]
    public var sources: [NoiseSource]
    public var seed: UInt64
    public var limit: Int?
    public var includeClean: Bool
    /// Clips held for babble (other speakers than the selected items).
    public var babblePoolSize: Int

    public init(paths: EvalPaths = EvalPaths(), snrs: [Double] = [20, 10, 5, 0], sources: [NoiseSource] = [.babble(talkers: 3), .pink],
                seed: UInt64 = 20261001, limit: Int? = nil, includeClean: Bool = true, babblePoolSize: Int = 12) {
        self.paths = paths; self.snrs = snrs; self.sources = sources; self.seed = seed
        self.limit = limit; self.includeClean = includeClean; self.babblePoolSize = babblePoolSize
    }

    public static func noisyName(_ set: String) -> String { "\(set)-noisy" }

    /// `limit` items evenly spaced through the set (deterministic; covers many speakers), or all.
    public static func spread<T>(_ items: [T], limit: Int?) -> [T] {
        guard let limit, limit > 0, limit < items.count else { return items }
        return (0..<limit).map { items[$0 * items.count / limit] }
    }

    static func speaker(_ id: String) -> Substring { id.split(separator: "-").first ?? Substring(id) }

    @discardableResult
    public func build(from manifest: EvalManifest, load: (URL) throws -> [Float] = EvalAudio.load16k) throws -> EvalManifest {
        let name = Self.noisyName(manifest.set)
        let dir = paths.cacheDirectory.appendingPathComponent(name, isDirectory: true)
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let withAudio = manifest.items.filter { $0.audio != nil }
        let selected = Self.spread(withAudio, limit: limit)
        let chosen = Set(selected.map(\.id))
        var babblePool: [(speaker: Substring, samples: [Float])] = []
        if sources.contains(where: { if case .babble = $0 { return true }; return false }) {
            // Utterances outside the evaluated subset, spread across speakers; per item, clips of
            // the same speaker are excluded so no talker babbles over themselves.
            for item in Self.spread(withAudio.filter { !chosen.contains($0.id) }, limit: babblePoolSize) {
                if let u = paths.audioURL(item, manifest: manifest) { babblePool.append((Self.speaker(item.id), try load(u))) }
            }
        }

        var out: [EvalItem] = []
        for item in selected {
            guard let url = paths.audioURL(item, manifest: manifest) else { continue }
            if includeClean {
                var clean = item
                clean.audio = url.path
                clean.tags = item.tags + ["snr-clean"]
                out.append(clean)
            }
            let speech = try load(url)
            for source in sources {
                for snr in snrs {
                    var rng = NoiseMixer.rng(seed: seed, item: item.id, source: source, snr: snr)
                    let pool = babblePool.filter { $0.speaker != Self.speaker(item.id) }.map(\.samples)
                    let noise = try NoiseMixer.noise(for: source, count: speech.count, rng: &rng, babblePool: pool, load: load)
                    let mixed = NoiseMixer.mix(speech: speech, noise: noise, snrDB: snr)
                    let id = "\(item.id)@\(source.kind)-\(NoiseMixer.snrTag(snr))"
                    let file = "\(id).wav"
                    try EvalAudio.writeWAV(mixed.samples, to: audioDir.appendingPathComponent(file))
                    var noisy = item
                    noisy.id = id
                    noisy.audio = file
                    noisy.tags = item.tags + [NoiseMixer.snrTag(snr), source.tag]
                    out.append(noisy)
                }
            }
        }
        let noisy = EvalManifest(set: name, language: manifest.language, audioRoot: "\(name)/audio", licence: manifest.licence,
                                 source: "\(manifest.source ?? manifest.set) + V3 noise (\(sources.map(\.kind).joined(separator: ","))) seed \(seed)",
                                 items: out)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(noisy).write(to: dir.appendingPathComponent("manifest.json"))
        return noisy
    }

    /// Parses `--noise babble,pink,white` (+ `--noise-dir D [--noise-name musan]`).
    public static func sources(_ names: [String], noiseDir: URL?, noiseName: String = "musan") throws -> [NoiseSource] {
        var out: [NoiseSource] = try names.map {
            switch $0 {
            case "white": return .white
            case "pink": return .pink
            case "babble": return .babble(talkers: 3)
            default: throw LabError.badArguments("unknown noise '\($0)'; one of white, pink, babble (or --noise-dir)")
            }
        }
        if let noiseDir {
            let exts: Set<String> = ["wav", "flac"]
            var files: [URL] = []
            let e = FileManager.default.enumerator(at: noiseDir, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL { if exts.contains(u.pathExtension.lowercased()) { files.append(u) } }
            guard !files.isEmpty else { throw LabError.badArguments("no wav/flac under \(noiseDir.path)") }
            out.append(.recordings(name: noiseName, files: files.sorted { $0.path < $1.path }))
        }
        return out
    }
}
