import AVFoundation
import CoreAudio
import Foundation
import Testing
import Shared
@testable import Engine

/// The "Listening · quiet" for ever failure, in the two layers that can now see it.
///
/// What is exercised: the pure silence verdict (`CaptureSilenceWatchdog`), the pipeline emitting
/// `.captureFailed` for a stream of zero-filled blocks, and `CoreAudioCaptureSource` rebuilding its
/// graph when `AVAudioEngine` reports a configuration change (which detaches the installed tap).
///
/// What cannot be exercised here, and must be checked on hardware: that macOS really does deliver
/// zero-filled buffers rather than an error for a microphone it is silencing, that
/// `AVAudioEngineConfigurationChange` really fires for the route changes the owner hits, and that
/// `AVCaptureDevice.authorizationStatus` reports what the TCC database holds for an ad-hoc
/// signature. No XCTest, no simulator and no microphone exist on this machine.
@Suite("Capture silence: a stream that is open and silenced")
struct CaptureSilenceTests {

    // MARK: - The pure verdict

    @Test("three seconds of bit-exact zeros is reported once, with the elapsed silence")
    func zerosAreReportedOnce() throws {
        var w = CaptureSilenceWatchdog(timeout: 3)
        #expect(w.isArmed)
        // 50 ms blocks, as the live tap delivers. Float accumulation makes the reported total
        // approximate, so the assertion is on the verdict and a tolerance, not on an exact Double.
        var fired: TimeInterval?
        for _ in 0..<80 {
            if case .digitalSilence(let s) = w.note(seconds: 0.05, allZero: true), fired == nil { fired = s }
        }
        let seconds = try #require(fired)
        #expect(abs(seconds - 3.0) < 0.06)
        // Once reported it is spent: a second `.captureFailed` for one capture would be noise.
        #expect(!w.isArmed)
        for _ in 0..<100 { #expect(w.note(seconds: 0.05, allZero: true) == .healthy) }
    }

    @Test("one non-zero sample disarms it for the rest of the capture — a quiet room is not this")
    func realAudioDisarmsIt() {
        var w = CaptureSilenceWatchdog(timeout: 1)
        for _ in 0..<10 { w.note(seconds: 0.05, allZero: true) }
        #expect(w.note(seconds: 0.05, allZero: false) == .healthy)
        #expect(!w.isArmed)
        // A microphone that worked and then went silent is `listeningQuiet`/A06 territory, not a
        // broken capture: hours of zeros after real audio must still report healthy.
        for _ in 0..<10_000 { #expect(w.note(seconds: 0.05, allZero: true) == .healthy) }
    }

    /// `realAudioDisarmsIt` proves the *disarm latch*: zeros after audio are healthy. That is not
    /// yet the quiet-room claim, because a quiet room is never zero to begin with — it dithers from
    /// the first block. Stated separately so the claim is tested rather than implied.
    @Test("a quiet room never arms it: a live noise floor is non-zero in every block")
    func quietRoomNeverFires() {
        var w = CaptureSilenceWatchdog(timeout: 3)
        // An hour of a quiet room, one 50 ms block at a time, each carrying ±1 LSB of dither.
        for _ in 0..<72_000 { #expect(w.note(seconds: 0.05, allZero: false) == .healthy) }
        #expect(!w.isArmed, "a capture that has heard its own noise floor can no longer be called silenced")
    }

    @Test("a zero timeout disables it")
    func disabled() {
        var w = CaptureSilenceWatchdog(timeout: 0)
        #expect(!w.isArmed)
        for _ in 0..<1000 { #expect(w.note(seconds: 0.05, allZero: true) == .healthy) }
    }

    @Test("reset re-arms it for the next capture")
    func resetRearms() {
        var w = CaptureSilenceWatchdog(timeout: 1)
        for _ in 0..<20 { w.note(seconds: 0.05, allZero: true) }
        #expect(!w.isArmed)
        w.reset()
        #expect(w.isArmed)
        var fired = false
        for _ in 0..<30 {
            if case .digitalSilence = w.note(seconds: 0.05, allZero: true) { fired = true }
        }
        #expect(fired)
    }

    @Test("the reason names the device and points at the microphone grant")
    func reasonCopy() {
        let reason = CaptureSilenceWatchdog.reason(device: "MacBook Pro Microphone", seconds: 3)
        #expect(reason.contains("MacBook Pro Microphone"))
        #expect(reason.contains("microphone access"))
    }

    // MARK: - The pipeline

    /// A capture source that delivers whatever samples it is told to, on demand.
    final class ScriptedSource: AudioCaptureSource, @unchecked Sendable {
        var device: AudioDeviceInfo? = AudioDeviceInfo(id: 1, uid: "fake", name: "Fake Mic",
                                                       transport: .builtIn, sampleRate: 16_000, inputChannels: 1)
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        func prewarm() throws {}
        func start() throws {}
        func stop() {}
        func switchDevice(to device: AudioDeviceInfo?) throws { self.device = device }

        /// One ≈50 ms block.
        func push(_ samples: [Float]) { samples.withUnsafeBufferPointer { sink?($0) } }
        func pushSilence(blocks: Int) { for _ in 0..<blocks { push([Float](repeating: 0, count: 800)) } }
    }

    /// Collects events until `stop` is awaited, so an assertion reads a complete run.
    @Test("a stream of zero-filled blocks is reported as a capture failure, not as a quiet room")
    func pipelineReportsDigitalSilence() async throws {
        let source = ScriptedSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0          // blocks *do* arrive; only the silence watchdog applies
        options.digitalSilenceTimeout = 1.0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let events = pipeline.events()
        let failures = Collector()
        let task = Task.detached {
            for await event in events {
                if case .captureFailed(let reason) = event { failures.append(reason) }
                if case .stopped = event { return }
            }
        }
        try await pipeline.start()
        source.pushSilence(blocks: 25)      // 1.25 s of exact zeros
        await pipeline.drain()
        await pipeline.stop()
        await task.value
        let reasons = failures.all
        #expect(reasons.count == 1, "exactly one report per capture, got \(reasons)")
        #expect(reasons.first?.contains("Fake Mic") == true)
    }

    @Test("real audio in the same window keeps the capture healthy")
    func pipelineStaysQuietForRealAudio() async throws {
        let source = ScriptedSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.digitalSilenceTimeout = 1.0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let events = pipeline.events()
        let failures = Collector()
        let task = Task.detached {
            for await event in events {
                if case .captureFailed(let reason) = event { failures.append(reason) }
                if case .stopped = event { return }
            }
        }
        try await pipeline.start()
        // A quiet room as a live input actually renders it: every block non-zero at ±1 LSB of a
        // 16-bit converter, for far longer than the timeout. This is the case the watchdog must
        // never claim — and it is tested as a continuous noise floor, not as one non-zero block
        // followed by zeros, because the latter only exercises the disarm latch and would still
        // pass if `allZero` were computed per-capture instead of per-block.
        let lsb: Float = 1.0 / 32_768
        for b in 0..<200 {
            source.push((0..<800).map { ($0 + b) % 2 == 0 ? lsb : -lsb })
        }
        // And after it, zeros: a microphone that worked and then was muted mid-capture is
        // `listeningQuiet`/A06 territory, not a broken capture.
        source.pushSilence(blocks: 200)
        await pipeline.drain()
        await pipeline.stop()
        await task.value
        #expect(failures.all.isEmpty)
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    // MARK: - Recovery from an AVAudioEngine configuration change

    /// `CaptureLifecycleTests.FakeCaptureDriver` with the configuration-change hook wired, so the
    /// notification can be fired by hand.
    final class ReconfiguringDriver: CaptureGraphDriver, @unchecked Sendable {
        var devices: [AudioDeviceInfo]
        var defaultDevice: AudioDeviceInfo?
        var rate: Double = 48_000
        var hasInputUnit = true
        private(set) var events: [String] = []
        private(set) var tapInstalled = false
        private(set) var engineRunning = false
        private var onConfigurationChange: (() -> Void)?

        init(devices: [AudioDeviceInfo], defaultDevice: AudioDeviceInfo?) {
            self.devices = devices
            self.defaultDevice = defaultDevice
        }

        func inputDevices() -> [AudioDeviceInfo] { devices }
        func defaultInputDevice() -> AudioDeviceInfo? { defaultDevice }
        func defaultInputDeviceID() -> AudioObjectID? { defaultDevice?.id }
        func setCurrentDevice(_ id: AudioObjectID) -> OSStatus { events.append("pin"); return noErr }
        func syncClientFormat() -> Bool { events.append("sync"); return false }
        func readFormats() -> CaptureGraphFormats {
            var f = CaptureGraphFormats()
            f.nodeInputRate = rate; f.nodeInputChannels = 1
            f.nodeOutputRate = rate; f.nodeOutputChannels = 1
            f.halHardwareRate = rate; f.halHardwareChannels = 1
            f.halClientRate = rate; f.halClientChannels = 1
            return f
        }
        func installTap(bufferSize: AVAudioFrameCount, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioFormat {
            events.append("tap"); tapInstalled = true
            return AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        }
        func removeTap() { events.append("removeTap"); tapInstalled = false }
        func prepare() { events.append("prepare") }
        func start() throws { events.append("start"); engineRunning = true }
        func pause() { events.append("pause"); engineRunning = false }
        func stop() { events.append("stop"); engineRunning = false }
        func recreateEngine() { events.append("recreate") }
        func startMonitoring(onDefaultInputChanged: @escaping (AudioDeviceInfo?) -> Void,
                             onDeviceListChanged: @escaping ([AudioDeviceInfo]) -> Void) { events.append("monitor") }
        func stopMonitoring() { events.append("stopMonitor") }
        func observeConfigurationChanges(_ onChange: @escaping () -> Void) {
            events.append("observeConfig")
            onConfigurationChange = onChange
        }
        func stopObservingConfigurationChanges() { onConfigurationChange = nil }

        /// What `AVAudioEngine` posts after it has rebuilt itself — and after it has thrown the
        /// installed tap away, which is the part that used to go unnoticed.
        func fireConfigurationChange() {
            tapInstalled = false
            engineRunning = false
            onConfigurationChange?()
        }
    }

    static let builtIn = AudioDeviceInfo(id: 10, uid: "builtin", name: "MacBook Pro Microphone",
                                         transport: .builtIn, sampleRate: 48_000, inputChannels: 1)

    @Test("a graph build registers the engine-configuration observer")
    func observerIsRegistered() throws {
        let driver = ReconfiguringDriver(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let source = CoreAudioCaptureSource(driver: driver, idleReleaseAfter: 0)
        try source.prewarm()
        #expect(driver.events.contains("observeConfig"))
    }

    @Test("a configuration change while the graph is paused re-installs the tap before the next press")
    func pausedGraphIsRebuilt() throws {
        let driver = ReconfiguringDriver(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let source = CoreAudioCaptureSource(driver: driver, idleReleaseAfter: 0)
        try source.prewarm()
        try source.start()
        source.stop()
        #expect(source.phase == .paused)
        #expect(driver.tapInstalled)

        // The engine rebuilds itself between turns and takes the tap with it. Before this fix the
        // next `start()` was one `engine.start()` onto that dead tap: capture "opened", the mic
        // indicator lit, and not one buffer arrived for the rest of the session.
        driver.fireConfigurationChange()
        #expect(driver.tapInstalled, "the graph must be rebuilt, tap and all")
        // A rebuild between turns leaves the graph `prepared` — built, pinned, tapped, engine not
        // started — which is the same promise `paused` made: the microphone stays closed.
        #expect(source.phase == .prepared)
        #expect(!driver.engineRunning, "a rebuild between turns must not open the microphone")

        try source.start()
        #expect(driver.engineRunning)
        #expect(source.phase == .running)
    }

    @Test("a configuration change mid-capture restarts the engine, so a held key keeps recording")
    func runningGraphIsRestarted() throws {
        let driver = ReconfiguringDriver(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let source = CoreAudioCaptureSource(driver: driver, idleReleaseAfter: 0)
        try source.prewarm()
        try source.start()
        #expect(source.phase == .running)

        driver.fireConfigurationChange()
        #expect(source.phase == .running)
        #expect(driver.tapInstalled)
        #expect(driver.engineRunning)
    }

    @Test("a configuration change with nothing built does nothing")
    func stoppedGraphIsLeftAlone() throws {
        let driver = ReconfiguringDriver(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let source = CoreAudioCaptureSource(driver: driver, idleReleaseAfter: 0)
        try source.prewarm()
        source.release(reason: .quit)
        #expect(source.phase == .stopped)
        let before = driver.events.count
        driver.fireConfigurationChange()
        #expect(driver.events.count == before)
    }

    // MARK: - A silent capture is released, not paused

    @Test("the silent release reason tears the graph down so the next press builds a cold one")
    func silentReleaseStopsTheGraph() throws {
        let driver = ReconfiguringDriver(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let source = CoreAudioCaptureSource(driver: driver, idleReleaseAfter: 0)
        try source.prewarm()
        try source.start()
        source.release(reason: .silent)
        #expect(source.phase == .stopped)
        #expect(!driver.tapInstalled)
        #expect(source.diagnostics.lastRelease == .silent)
    }

    @Test("a denied microphone grant classifies as P01, not as missing hardware")
    func deniedGrantIsAPermissionsFailure() {
        #expect(EngineMessage.recoveryID(for: AudioCaptureError.notPermitted(status: "turned off")) == .P01)
        #expect(EngineMessage.describe(AudioCaptureError.notPermitted(status: "turned off"),
                                      log: Log(category: "silence-test", buffer: LogBuffer(capacity: 2)))
                == "Microphone access is off")
        // The old behaviour, kept honest: no *device* is still A01.
        #expect(EngineMessage.recoveryID(for: AudioCaptureError.noInputDevice) == .A01)
    }
}
