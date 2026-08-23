import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// P1.12 T4 — chaos pass at the integration seams. Device-swap-mid-utterance at the audio
/// layer is covered by `EngineTests/AudioPipelineTests.deviceSwapMidUtteranceDropsNothing`;
/// here the same swap runs through the P1.12 `PipelineAudioSource` bridge into `RealEngine`.
/// Download resume (HTTP Range + SHA256) is covered by `EngineTests/ASRModelManagerTests`;
/// here the *interruption → retry* path is driven through the onboarding `ModelManaging` tier API.
@Suite("P1.12 — chaos pass")
struct ChaosTests {
    // MARK: Device swap mid-utterance through the RealEngine bridge

    final class EchoRecognizer: FinalRecognizer, @unchecked Sendable {
        let name = "echo"
        private(set) var received = 0
        func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
            received = samples.count
            return [TranscriptSpan(text: "\(samples.count)", confidence: 1, audioRange: 0...(Double(samples.count) / 16_000), provenance: [.asr])]
        }
    }

    @Test func deviceSwapMidUtteranceThroughBridgeDropsNothing() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_03_rishi.wav"))
        let wav = try WAVFile.read(url: url)
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD())
        let bridge = PipelineAudioSource(pipeline: pipeline)
        bridge.requireMicrophonePermission = false
        let recognizer = EchoRecognizer()
        let engine = RealEngine(audio: bridge, provider: StaticRecognizerProvider(final: recognizer))

        try await engine.start(prewarm: true)
        let airpods = AudioDeviceInfo(id: 2, uid: "airpods", name: "AirPods", transport: .bluetooth, sampleRate: 16_000, inputChannels: 1)
        var i = 0, swaps = 0
        while i < wav.samples.count {
            let end = min(i + 800, wav.samples.count)
            source.push(Array(wav.samples[i..<end]))
            i = end
            if i % (800 * 7) == 0 { try source.switchDevice(to: swaps % 2 == 0 ? airpods : nil); swaps += 1 }
        }
        await pipeline.drain()
        let spans = try await engine.stop()
        #expect(swaps >= 5)
        #expect(spans.first?.text == "\(wav.samples.count)", "bridge must deliver every sample across \(swaps) swaps")
        #expect(await engine.bufferedSampleCount() == wav.samples.count)
    }

    @Test func missingMicrophonePermissionFailsStartWithoutCrashing() async throws {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        let bridge = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD()))
        bridge.requireMicrophonePermission = true
        let engine = RealEngine(audio: bridge, provider: StaticRecognizerProvider(final: EchoRecognizer()))
        if PipelineAudioSource.microphoneAuthorized {
            // This test process is already trusted for the mic; nothing to prove here.
            return
        }
        await #expect(throws: AudioCaptureError.noInputDevice) { try await engine.start(prewarm: true) }
        #expect(engine.state == .idle || engine.state.caseName == "error" || engine.state.caseName == "idle")
    }

    // MARK: Focus churn → abort + queue + redeliver

    @Test func focusChurnAbortsInjectionAndRedeliversWhenFocusReturns() async throws {
        let system = MockSystemAccess()
        let textEdit = try #require(system.frontmost)
        let injector = TextInjector(system: system)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
        let spans = [TranscriptSpan(text: "meet at noon", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]

        // Snapshot at key release = TextEdit; by the time the final pass lands, Slack is in front.
        let release = injector.focusGuard.snapshot()
        system.frontmost = FocusSnapshot(pid: 200, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        let result = await lander.land(spans, startedAt: Date(), focus: release)
        guard case .abortedFocusChanged? = result.injection else {
            Issue.record("expected abort, got \(String(describing: result.injection))"); return
        }
        #expect(system.field.value.isEmpty, "nothing may be typed into the wrong app")
        #expect(system.journal.isEmpty)
        #expect(injector.focusGuard.queue.count == 1)

        // Still in Slack: flush delivers nothing.
        #expect(injector.flushQueue().isEmpty)
        // Back to TextEdit: the queued utterance lands there.
        system.frontmost = textEdit
        let delivered = injector.flushQueue()
        #expect(delivered.count == 1 && delivered[0].succeeded)
        #expect(system.field.value.lowercased().contains("meet at noon"))
    }

    @Test("chaos: random focus flips across 30 landings never leak text", arguments: [1, 7, 13])
    func randomFocusFlips(seed: UInt64) async throws {
        var rng = SplitMix(seed: seed)
        let system = MockSystemAccess()
        let home = try #require(system.frontmost)
        let other = FocusSnapshot(pid: 300, bundleID: "com.apple.Safari", appName: "Safari")
        let injector = TextInjector(system: system)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
        var landed = 0
        for n in 0..<30 {
            system.frontmost = home
            let snap = injector.focusGuard.snapshot()
            if rng.next() % 2 == 0 { system.frontmost = other }
            let r = await lander.land([TranscriptSpan(text: "word\(n)", confidence: 0.9, audioRange: 0...1, provenance: [.asr])],
                                      startedAt: Date(), focus: snap)
            if r.landed { landed += 1 }
        }
        let typedIntoOther = system.journal.filter { $0.contains("(300)") }
        #expect(typedIntoOther.isEmpty, "text reached Safari: \(typedIntoOther)")
        #expect(landed + injector.focusGuard.queue.count == 30)
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Model download interruption → resume through the tier API

    /// Fails the first `failures` fetches, then writes the required files.
    final class FlakyFetcher: ModelFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        var failures: Int
        init(failures: Int) { self.failures = failures }
        func fetch(_ descriptor: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            let n = lock.withLock { calls += 1; return calls }
            progress?(DownloadProgressInfo(modelID: descriptor.id, fraction: 0.3, bytesReceived: 1, bytesExpected: 3))
            if n <= failures { throw URLError(.networkConnectionLost) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for p in descriptor.requiredPaths {
                let f = folder.appendingPathComponent(p)
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("stub".utf8).write(to: f)
            }
            progress?(DownloadProgressInfo(modelID: descriptor.id, fraction: 1, bytesReceived: 3, bytesExpected: 3))
        }
    }

    @Test func modelDownloadInterruptionThenResumeViaTiers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-chaos-\(UUID().uuidString)")
        let fetcher = FlakyFetcher(failures: 1)
        let manager = ModelManager(root: root, fetchers: [.finalTDT: fetcher, .streamingEOU: fetcher], externalCaches: [:])
        let tiers = ModelManagerTiers(manager: manager, settings: InMemorySettingsStore())
        await tiers.refresh()
        #expect(!tiers.isInstalled(.fast))

        var progress: [Double] = []
        let sink = ProgressBox()
        await #expect(throws: (any Error).self) {
            try await tiers.download(.fast) { sink.append($0) }
        }
        await tiers.refresh()
        #expect(!tiers.isInstalled(.fast), "a torn download must not count as installed")
        #expect(await manager.status(.parakeetTDTCTC110m) == .missing)

        try await tiers.download(.fast) { sink.append($0) }
        progress = sink.values
        #expect(tiers.isInstalled(.fast))
        #expect(await manager.isPresent(.parakeetTDTCTC110m))
        #expect(fetcher.calls == 2)
        #expect(progress.last == 1)
        try? FileManager.default.removeItem(at: root)
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Double] = []
        func append(_ v: Double) { lock.withLock { items.append(v) } }
        var values: [Double] { lock.withLock { items } }
    }

    // MARK: 10k-word session through the pipeline

    static func words(_ n: Int) -> [TranscriptSpan] {
        let vocab = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "then", "um", "we", "ship",
                     "the", "release", "on", "thursday", "period", "new", "line", "please", "review", "the", "numbers"]
        var out: [TranscriptSpan] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let start: TimeInterval = Double(i) * 0.3
            let end: TimeInterval = start + 0.3
            let conf: Float = i % 37 == 0 ? 0.3 : 0.9
            out.append(TranscriptSpan(text: vocab[i % vocab.count], confidence: conf, audioRange: start...end, provenance: [.asr]))
        }
        return out
    }

    @Test func tenThousandWordSessionHoldsContractsAndScalesLinearly() async throws {
        let runner = PipelineRunner(stages: StageRegistry.allStages().filter { $0.id != .gatekeeper }, policy: .strict)
        let ctx = StageContext(register: .prose, appBundleID: "com.apple.TextEdit")

        // Session of 100 utterances × 100 words = 10k words (how a real 10k-word session arrives).
        var totalMs = 0.0
        var sessionWords = 0
        for _ in 0..<100 {
            let r = try await runner.run(Self.words(100), context: ctx)
            #expect(r.metrics.allSatisfy { $0.contractViolations.isEmpty }, "violations: \(r.metrics.flatMap(\.contractViolations))")
            #expect(r.spans.count == 100)
            totalMs += r.totalLatencyMs
            sessionWords += r.spans.count
        }
        #expect(sessionWords == 10_000)
        print("10k-word session: \(Int(totalMs)) ms total, \(String(format: "%.2f", totalMs / 100)) ms per 100-word utterance")
        #expect(totalMs / 100 < 250, "per-utterance pipeline must stay under the 250 ms budget")

        // Single 10k-word utterance (pathological hands-free run): must not blow up super-linearly.
        func timed(_ n: Int) async throws -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = try await runner.run(Self.words(n), context: ctx)
            #expect(r.metrics.allSatisfy { $0.contractViolations.isEmpty })
            #expect(r.spans.count == n)
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        }
        _ = try await timed(1_000) // warm
        let t1k = try await timed(1_000)
        let t10k = try await timed(10_000)
        print("single utterance: 1k=\(Int(t1k)) ms, 10k=\(Int(t10k)) ms (ratio \(String(format: "%.1f", t10k / max(t1k, 0.1))))")
        #expect(t10k < max(t1k, 1) * 40, "10k words took \(t10k) ms vs 1k \(t1k) ms — worse than ~O(n)")
    }
}
