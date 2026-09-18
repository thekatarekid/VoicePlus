import CoreAudio
import Foundation
import Testing
@testable import Engine
@testable import Shared

private func collect(_ pipeline: AudioPipeline, run: @escaping () async throws -> Void) async throws -> [AudioPipelineEvent] {
    let stream = pipeline.events()
    let collector = Task { () -> [AudioPipelineEvent] in
        var out: [AudioPipelineEvent] = []
        for await e in stream { out.append(e); if case .stopped = e { break } }
        return out
    }
    try await run()
    return await collector.value
}

/// Collects the first `.captureFailed` reason, giving up after `timeout` so a broken watchdog
/// fails the test instead of hanging it.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    var value: String? { lock.withLock { storage } }
    func set(_ v: String) { lock.withLock { if storage == nil { storage = v } } }
}

@Suite struct AudioPipelineTests {
    /// BUG (1.6.3): capture "started" on a graph whose tap could never fire, and the pipeline had no
    /// way to say so — the meter simply never moved. A started pipeline must deliver `.level` blocks,
    /// and `.started` must name the device it actually opened (it used to always report nil, because
    /// wrapped sources resolve `device` only once the inner source has opened the HAL).
    @Test func startedPipelineDeliversLevelBlocksAndNamesItsDevice() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_02_daniel.wav"))
        let source = try FixtureCaptureSource(url: url)
        let pipeline = AudioPipeline(source: AcousticCaptureSource(wrapping: source, profile: .raw), vad: EnergyVAD())
        let events = try await collect(pipeline) { try await pipeline.start(); await pipeline.stop() }

        guard case .started(let device)? = events.first else { Issue.record("no .started"); return }
        #expect(device == .fixture, "`.started` must carry the device capture actually opened")
        let levels = events.compactMap { e -> Float? in if case .level(let rms) = e { return rms }; return nil }
        #expect(!levels.isEmpty, "a started pipeline delivered no level blocks")
        #expect(levels.contains { $0 > 0 }, "every level block was digital silence")
        #expect(!events.contains { if case .captureFailed = $0 { return true }; return false },
                "the watchdog fired on a pipeline that was delivering audio")
    }

    /// The watchdog itself: a source that starts cleanly and delivers nothing must surface a real
    /// error, not silence. This is the 1.6.3 shape exactly — `engine.start()` succeeded, `isRunning`
    /// was true, and not one buffer ever arrived.
    @Test func noAudioWatchdogReportsAnErrorWhenTheSourceDeliversNothing() async throws {
        let silent = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0.2
        let pipeline = AudioPipeline(source: silent, vad: EnergyVAD(), options: options)
        let box = EventBox()
        let stream = pipeline.events()
        let reader = Task {
            for await e in stream {
                if case .captureFailed(let reason) = e { box.set(reason); return }
                if case .stopped = e { return }
            }
        }
        try await pipeline.start()
        let deadline = Date().addingTimeInterval(3)
        while box.value == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        reader.cancel()
        await pipeline.stop()

        let reason = try #require(box.value, "the no-audio watchdog never fired")
        #expect(reason.contains("not one audio block arrived"))
    }

    /// Disabling the watchdog must not make it fire late.
    @Test func watchdogCanBeDisabled() async throws {
        let silent = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: silent, vad: EnergyVAD(), options: options)
        let box = EventBox()
        let stream = pipeline.events()
        let reader = Task { for await e in stream { if case .captureFailed(let r) = e { box.set(r) }; if case .stopped = e { return } } }
        try await pipeline.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        await pipeline.stop()
        _ = await reader.value
        #expect(box.value == nil)
    }

    @Test func replayedFixtureFlowsThroughWholePipeline() async throws {
        let url = try #require(AudioFixtures.url("vad", "vad_02_4segs.wav"))
        let wav = try WAVFile.read(url: url)
        let source = try FixtureCaptureSource(url: url)
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD())
        let events = try await collect(pipeline) {
            try await pipeline.prewarm()
            try await pipeline.start()      // synchronous replay
            await pipeline.stop()
        }
        guard case .started(let dev)? = events.first else { Issue.record("no started"); return }
        #expect(dev == .fixture)
        var audio: [Float] = []
        var chunks: [AudioChunk] = []
        var vad: [VADEvent] = []
        var quality: [MicQuality] = []
        var total = -1
        for e in events {
            switch e {
            case .audio(let s, _): audio.append(contentsOf: s)
            case .chunk(let c): chunks.append(c)
            case .vad(let v): vad.append(v)
            case .micQuality(let q): quality.append(q)
            case .stopped(let t): total = t
            default: break
            }
        }
        #expect(audio == wav.samples)                    // deterministic, byte-for-byte, nothing dropped
        #expect(total == wav.samples.count)
        #expect(quality.count == 1)
        #expect(vad.filter { if case .speechStart = $0 { return true }; return false }.count == 4)
        #expect(!chunks.isEmpty)
        #expect(chunks.flatMap(\.samples) == wav.samples) // chunks tile the utterance exactly
        for c in chunks.dropLast() { #expect(c.duration >= 3.0 - 1e-6 && c.duration <= 5.0 + 1e-6, "chunk \(c.range)") }
        var cursor: TimeInterval = 0
        for c in chunks { #expect(abs(c.range.lowerBound - cursor) < 1e-6); cursor = c.range.upperBound }
        #expect(pipeline.lastMicQuality?.verdict == .good)
    }

    @Test func latchedEndpointsOnTrailingSilence() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_02_daniel.wav"))
        var wav = try WAVFile.read(url: url)
        wav.samples.append(contentsOf: [Float](repeating: 0, count: 16_000 * 2))  // 2 s trailing silence
        let source = FixtureCaptureSource(wav: wav)
        var options = AudioPipeline.Options()
        options.latched = true
        options.endpointer = Endpointer(trailingSilence: 1.0, noSpeechTimeout: 8, maxUtterance: 60)
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let events = try await collect(pipeline) { try await pipeline.start(); await pipeline.stop() }
        let endpoints = events.compactMap { e -> Endpointer.Decision? in if case .endpoint(let d) = e { return d }; return nil }
        #expect(endpoints.count == 1)
        if case .endpoint(let at)? = endpoints.first { #expect(at < wav.duration - 1.5 && at > 0.5) } else { Issue.record("no endpoint") }
    }

    @Test func noSpeechTimesOut() async throws {
        let wav = WAVFile(sampleRate: 16_000, samples: [Float](repeating: 0, count: 16_000 * 4))
        var options = AudioPipeline.Options()
        options.latched = true
        options.endpointer = Endpointer(trailingSilence: 1.0, noSpeechTimeout: 3, maxUtterance: 60)
        let pipeline = AudioPipeline(source: FixtureCaptureSource(wav: wav), vad: EnergyVAD(), options: options)
        let events = try await collect(pipeline) { try await pipeline.start(); await pipeline.stop() }
        #expect(events.contains(.endpoint(.noSpeech)))
        // F1 (V4.18): silence is never graded — no "Mic level is very low" for a pause.
        #expect(!events.contains { if case .micQuality = $0 { return true }; return false })
    }

    /// Route-change chaos: device swaps mid-utterance must not lose a single sample.
    @Test func deviceSwapMidUtteranceDropsNothing() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_03_rishi.wav"))
        let wav = try WAVFile.read(url: url)
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))  // manual pushes
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD())
        let airpods = AudioDeviceInfo(id: 2, uid: "airpods", name: "AirPods", transport: .bluetooth, sampleRate: 16_000, inputChannels: 1)
        let events = try await collect(pipeline) {
            try await pipeline.start()
            let block = 800
            var i = 0
            var swaps = 0
            while i < wav.samples.count {
                let end = min(i + block, wav.samples.count)
                source.push(Array(wav.samples[i..<end]))
                i = end
                if i % (block * 7) == 0 {           // swap every ~350 ms
                    try source.switchDevice(to: swaps % 2 == 0 ? airpods : nil)
                    swaps += 1
                }
            }
            await pipeline.drain()
            await pipeline.stop()
        }
        var audio: [Float] = []
        var swaps = 0
        for e in events {
            if case .audio(let s, _) = e { audio.append(contentsOf: s) }
            if case .deviceChanged = e { swaps += 1 }
        }
        #expect(swaps >= 5)
        #expect(audio == wav.samples)
        #expect(!events.contains { if case .overrun = $0 { return true }; return false })
    }

    @Test func audioBuffersStreamAndRestart() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_04_samantha.wav"))
        let wav = try WAVFile.read(url: url)
        let pipeline = AudioPipeline(source: try FixtureCaptureSource(url: url), vad: EnergyVAD())
        for _ in 0..<2 {
            let buffers = pipeline.audioBuffers()
            let task = Task { var n = 0; for await b in buffers { n += b.count }; return n }
            try await pipeline.start()
            await pipeline.stop()
            #expect(await task.value == wav.samples.count)
        }
    }

    @Test func ringOverrunIsReported() {
        let ring = RingBuffer(capacity: 16)
        ring.write([Float](repeating: 0, count: 20))
        #expect(ring.overruns == 4 && ring.totalWritten == 16)
    }

    @Test func deviceEnumerationDoesNotCrash() {
        // Real HAL queries; on CI/headless there may be no devices — only shape is asserted.
        let devices = AudioDeviceEnumerator.inputDevices()
        for d in devices { #expect(!d.uid.isEmpty && d.inputChannels > 0) }
        #expect(AudioDeviceEnumerator.transport(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        let monitor = AudioDeviceMonitor()
        monitor.start(); #expect(monitor.isRunning); monitor.stop(); #expect(!monitor.isRunning)
    }
}
