import Foundation
import Testing
import Shared
@testable import Engine

/// R1.4 — **capture hardening against the three things a real microphone does.**
///
///   * **unplug while listening** — the device vanishes mid-utterance;
///   * **reconnect** — it (or another input) comes back;
///   * **sleep/wake** — the graph is torn down and rebuilt, arriving as stop-then-start.
///
/// Requirements, from V3 §5.1: state must clear, capture must not wedge, and no already-finalized
/// audio may be lost. None of that needs a HAL: it is all behaviour of `AudioCaptureSource` and its
/// wrapper, so these run against the protocol with a mock that can be told to fail, disappear and
/// come back. What is *not* covered here is the HAL itself — `CoreAudioCaptureSource`'s route
/// monitor and `AVAudioEngine`'s own teardown — which needs `--mic-selftest` on real hardware.
@Suite("Capture hot-swap and recovery")
struct CaptureHotSwapTests {

    /// A capture source that behaves like a microphone with a cable. `failNextStart` makes the next
    /// `start()` throw (the device was pulled between prewarm and start); `unplug()` fires the route
    /// callback with no device; `attach(_:)` brings one back.
    final class MockCaptureSource: AudioCaptureSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        private(set) var device: AudioDeviceInfo?
        var failNextStart: AudioCaptureError?
        var failNextPrewarm: AudioCaptureError?
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var prewarms = 0
        private(set) var isRunning = false

        init(device: AudioDeviceInfo? = .fixture) { self.device = device }

        func prewarm() throws {
            prewarms += 1
            if let e = failNextPrewarm { failNextPrewarm = nil; throw e }
        }

        func start() throws {
            starts += 1
            if let e = failNextStart { failNextStart = nil; throw e }
            isRunning = true
        }

        func stop() { stops += 1; isRunning = false }

        func switchDevice(to newDevice: AudioDeviceInfo?) throws {
            guard let newDevice else {
                let old = device
                device = nil
                isRunning = false
                onDeviceChanged?(old, nil)
                throw AudioCaptureError.noInputDevice
            }
            let old = device
            device = newDevice
            onDeviceChanged?(old, newDevice)
        }

        /// The cable comes out: the route callback fires with nothing on the other end.
        func unplug() {
            let old = device
            device = nil
            isRunning = false
            onDeviceChanged?(old, nil)
        }

        /// A device appears (reconnect, or the policy falling back to the built-in mic).
        func attach(_ new: AudioDeviceInfo) {
            let old = device
            device = new
            onDeviceChanged?(old, new)
        }

        /// Deliver audio the way a tap would.
        func push(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { sink?($0) }
        }
    }

    static func device(_ name: String, _ transport: AudioDeviceInfo.Transport = .usb, rate: Double = 48_000) -> AudioDeviceInfo {
        AudioDeviceInfo(id: UInt32(abs(name.hashValue % 1000) + 1), uid: "uid.\(name)", name: name,
                        transport: transport, sampleRate: rate, inputChannels: 1)
    }

    /// A tone, so a sink can tell whose audio it received.
    static func tone(_ value: Float, count: Int = 1600) -> [Float] { [Float](repeating: value, count: count) }

    // MARK: unplug while listening

    /// Every sample delivered before the unplug must reach the sink. The gate has one hop of
    /// internal latency, so the count is checked against the input, not for equality.
    @Test func unplugWhileListeningLosesNoAlreadyCapturedAudio() throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .raw)
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        var routes: [(AudioDeviceInfo?, AudioDeviceInfo?)] = []
        src.onDeviceChanged = { routes.append(($0, $1)) }

        try src.start()
        inner.push(Self.tone(0.5, count: 8000))     // half a second of speech, "finalized"
        #expect(received.count == 8000)

        inner.unplug()
        #expect(routes.count == 1)
        #expect(routes[0].1 == nil)
        #expect(src.device == nil)

        src.stop()
        // Nothing was dropped and nothing was replayed: the pre-unplug audio is intact.
        #expect(received.count == 8000)
        #expect(received.allSatisfy { $0 == 0.5 })
        #expect(inner.stops == 1)
    }

    /// The wedge R1.4 exists to remove. `prewarm()` marks the wrapper as pre-rolling *before* it
    /// starts the inner source; when that start throws (the device was pulled between hotkey-down
    /// and hotkey-up) the flag used to stay set, and the next `start()` concluded the inner source
    /// was already streaming and never started it. Capture then announced itself and delivered zero
    /// blocks for the rest of the session.
    @Test func failedPrewarmDoesNotWedgeTheNextStart() throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)   // preroll > 0
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }

        inner.failNextStart = .engineStartFailed("device removed")
        #expect(throws: AudioCaptureError.self) { try src.prewarm() }

        // Retry: the inner source must genuinely be started this time.
        try src.start()
        #expect(inner.isRunning)
        inner.push(Self.tone(0.4))
        src.stop()
        #expect(!received.isEmpty, "capture wedged: the retry never started the inner source")
    }

    /// The same wedge reached through `start()` rather than `prewarm()`.
    @Test func failedStartDoesNotWedgeTheNextStart() throws {
        let inner = MockCaptureSource(device: Self.device("AirPods Pro", .bluetooth, rate: 16_000))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }

        inner.failNextStart = .noInputDevice
        #expect(throws: AudioCaptureError.self) { try src.start() }
        try src.start()
        #expect(inner.isRunning)
        inner.push(Self.tone(0.3))
        src.stop()
        #expect(!received.isEmpty)
    }

    /// A `switchDevice` to nothing throws and leaves the wrapper usable rather than half-open.
    @Test func switchToNoDeviceThrowsAndStaysRecoverable() throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        try src.start()
        #expect(throws: AudioCaptureError.self) { try src.switchDevice(to: nil) }
        #expect(src.device == nil)

        // Recovery: a device comes back and audio flows again through the same wrapper.
        try src.switchDevice(to: Self.device("MacBook Pro Microphone", .builtIn))
        inner.push(Self.tone(0.6))
        #expect(!received.isEmpty)
        src.stop()
    }

    // MARK: reconnect

    /// A reconnect resets the acoustic chain (its noise floor was learned in another room) and
    /// forwards the route change, and audio from the new device is delivered.
    @Test func reconnectResetsTheChainAndKeepsDelivering() throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        var routes: [String] = []
        src.onDeviceChanged = { routes.append("\($0?.name ?? "none")->\($1?.name ?? "none")") }

        try src.start()
        inner.push(Self.tone(0.5, count: 3200))
        let before = received.count

        inner.unplug()
        inner.attach(Self.device("AirPods Pro", .bluetooth, rate: 16_000))
        #expect(routes == ["Scarlett Solo->none", "none->AirPods Pro"])
        #expect(src.bluetooth?.mode == .scoWideband, "the new device must be re-assessed")

        inner.push(Self.tone(0.5, count: 3200))
        #expect(received.count > before, "audio from the reconnected device never reached the sink")
        src.stop()
    }

    /// State clears across a route change: the pre-roll buffer holds the *old* device's last
    /// buffers, and flushing those into the utterance that starts on the new device would splice
    /// one room onto another.
    @Test func routeChangeDropsThePrerollHeldFromTheOldDevice() throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner,
                                        profile: RobustnessProfile(noiseSuppression: false, prerollSeconds: 0.5))
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }

        try src.prewarm()
        inner.push(Self.tone(0.9, count: 8000))       // captured into the pre-roll, not delivered
        #expect(received.isEmpty)

        inner.unplug()
        inner.attach(Self.device("MacBook Pro Microphone", .builtIn))
        try src.start()
        #expect(src.prerollFlushed == 0, "the old device's pre-roll was flushed into the new utterance")
        #expect(received.isEmpty)

        inner.push(Self.tone(0.2, count: 1600))
        #expect(received.allSatisfy { $0 == 0.2 }, "stale audio from the unplugged device leaked through")
        src.stop()
    }

    // MARK: sleep / wake

    /// Sleep/wake arrives as stop-then-start. Nothing the wrapper held before the sleep may appear
    /// in the utterance after it, and the second start must work.
    @Test func sleepWakeClearsHeldStateAndStartsCleanly() throws {
        let inner = MockCaptureSource(device: Self.device("MacBook Pro Microphone", .builtIn))
        let src = AcousticCaptureSource(wrapping: inner,
                                        profile: RobustnessProfile(noiseSuppression: false, prerollSeconds: 0.5))
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }

        // Before sleep: a pre-roll is captured and flushed, then live audio.
        try src.prewarm()
        inner.push(Self.tone(0.8, count: 8000))
        try src.start()
        #expect(src.prerollFlushed == 8000)
        inner.push(Self.tone(0.8, count: 1600))
        let beforeSleep = received.count

        // Sleep.
        src.stop()
        #expect(inner.stops == 1)

        // Wake: prewarm captures nothing yet, so the new utterance starts from silence, and the
        // pre-sleep counter is back to zero rather than carrying the old utterance's total.
        try src.prewarm()
        try src.start()
        #expect(src.prerollFlushed == 0, "state from before the sleep survived into the next utterance")
        #expect(received.count == beforeSleep)
        inner.push(Self.tone(0.1, count: 1600))
        #expect(received.suffix(1600).allSatisfy { $0 == 0.1 })
        src.stop()
        #expect(inner.starts >= 2, "the graph was never restarted after wake")
    }

    /// Repeated stop/start cycles must not accumulate anything: a laptop lid does this all day.
    @Test func repeatedStopStartCyclesDoNotAccumulateState() throws {
        let inner = MockCaptureSource(device: Self.device("MacBook Pro Microphone", .builtIn))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        var totals: [Int] = []
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        for _ in 0..<5 {
            received.removeAll()
            try src.start()
            inner.push(Self.tone(0.5, count: 4800))
            src.stop()
            totals.append(received.count)
        }
        #expect(Set(totals).count == 1, "each utterance must deliver the same amount: \(totals)")
        #expect(totals[0] >= 4800)
    }

    // MARK: pipeline-level: no wedge, nothing lost

    /// The same three events at the level the app sees them: `AudioPipeline` must forward the route
    /// change, keep running, and account for every sample in `.stopped(totalSamples:)`.
    @Test func pipelineSurvivesUnplugReconnectAndCountsEverySample() async throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .raw)
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: src, vad: EnergyVAD(), options: options)
        let events = pipeline.events()

        try await pipeline.start()
        inner.push(Self.tone(0.4, count: 4800))
        inner.unplug()
        inner.attach(Self.device("MacBook Pro Microphone", .builtIn))
        inner.push(Self.tone(0.4, count: 4800))
        await pipeline.drain()
        await pipeline.stop()

        var routed: [String] = []
        var failures: [String] = []
        var total = 0
        for await event in events {
            switch event {
            case .deviceChanged(let from, let to): routed.append("\(from?.name ?? "none")->\(to?.name ?? "none")")
            case .captureFailed(let reason): failures.append(reason)
            case .stopped(let t): total = t
            default: break
            }
            if case .stopped = event { break }
        }
        #expect(routed == ["Scarlett Solo->none", "none->MacBook Pro Microphone"])
        #expect(failures.isEmpty, "an unplug-and-reconnect must not be reported as a capture failure")
        #expect(total == 9600, "audio was lost across the route change: \(total) of 9600")
    }

    /// A start that fails is reported once and leaves the pipeline restartable — the "no wedge"
    /// requirement one level up from `failedStartDoesNotWedgeTheNextStart`.
    @Test func pipelineRestartsAfterAFailedStart() async throws {
        let inner = MockCaptureSource(device: Self.device("Scarlett Solo"))
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: src, vad: EnergyVAD(), options: options)
        let events = pipeline.events()

        inner.failNextStart = .engineStartFailed("device removed")
        await #expect(throws: AudioCaptureError.self) { try await pipeline.start() }

        try await pipeline.start()
        inner.push(Self.tone(0.4, count: 3200))
        await pipeline.drain()
        await pipeline.stop()

        // A failed start unwinds the worker, so it emits `.captureFailed` *and* a `.stopped(0)` of
        // its own before the retry; the second `.stopped` is the one that carries the recovered
        // audio. Both are collected rather than breaking on the first.
        var failures = 0
        var stops: [Int] = []
        for await event in events {
            if case .captureFailed = event { failures += 1 }
            if case .stopped(let t) = event {
                stops.append(t)
                if stops.count == 2 { break }
            }
        }
        #expect(failures == 1, "the failed start must be reported exactly once")
        #expect(stops.first == 0, "the unwind of the failed start must report nothing captured")
        #expect((stops.last ?? -1) >= 3200, "the pipeline never recovered: \(stops)")
    }

    // MARK: manifest and graph must agree (R1.4 acceptance)

    /// A source that reports a resolved graph, so the manifest's `aec` can be checked against it
    /// without a HAL.
    final class GraphReportingSource: AudioCaptureSource, CaptureGraphDescribing, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        var device: AudioDeviceInfo? = .fixture
        var diagnostics: AudioCaptureDiagnostics
        init(voiceProcessing: Bool) {
            var d = AudioCaptureDiagnostics()
            d.deviceName = voiceProcessing ? "MacBook Pro Microphone (VP)" : "MacBook Pro Microphone"
            d.nodeInputRate = 44_100; d.nodeInputChannels = 1
            d.nodeOutputRate = 44_100; d.nodeOutputChannels = 1
            d.tapRate = 44_100; d.tapChannels = voiceProcessing ? 5 : 1
            d.voiceProcessing = voiceProcessing
            self.diagnostics = d
        }
        func prewarm() throws {}
        func start() throws {}
        func stop() {}
        func switchDevice(to device: AudioDeviceInfo?) throws { self.device = device }
        func push(_ samples: [Float]) { samples.withUnsafeBufferPointer { sink?($0) } }
    }

    /// The contradiction R1.4 was handed: all twenty real-room manifests said
    /// `aec=appleVoiceProcessing` while their own graph line said `vp=false`, because the manifest
    /// recorded the profile's *intent*. It now records what the graph resolved to, so the two agree
    /// whichever source is wrapped.
    @Test func manifestAECMatchesTheCaptureGraph() throws {
        for vp in [false, true] {
            let inner = GraphReportingSource(voiceProcessing: vp)
            let profile: RobustnessProfile = vp ? .voiceProcessing : .default
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceplus-r14-\(vp)-\(UUID().uuidString)", isDirectory: true)
            let recorder = UtteranceRecorder(directory: dir)
            let src = AcousticCaptureSource(wrapping: inner, profile: profile, recorder: recorder)
            src.sink = { _ in }
            try src.start()
            inner.push(Self.tone(0.3, count: 16_000))
            src.stop()

            let sidecars = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
            let sidecar = try #require(sidecars.first, "the recorder wrote no manifest")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let m = try decoder.decode(UtteranceRecorder.Manifest.self, from: Data(contentsOf: sidecar))
            let graph = try #require(m.captureGraph, "the manifest recorded no capture graph")
            #expect(graph.contains("vp=\(vp)"))
            #expect(m.aec == (vp ? "appleVoiceProcessing" : "off"),
                    "manifest aec=\(m.aec) contradicts the graph (\(graph))")
            #expect(src.effectiveAEC == (vp ? .appleVoiceProcessing : .off))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The shipping wiring: `EngineFactory` wraps `CoreAudioCaptureSource`, whose graph never has
    /// voice processing, so the profile it hands the wrapper must not claim any. This is the
    /// assertion that fails if someone re-points the default at `.voiceProcessing` without
    /// swapping the capture source too.
    @Test func shippingDefaultProfileClaimsNoEchoCancellationItDoesNotRun() {
        #expect(RobustnessProfile.default.aec == .off)
        // R1.4 chose the plain tap by measurement: no gate in the shipping chain. The pre-roll is a
        // capture concern and stays, which is the only thing separating `.default` from `.raw`.
        #expect(!RobustnessProfile.default.noiseSuppression)
        #expect(RobustnessProfile.default.prerollSeconds == 0.5)
        #expect(RobustnessProfile.raw.aec == .off)
        #expect(RobustnessProfile.raw.prerollSeconds == 0)
        // The gate is still reachable, and still honest about running no echo canceller.
        #expect(RobustnessProfile.gate.noiseSuppression)
        #expect(RobustnessProfile.gate.aec == .off)
        #expect(RobustnessProfile.voiceProcessing.aec == .appleVoiceProcessing)
        #expect(RobustnessProfile.voiceProcessing.noiseSuppression, "column (c) is vp + gate")
        // A plain tap under a profile that asks for Apple VP still reports the truth.
        let liar = AcousticCaptureSource(wrapping: GraphReportingSource(voiceProcessing: false),
                                         profile: .voiceProcessing)
        #expect(liar.effectiveAEC == .off)
    }

    /// A wrapper forwards the graph of whatever it wraps, so `--mic-selftest-vp` and the recorder
    /// read the same line. Before R1.4 only `CoreAudioCaptureSource` was cast for this, so a
    /// voice-processing run recorded no graph at all.
    @Test func wrapperForwardsTheInnerGraphWhicheverSourceItIs() {
        let plain = AcousticCaptureSource(wrapping: GraphReportingSource(voiceProcessing: false), profile: .default)
        #expect(plain.diagnostics.summary.contains("vp=false"))
        let vp = AcousticCaptureSource(wrapping: GraphReportingSource(voiceProcessing: true), profile: .voiceProcessing)
        #expect(vp.diagnostics.summary.contains("vp=true"))
        #expect(vp.diagnostics.tapChannels == 5, "the voice-processing tap's 5-channel layout must survive forwarding")
        // A source with no graph to describe reports an empty one rather than crashing.
        let mock = AcousticCaptureSource(wrapping: MockCaptureSource(), profile: .default)
        #expect(mock.diagnostics.deviceName == "-")
    }
}
