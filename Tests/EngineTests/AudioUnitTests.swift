import Foundation
import Testing
@testable import Engine
@testable import Shared

private func sine(_ hz: Double, rate: Int, seconds: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(Double(rate) * seconds)).map { amp * Float(sin(2 * .pi * hz * Double($0) / Double(rate))) }
}

@Suite struct WAVFileTests {
    @Test func pcm16RoundTrip() throws {
        let original = WAVFile(sampleRate: 16_000, channels: 1, samples: sine(440, rate: 16_000, seconds: 0.1))
        let parsed = try WAVFile.parse(original.pcm16Data())
        #expect(parsed.sampleRate == 16_000)
        #expect(parsed.channels == 1)
        #expect(parsed.samples.count == original.samples.count)
        for (a, b) in zip(parsed.samples, original.samples) { #expect(abs(a - b) < 1e-4) }
    }

    @Test func stereoDownmixAndMetadata() throws {
        let wav = WAVFile(sampleRate: 48_000, channels: 2, samples: [0.5, -0.5, 1.0, 0.0])
        #expect(wav.frameCount == 2)
        #expect(wav.mono == [0.0, 0.5])
        let parsed = try WAVFile.parse(wav.pcm16Data())
        #expect(parsed.channels == 2 && parsed.sampleRate == 48_000 && parsed.frameCount == 2)
    }

    @Test func rejectsGarbage() {
        #expect(throws: WAVFile.WAVError.notRIFF) { try WAVFile.parse(Data([1, 2, 3])) }
    }

    @Test func readsRealFixture() throws {
        let url = try #require(AudioFixtures.url("vad", "vad_01_3segs.wav"))
        let wav = try WAVFile.read(url: url)
        #expect(wav.sampleRate == 16_000 && wav.channels == 1)
        #expect(abs(wav.duration - 245_985.0 / 16_000) < 0.001)
    }
}

@Suite struct RingBufferTests {
    @Test func wrapsAroundAndCountsOverruns() {
        let ring = RingBuffer(capacity: 8)
        #expect(ring.write([1, 2, 3, 4, 5, 6]) == 6)
        #expect(ring.read(maxCount: 4) == [1, 2, 3, 4])
        #expect(ring.write([7, 8, 9, 10, 11, 12]) == 6)   // wraps
        #expect(ring.available == 8)
        #expect(ring.write([13]) == 0)
        #expect(ring.overruns == 1)
        #expect(ring.read() == [5, 6, 7, 8, 9, 10, 11, 12])
        #expect(ring.available == 0)
    }

    @Test func producerConsumerPreservesOrder() async {
        let ring = RingBuffer(capacity: 1024)
        let total = 100_000
        let producer = Task.detached {
            var i = 0
            while i < total {
                let n = min(100, total - i)
                let block = (i..<i + n).map(Float.init)
                var written = 0
                while written < n { written += ring.write(Array(block[written...])); if written < n { await Task.yield() } }
                i += n
            }
        }
        var got: [Float] = []
        while got.count < total { let r = ring.read(); if r.isEmpty { await Task.yield() } else { got.append(contentsOf: r) } }
        await producer.value
        #expect(got == (0..<total).map(Float.init))
    }
}

@Suite struct ConverterTests {
    @Test func resamples48kStereoTo16kMono() {
        let conv = AudioConverter16k(sampleRate: 48_000, channels: 2)
        let mono = sine(1000, rate: 48_000, seconds: 0.5)
        var stereo: [Float] = []
        for s in mono { stereo.append(s); stereo.append(s) }
        let out = conv.convert(samples: stereo)
        #expect(abs(out.count - 8000) <= 64)
        let rmsIn = (mono.reduce(0) { $0 + $1 * $1 } / Float(mono.count)).squareRoot()
        let rmsOut = (out.reduce(0) { $0 + $1 * $1 } / Float(out.count)).squareRoot()
        #expect(abs(rmsIn - rmsOut) < 0.05)
    }

    @Test func passthroughAt16kMono() {
        let conv = AudioConverter16k(sampleRate: 16_000, channels: 1)
        let s = sine(300, rate: 16_000, seconds: 0.1)
        #expect(conv.convert(samples: s) == s)
    }
}

@Suite struct MicQualityTests {
    @Test func cleanSpeechIsGood() throws {
        let wav = try WAVFile.read(url: try #require(AudioFixtures.url("clean", "clean_01_samantha.wav")))
        let q = MicQualityAnalyzer.analyze(Array(wav.samples.prefix(4800)))
        #expect(q.verdict == .good)
        #expect(!q.lowLevel)
        #expect(q.clipping < 0.002)
    }

    @Test func clippingIsFlagged() throws {
        let wav = try WAVFile.read(url: try #require(AudioFixtures.url("clipping", "clipping_x4.wav")))
        // first 300 ms may be lead-in; scan windows until one carries signal
        var worst = MicQuality.unknownGood
        var i = 0
        while i + 4800 <= wav.samples.count {
            let q = MicQualityAnalyzer.analyze(Array(wav.samples[i..<i + 4800]))
            if q.clipping > worst.clipping { worst = q }
            i += 4800
        }
        #expect(worst.clipping > 0.02)
        #expect(worst.verdict == .bad)
    }

    @Test func silenceIsLowLevel() throws {
        for name in ["silence_digital_5s.wav", "silence_lownoise_5s.wav"] {
            let wav = try WAVFile.read(url: try #require(AudioFixtures.url("silence", name)))
            let q = MicQualityAnalyzer.analyze(Array(wav.samples.prefix(4800)))
            #expect(q.lowLevel, "\(name)")
            #expect(q.verdict == .bad, "\(name)")
        }
    }

    @Test func analyzerFiresOnceAt300ms() {
        let a = MicQualityAnalyzer()
        #expect(a.feed([Float](repeating: 0, count: 8000)) == nil)     // leading pause is skipped
        #expect(a.feed([Float](repeating: 0.1, count: 3000)) == nil)
        #expect(a.feed([Float](repeating: 0.1, count: 3000)) != nil)
        #expect(a.feed([Float](repeating: 0.1, count: 3000)) == nil)
        #expect(a.result != nil)
        let quiet = MicQualityAnalyzer()
        #expect(quiet.feed([Float](repeating: 0, count: 16_000)) == nil)
        #expect(quiet.feed([Float](repeating: 0, count: 16_000))?.lowLevel == true)  // deadline hit
    }
}

@Suite struct ChunkerEndpointerTests {
    @Test func cutsAtMaxAndAtSpeechEnd() {
        var c = Chunker(minDuration: 3, maxDuration: 5)
        #expect(c.feed([Float](repeating: 0, count: 16_000 * 2)).isEmpty)
        #expect(c.markSpeechEnd() == nil)                  // only 2 s pending
        let chunks = c.feed([Float](repeating: 0, count: 16_000 * 4))
        #expect(chunks.count == 1)
        #expect(chunks[0].reason == .maxDuration)
        #expect(chunks[0].range == 0...5)
        #expect(abs(c.pendingDuration - 1) < 1e-6)
        _ = c.feed([Float](repeating: 0, count: 16_000 * 2))
        let atEnd = c.markSpeechEnd()
        #expect(atEnd?.reason == .speechEnd)
        #expect(atEnd?.range == 5...8)
        _ = c.feed([Float](repeating: 0, count: 1600))
        #expect(abs((c.flush()?.duration ?? 0) - 0.1) < 1e-6)
        #expect(c.flush() == nil)
    }

    @Test func prefersSpeechBoundaryWhenMaxHits() {
        var c = Chunker(minDuration: 3, maxDuration: 5)
        _ = c.feed([Float](repeating: 0, count: 16_000 * 2))
        #expect(c.markSpeechEnd() == nil)
        _ = c.feed([Float](repeating: 0, count: 16_000 * 2))   // 4 s pending, boundary at 2 s (< min) -> ignored
        let chunks = c.feed([Float](repeating: 0, count: 16_000 * 1))
        #expect(chunks.first?.range == 0...5)
    }

    @Test func endpointerDecisions() {
        var e = Endpointer(trailingSilence: 1.0, noSpeechTimeout: 5, maxUtterance: 60)
        #expect(e.tick(now: 4.9) == nil)
        e.speechStarted(at: 1.0)
        #expect(e.tick(now: 6.0) == nil)        // still in speech, past noSpeech timeout is fine
        e.speechEnded(at: 6.5)
        #expect(e.tick(now: 7.4) == nil)
        #expect(e.tick(now: 7.5) == .endpoint(at: 6.5))
        #expect(e.tick(now: 9) == nil)          // decides once
        var quiet = Endpointer(trailingSilence: 1.0, noSpeechTimeout: 5, maxUtterance: 60)
        #expect(quiet.tick(now: 5.0) == .noSpeech)
    }
}

@Suite struct InputSelectionPolicyTests {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "voiceplus.tests.\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "voiceplus.tests")
        return d
    }
    let builtIn = AudioDeviceInfo(id: 1, uid: "builtin", name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, inputChannels: 1)
    let airpods = AudioDeviceInfo(id: 2, uid: "airpods", name: "AirPods Pro", transport: .bluetooth, sampleRate: 16_000, inputChannels: 1)
    let monitor = AudioDeviceInfo(id: 3, uid: "monitor", name: "LG UltraFine", transport: .displayPort, sampleRate: 48_000, inputChannels: 2)
    let loopback = AudioDeviceInfo(id: 4, uid: "loop", name: "BlackHole 2ch", transport: .virtual, sampleRate: 48_000, inputChannels: 2)

    @Test func skipsDisplayAndVirtualDefaults() {
        let p = InputSelectionPolicy(defaults: defaults())
        #expect(p.choose(from: [builtIn, monitor, loopback], systemDefault: monitor)?.uid == "builtin")
        // Changed in 1.7.13. This used to expect "airpods": being the system default was decisive,
        // so dictation followed macOS onto the HFP/SCO mic the moment AirPods connected — 16 kHz
        // telephony bandwidth, and a large accuracy cost paid silently. A narrowband Bluetooth mic
        // no longer collects the system-default bonus. See `UtteranceRecorderTests` for the rest.
        #expect(p.choose(from: [builtIn, airpods], systemDefault: airpods)?.uid == "builtin")
        #expect(p.choose(from: [monitor, loopback], systemDefault: loopback)?.uid == "monitor")
    }

    @Test func preferencesOverrideDefault() {
        let p = InputSelectionPolicy(defaults: defaults())
        p.setPreference(true, for: "builtin")
        #expect(p.choose(from: [builtIn, airpods], systemDefault: airpods)?.uid == "builtin")
        p.setPreference(false, for: "builtin")
        #expect(p.choose(from: [builtIn, airpods], systemDefault: builtIn)?.uid == "airpods")
        p.preferredUID = "airpods"
        #expect(p.choose(from: [builtIn, airpods], systemDefault: builtIn)?.uid == "airpods")
        #expect(p.choose(from: [builtIn], systemDefault: builtIn)?.uid == "builtin") // preferred absent → fallback
        p.setPreference(nil, for: "builtin")
        #expect(p.preference(for: "builtin") == nil)
    }

    @Test func keepsCurrentDeviceWhenStillPresent() {
        let p = InputSelectionPolicy(defaults: defaults())
        #expect(p.choose(from: [builtIn, airpods], systemDefault: builtIn, current: airpods)?.uid == "airpods")
    }
}
