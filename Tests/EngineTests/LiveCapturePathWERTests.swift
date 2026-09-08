import AVFoundation
import Foundation
import Testing
import Shared
@testable import Engine

/// WER through the *live capture* resampling path.
///
/// Why this suite exists. `ASRGoldenTranscriptTests` feeds 16 kHz WAVs straight into the
/// recognizer. `AcousticChainWERTests` adds the DSP chain — but still at 16 kHz. In both,
/// `AudioConverter16k` is a **no-op**: its initialiser sets `converter = nil` when the source is
/// already 16 kHz mono Float32. So every accuracy number measured before this file was written
/// exercised zero sample-rate conversion.
///
/// The real microphone never does that. `CoreAudioCaptureSource` installs its tap at the hardware
/// format — on this machine the unified log shows 41 of 41 capture graphs at
/// `tap=44100Hz/1ch` — and every buffer goes through `AVAudioConverter` 44100 → 16000 in
/// ~2048-frame blocks before anything else sees it. That link was the last unmeasured one in the
/// chain, which is exactly why it was worth measuring.
///
/// These tests close the gap: fixture → resample up to the hardware rate → chop into tap-sized
/// buffers → `AudioConverter16k` (streaming, `flush: false`, one instance for the whole utterance,
/// exactly as the tap does) → acoustic chain → recognizer.
@Suite("Live capture path WER (real model)", .serialized)
struct LiveCapturePathWERTests {

    // MARK: emulating the capture side

    /// Resamples 16 kHz mono up to `rate`, standing in for what the microphone hardware delivers.
    /// One-shot and high quality, so it contributes no error of its own worth speaking of.
    static func resample(_ samples: [Float], from source: Double = 16_000, to rate: Double) throws -> [Float] {
        guard rate != source else { return samples }
        let inFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false))
        let outFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: inFormat, to: outFormat))
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * rate / source) + 8192
        let output = try #require(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity))
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        #expect(error == nil)
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Feeds `samples` (already at `hardwareRate`) through `AudioConverter16k` the way the live tap
    /// does: one converter for the whole utterance, tap-sized buffers, streaming (`flush: false`).
    static func throughTapConverter(_ samples: [Float], hardwareRate: Double, tapFrames: Int = 2048) throws -> [Float] {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareRate, channels: 1, interleaved: false))
        let converter = AudioConverter16k(inputFormat: format)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * 16_000 / hardwareRate) + tapFrames)
        var i = 0
        while i < samples.count {
            let end = min(i + tapFrames, samples.count)
            let block = Array(samples[i..<end])
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)) else { break }
            buffer.frameLength = AVAudioFrameCount(block.count)
            block.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: block.count)
            }
            out.append(contentsOf: converter.convert(buffer, flush: false))
            i = end
        }
        return out
    }

    /// fixture 16 kHz → hardware rate → tap → `AudioConverter16k` → back at 16 kHz.
    static func throughLiveCapture(_ samples: [Float], hardwareRate: Double) throws -> [Float] {
        try throughTapConverter(try resample(samples, to: hardwareRate), hardwareRate: hardwareRate)
    }

    // MARK: measurements that need no model

    /// The duration test. A resample that loses or gains samples is a time warp, and a time warp
    /// is exactly the failure that yields phonetically-adjacent substitutions with the right
    /// syllable count. Anything worse than 0.5 % over a whole utterance would be audible drift.
    @Test func liveCaptureConversionPreservesDuration() throws {
        let seconds = 4.0
        let tone = (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.3 }
        for rate in [44_100.0, 48_000.0] {
            let out = try Self.throughLiveCapture(tone, hardwareRate: rate)
            let ratio = Double(out.count) / Double(tone.count)
            print(String(format: "[duration] hardware %.0f Hz: %d in -> %d out (%.4f x, %.3f s vs %.3f s)",
                         rate, tone.count, out.count, ratio, Double(out.count) / 16_000, seconds))
            #expect(abs(ratio - 1.0) < 0.005, "44.1/48 kHz capture must not time-warp the audio")
        }
    }

    /// The streaming test. The live tap calls `convert(_:flush:)` thousands of times on one
    /// converter instance; a per-call priming or tail bug shows up as a growing shortfall.
    @Test func streamingTapConversionMatchesOneShotWithinAFewMilliseconds() throws {
        let tone = (0..<(16_000 * 10)).map { Float(sin(Double($0) * 2 * .pi * 300 / 16_000)) * 0.3 }
        let hardware = try Self.resample(tone, to: 44_100)
        let streamed = try Self.throughTapConverter(hardware, hardwareRate: 44_100, tapFrames: 2048)
        let oneShot = try Self.throughTapConverter(hardware, hardwareRate: 44_100, tapFrames: hardware.count)
        let drift = abs(streamed.count - oneShot.count)
        print("[streaming] 10 s: streamed \(streamed.count), one-shot \(oneShot.count), drift \(drift) samples (\(Double(drift) / 16.0) ms)")
        #expect(drift < 16_000 / 20, "block size must not change how much audio survives")
    }

    // MARK: measurement that needs the model

    /// The one that matters: does clean speech survive the resample the real microphone forces?
    /// Compared against the same fixtures fed at native 16 kHz, so the delta is attributable.
    @Test(.timeLimit(.minutes(30)))
    func liveCaptureResamplingDoesNotDegradeCleanSpeech() async throws {
        let manager = ModelManager()
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let (dir, entries) = try AcousticChainWERTests.loadFixtures()
        let final = try await RecognizerFactory.makeFinal(manager: manager)

        func measure(_ label: String, _ prepare: ([Float]) throws -> [Float]) async throws -> Double {
            var total = 0.0
            for e in entries {
                let raw = try SampleAudioSource.load16k(url: dir.appendingPathComponent(e.file))
                let processed = AcousticChainWERTests.throughChain(try prepare(raw), profile: .default)
                let hyp = try await final.recognize(processed).joinedText
                let wer = wordErrorRate(reference: e.transcript, hypothesis: hyp)
                total += wer
                if wer > 0.15 { print(String(format: "[%@] %@: WER %.3f | %@", label, e.file, wer, hyp)) }
            }
            let mean = total / Double(entries.count)
            print(String(format: "[%@] MEAN WER %.4f over %d fixtures", label, mean, entries.count))
            return mean
        }

        let native = try await measure("16k native") { $0 }
        let at44k = try await measure("44.1k tap") { try Self.throughLiveCapture($0, hardwareRate: 44_100) }
        let at48k = try await measure("48k tap") { try Self.throughLiveCapture($0, hardwareRate: 48_000) }
        print(String(format: "live-capture resampling cost: 44.1k %+.4f, 48k %+.4f WER vs native",
                     at44k - native, at48k - native))
        #expect(at44k < 0.10, "the 44.1 kHz capture path must not cost accuracy")
        #expect(at48k < 0.10, "the 48 kHz capture path must not cost accuracy")
    }

    // MARK: absolute level

    /// Scales `samples` so their RMS sits at `dBFS`.
    static func atLevel(_ samples: [Float], dBFS: Float) -> [Float] {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        guard rms > 0 else { return samples }
        let scale = powf(10, dBFS / 20) / rms
        return samples.map { $0 * scale }
    }

    /// The gap every earlier measurement shared. Each fixture in `Fixtures/audio/clean` is
    /// RMS-normalised to −20 dBFS, and the room-floor sweeps varied the *noise* under a signal
    /// held at that level — so absolute level was pinned at −20 dBFS in every number ever
    /// recorded. A real microphone has no such guarantee: this machine's input volume sits at
    /// 51 %, and nothing between the tap and `final.recognize` applies any gain.
    ///
    /// This sweep asks the question directly: how does clean speech score at the levels a real
    /// mic actually produces?
    @Test(.timeLimit(.minutes(30)))
    func inputLevelSweepOnCleanSpeech() async throws {
        let manager = ModelManager()
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let (dir, entries) = try AcousticChainWERTests.loadFixtures()
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let raws = try entries.map { try SampleAudioSource.load16k(url: dir.appendingPathComponent($0.file)) }

        for level in [Float(-20), -30, -40, -50, -60] {
            for profile in [RobustnessProfile.default, .raw] {
                var total = 0.0
                for (i, e) in entries.enumerated() {
                    let scaled = Self.atLevel(raws[i], dBFS: level)
                    let processed = AcousticChainWERTests.throughChain(scaled, profile: profile)
                    let hyp = try await final.recognize(processed).joinedText
                    total += wordErrorRate(reference: e.transcript, hypothesis: hyp)
                }
                print(String(format: "[level %.0f dBFS / %@] MEAN WER %.4f",
                             level, profile.noiseSuppression ? "default" : "raw", total / Double(entries.count)))
            }
        }
    }
}
