import Foundation
import Testing
import Shared
@testable import Engine

/// WER *through* the acoustic front end. The golden suite in `ASRGoldenTranscriptTests` feeds WAVs
/// straight into `final.recognize` and so cannot see damage done by the capture-side chain; this
/// suite runs the same clean fixtures through `AcousticChain` in 100 ms blocks — exactly how
/// `AcousticCaptureSource` feeds it live — before recognition. Keep both: the contrast is the point.
///
/// Measured 2026-09-08 (Parakeet TDT 0.6B v3, M2 Pro), on the synthetic `say`-generated fixtures:
///
///   raw (no DSP)                          mean WER 0.0291
///   gate (spectral gate, strength 0.6)    mean WER 0.0140
///
/// **This was the reason `RobustnessProfile.default` enabled `SpectralGateNoiseSuppressor`, and
/// R1.4 reversed it (2026-09-11).** On the real-room corpus — the owner's voice on a real
/// microphone, twenty utterances — the gate lost on the quiet pass and at every point of a
/// 30→0 dB room-floor sweep, so `.default` is now the plain tap and the gate lives in
/// `RobustnessProfile.gate`. See `Engine/Audio/Robustness/SUITES.md`. This suite is unchanged in
/// substance: it still measures the gate, and every `.default` below became `.gate` so that it goes
/// on measuring the gate rather than silently comparing the plain tap to itself. If a larger corpus
/// swings the numbers back, this file is the evidence for the other side.
///
/// The gate *does* distort clean speech badly — `defaultChainDistortionOnCleanSpeech` measures a
/// mean SDR of 10.9 dB against the untouched input (range 4.0–28.7), and the `.raw` control
/// reconstructs at ~117 dB, so the gate is unambiguously the source of that distortion. It simply
/// costs no accuracy: Parakeet is robust to it. `roomFloorSweepRawVersusDefault` re-checks the same
/// comparison over a simulated room floor from 45 dB down to 15 dB SNR and the gated path is equal
/// or better at every point (every difference in the sweep is a number-formatting flip such as
/// "3 30" vs "three thirty", not a recognition error).
///
/// So: do not "fix" the front end on the strength of the SDR number alone. If dictation accuracy
/// regresses, this suite is the check that tells you whether the acoustic chain is responsible —
/// and as of this writing it is not.
@Suite("Acoustic chain WER (real model)", .serialized)
struct AcousticChainWERTests {
    /// Feeds `samples` through the chain the way the capture source does: 100 ms blocks + flush.
    static func throughChain(_ samples: [Float], profile: RobustnessProfile) -> [Float] {
        let chain = AcousticChain(profile: profile)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var i = 0
        let block = 1600
        while i < samples.count {
            let end = min(i + block, samples.count)
            out.append(contentsOf: chain.process(Array(samples[i..<end])))
            i = end
        }
        out.append(contentsOf: chain.flush())
        return out
    }

    struct Result { var mean: Double; var worst: Double; var worstFile: String }

    static func measure(_ profile: RobustnessProfile, label: String,
                        entries: [FixtureEntry], dir: URL, final: any FinalRecognizer) async throws -> Result {
        var total = 0.0, worst = 0.0, worstFile = ""
        for e in entries {
            let raw = try SampleAudioSource.load16k(url: dir.appendingPathComponent(e.file))
            let processed = throughChain(raw, profile: profile)
            let hyp = try await final.recognize(processed).joinedText
            let wer = wordErrorRate(reference: e.transcript, hypothesis: hyp)
            total += wer
            if wer > worst { worst = wer; worstFile = e.file }
            print(String(format: "[%@] %@: WER %.3f | %@", label, e.file, wer, hyp))
        }
        let r = Result(mean: total / Double(entries.count), worst: worst, worstFile: worstFile)
        print(String(format: "[%@] MEAN WER %.4f over %d fixtures (worst %.3f on %@)",
                     label, r.mean, entries.count, r.worst, r.worstFile))
        return r
    }

    static func loadFixtures() throws -> (URL, [FixtureEntry]) {
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/clean")
        let entries = try JSONDecoder().decode([FixtureEntry].self,
                                               from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        return (dir, entries)
    }

    /// The regression guard: clean speech must survive the *default* dictation front end.
    /// Budget matches the bypass test (mean ≤ 0.10) — the front end must not cost accuracy.
    @Test(.timeLimit(.minutes(30)))
    func defaultProfileDoesNotDegradeCleanSpeech() async throws {
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let (dir, entries) = try Self.loadFixtures()
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let dflt = try await Self.measure(.gate, label: "gate", entries: entries, dir: dir, final: final)
        #expect(dflt.mean <= 0.10, "the default acoustic chain degrades clean speech")
        #expect(dflt.worst <= 0.25, "worst-case fixture through the default chain: \(dflt.worstFile)")
    }

    /// Diagnostic A/B: raw (no DSP) vs the shipping default, same fixtures, same model.
    /// Set VOICEPLUS_CHAIN_AB=1 to run; it doubles model time.
    @Test(.timeLimit(.minutes(60)))
    func rawVersusDefaultAB() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_CHAIN_AB"] == "1" else {
            print("SKIPPED: set VOICEPLUS_CHAIN_AB=1 for the raw-vs-default A/B."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: no model."); return }
        let (dir, entries) = try Self.loadFixtures()
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let raw = try await Self.measure(.raw, label: "raw", entries: entries, dir: dir, final: final)
        let dflt = try await Self.measure(.gate, label: "gate", entries: entries, dir: dir, final: final)
        print(String(format: "A/B: raw MEAN %.4f | default MEAN %.4f", raw.mean, dflt.mean))
    }
}

/// Diagnostics that answer "does the acoustic chain actually damage speech, and does that damage
/// cost accuracy?" separately: SDR measures the distortion, WER measures whether it matters.
extension AcousticChainWERTests {
    /// Deterministic pink-ish noise (one-pole filtered white), so a room floor can be simulated
    /// without new fixture files. Seeded LCG => byte-identical across runs.
    static func pinkNoise(count: Int, seed: UInt64 = 0x5DEECE66D) -> [Float] {
        var s = seed
        func u() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int32(truncatingIfNeeded: s >> 33)) / Float(Int32.max) }
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let w = u()
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            out[i] = (b0 + b1 + b2 + w * 0.1848) * 0.15
        }
        return out
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var a: Float = 0; for v in x { a += v * v }; return (a / Float(x.count)).squareRoot()
    }

    /// speech + pink noise at `snrDB` measured over the speech-active portion (frames above -45 dBFS).
    static func mix(_ speech: [Float], snrDB: Float, seed: UInt64) -> [Float] {
        let frame = 320
        var active: [Float] = []
        var i = 0
        while i + frame <= speech.count {
            let f = Array(speech[i..<i + frame])
            if rms(f) > 0.0056 { active.append(contentsOf: f) }
            i += frame
        }
        let speechRMS = rms(active.isEmpty ? speech : active)
        let noise = pinkNoise(count: speech.count, seed: seed)
        let scale = speechRMS / max(rms(noise), 1e-9) * powf(10, -snrDB / 20)
        return zip(speech, noise).map { $0 + $1 * scale }
    }

    /// Distortion the default chain inflicts on already-clean speech, as SDR vs the untouched input.
    @Test func defaultChainDistortionOnCleanSpeech() throws {
        let (dir, entries) = try Self.loadFixtures()
        var sdrs: [Float] = []
        var passSDRs: [Float] = []
        for e in entries {
            let raw = try SampleAudioSource.load16k(url: dir.appendingPathComponent(e.file))
            let gated = Self.throughChain(raw, profile: .gate)
            let pass = Self.throughChain(raw, profile: .raw)
            sdrs.append(SNREstimate.referenceSNR(Array(gated.prefix(raw.count)), reference: raw))
            passSDRs.append(SNREstimate.referenceSNR(Array(pass.prefix(raw.count)), reference: raw))
            print(String(format: "SDR %@: gated %.1f dB | passthrough %.1f dB", e.file, sdrs.last!, passSDRs.last!))
        }
        let mean = sdrs.reduce(0, +) / Float(sdrs.count)
        print(String(format: "MEAN SDR of default chain vs clean input: %.1f dB (min %.1f, max %.1f)",
                     mean, sdrs.min()!, sdrs.max()!))
        #expect(passSDRs.allSatisfy { $0 > 40 }, "the .raw profile must be bit-transparent-ish")
    }

    /// The realistic case the clean TTS fixtures cannot represent: a decent mic in a *normal room*,
    /// i.e. clean speech over a real (non-digital-silence) noise floor. Set VOICEPLUS_CHAIN_AB=1.
    @Test(.timeLimit(.minutes(60)))
    func roomFloorSweepRawVersusDefault() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_CHAIN_AB"] == "1" else {
            print("SKIPPED: set VOICEPLUS_CHAIN_AB=1 for the room-floor sweep."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: no model."); return }
        let (dir, entries) = try Self.loadFixtures()
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        for snr in [Float(45), 35, 30, 25, 20, 15] {
            var rawTotal = 0.0, gatedTotal = 0.0
            for (n, e) in entries.enumerated() {
                let clean = try SampleAudioSource.load16k(url: dir.appendingPathComponent(e.file))
                let mixed = Self.mix(clean, snrDB: snr, seed: UInt64(n &+ 1) &* 0x9E3779B9)
                let rawHyp = try await final.recognize(Self.throughChain(mixed, profile: .raw)).joinedText
                let gatedHyp = try await final.recognize(Self.throughChain(mixed, profile: .gate)).joinedText
                let rw = wordErrorRate(reference: e.transcript, hypothesis: rawHyp)
                let gw = wordErrorRate(reference: e.transcript, hypothesis: gatedHyp)
                rawTotal += rw; gatedTotal += gw
                if rw != gw { print(String(format: "  %2.0f dB %@: raw %.3f / gated %.3f | raw=%@ | gated=%@", snr, e.file, rw, gw, rawHyp, gatedHyp)) }
            }
            print(String(format: "ROOM %2.0f dB SNR: raw MEAN %.4f | default MEAN %.4f", snr,
                         rawTotal / Double(entries.count), gatedTotal / Double(entries.count)))
        }
    }
}
