import AVFoundation
import CoreAudio
import Foundation
import Testing
import Shared
@testable import Engine

/// A1 / A4 (V4.7, V4.9) — the capture graph kept between turns, and the format sync + one-time
/// engine rebuild. `CoreAudioCaptureSource` runs here against `FakeCaptureDriver`, which models the
/// HAL and `AVAudioEngine` closely enough to reproduce the 44.1 k / 48 k mismatch and to count every
/// HAL call. What it cannot show — real AUHAL behaviour, the mic indicator while paused, the
/// key-down → first-buffer p95 — is build doc §5 items 1–3 (hardware).
@Suite("Capture lifecycle and format sync (V4.7, V4.9)")
struct CaptureLifecycleTests {

    // MARK: fixtures

    static let builtIn = AudioDeviceInfo(id: 10, uid: "builtin", name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, inputChannels: 1)
    static let airPods = AudioDeviceInfo(id: 20, uid: "airpods", name: "AirPods Pro", transport: .bluetooth, sampleRate: 24_000, inputChannels: 1)
    static let usb = AudioDeviceInfo(id: 30, uid: "usb", name: "Scarlett Solo", transport: .usb, sampleRate: 48_000, inputChannels: 2)

    /// The HAL + AVAudioEngine, in miniature. `staleCache` is the V4.9 bug: the node's cached client
    /// format does not follow the sync, so the formats still disagree afterwards.
    final class FakeCaptureDriver: CaptureGraphDriver, @unchecked Sendable {
        var devices: [AudioDeviceInfo]
        var defaultDevice: AudioDeviceInfo?
        var hardwareRate: Double
        var clientRate: Double
        var staleCache = false
        var staleRate: Double = 44_100
        /// Whether a fresh engine fixes a stale cache (true: it does; false: disagree twice).
        var recreateFixes = true
        var hasInputUnit = true
        var pinResult: OSStatus = noErr
        var failNextStart: AudioCaptureError?

        private(set) var events: [String] = []
        private(set) var tapInstalled = false
        private(set) var engineRunning = false
        private(set) var monitoring = false
        private(set) var recreations = 0
        private var tap: ((AVAudioPCMBuffer) -> Void)?
        private var onDefault: ((AudioDeviceInfo?) -> Void)?
        private var onList: (([AudioDeviceInfo]) -> Void)?

        init(devices: [AudioDeviceInfo] = [CaptureLifecycleTests.builtIn], defaultDevice: AudioDeviceInfo? = CaptureLifecycleTests.builtIn,
             hardwareRate: Double = 48_000, clientRate: Double = 48_000) {
            self.devices = devices
            self.defaultDevice = defaultDevice
            self.hardwareRate = hardwareRate
            self.clientRate = clientRate
        }

        func inputDevices() -> [AudioDeviceInfo] { events.append("enumerate"); return devices }
        func defaultInputDevice() -> AudioDeviceInfo? { events.append("default"); return defaultDevice }
        func defaultInputDeviceID() -> AudioObjectID? { events.append("defaultID"); return defaultDevice?.id }
        func setCurrentDevice(_ id: AudioObjectID) -> OSStatus {
            events.append("pin(\(id))")
            if let d = devices.first(where: { $0.id == id }) { hardwareRate = d.sampleRate }
            return pinResult
        }
        func syncClientFormat() -> Bool {
            events.append("sync")
            guard clientRate != hardwareRate else { return false }
            clientRate = hardwareRate
            return true
        }
        func readFormats() -> CaptureGraphFormats {
            var f = CaptureGraphFormats()
            f.nodeInputRate = hardwareRate
            f.nodeInputChannels = 1
            f.nodeOutputRate = staleCache ? staleRate : clientRate
            f.nodeOutputChannels = 1
            f.halHardwareRate = hardwareRate
            f.halHardwareChannels = 1
            f.halClientRate = clientRate
            f.halClientChannels = 1
            return f
        }
        func installTap(bufferSize: AVAudioFrameCount, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioFormat {
            events.append("tap")
            tapInstalled = true
            tap = onBuffer
            return AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1)!
        }
        func removeTap() { events.append("removeTap"); tapInstalled = false; tap = nil }
        func prepare() { events.append("prepare") }
        func start() throws {
            events.append("start")
            if let e = failNextStart { failNextStart = nil; throw e }
            engineRunning = true
        }
        func pause() { events.append("pause"); engineRunning = false }
        func stop() { events.append("stop"); engineRunning = false }
        func recreateEngine() {
            events.append("recreate")
            recreations += 1
            tapInstalled = false
            tap = nil
            if recreateFixes { staleCache = false }
        }
        func startMonitoring(onDefaultInputChanged: @escaping (AudioDeviceInfo?) -> Void,
                             onDeviceListChanged: @escaping ([AudioDeviceInfo]) -> Void) {
            events.append("monitor")
            monitoring = true
            onDefault = onDefaultInputChanged
            onList = onDeviceListChanged
        }
        /// Runs once, inside the next `stopMonitoring()` and before it takes effect: the window in
        /// which another thread can rebuild the graph while a release is removing the listeners.
        var onStopMonitoring: (() -> Void)?
        func stopMonitoring() {
            events.append("unmonitor")
            let hook = onStopMonitoring
            onStopMonitoring = nil
            hook?()
            monitoring = false
        }

        /// A tap callback, the way the audio thread delivers one — only while the engine runs.
        func deliver(frames: Int = 4_800, value: Float = 0.25) {
            guard engineRunning, let tap else { return }
            let format = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buffer.floatChannelData![0][i] = value }
            tap(buffer)
        }

        /// The system default input changes (AirPods connect).
        func changeDefault(to device: AudioDeviceInfo) {
            if !devices.contains(device) { devices.append(device) }
            defaultDevice = device
            onDefault?(device)
        }

        /// A device is pulled: it leaves the list and the default falls back to what is left.
        func unplug(_ device: AudioDeviceInfo) {
            devices.removeAll { $0.uid == device.uid }
            if defaultDevice?.uid == device.uid { defaultDevice = devices.first }
            onList?(devices)
        }

        func clearEvents() { events.removeAll() }
    }

    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func add(_ n: Int) { lock.withLock { stored += n } }
    }

    /// A policy with no remembered preferences (the developer's own UserDefaults must not decide).
    static func cleanPolicy() -> InputSelectionPolicy {
        InputSelectionPolicy(defaults: UserDefaults(suiteName: "voiceplus.capture-lifecycle.\(UUID().uuidString)")!)
    }

    private func source(_ driver: FakeCaptureDriver, idle: TimeInterval = 0) -> CoreAudioCaptureSource {
        CoreAudioCaptureSource(policy: Self.cleanPolicy(), driver: driver, idleReleaseAfter: idle)
    }

    // MARK: A1 — rebuild policy (pure)

    @Test func rebuildPolicyTable() {
        #expect(GraphRebuildPolicy.decide(formatsAgree: true, rebuildsSoFar: 0) == .accept)
        #expect(GraphRebuildPolicy.decide(formatsAgree: true, rebuildsSoFar: 1) == .accept)
        #expect(GraphRebuildPolicy.decide(formatsAgree: false, rebuildsSoFar: 0) == .rebuild, "disagree after sync → rebuild once")
        #expect(GraphRebuildPolicy.decide(formatsAgree: false, rebuildsSoFar: 1) == .fail, "disagree twice → throw")
        #expect(GraphRebuildPolicy.maxRebuilds == 1)
    }

    // MARK: A1 — format sync on the default-device path

    /// V4.9: the "already the system default" path used to return before the client-format sync —
    /// the path the 44.1 k / 48 k mismatch reached users on. The sync now always runs, and says so.
    @Test func defaultDevicePathSyncsTheClientFormatAndRecordsIt() throws {
        let driver = FakeCaptureDriver(hardwareRate: 48_000, clientRate: 44_100)
        let src = source(driver)
        try src.prewarm()
        let d = src.diagnostics
        #expect(!d.pinApplied)
        #expect(d.pinSkipReason == "already the system default input")
        #expect(d.clientFormatPushed, "the default-device path must push the hardware rate onto the client scope")
        #expect(d.formatsAgree)
        #expect(d.counters.formatSyncs == 1)
        #expect(d.engineRebuilds == 0)
        #expect(!driver.events.contains { $0.hasPrefix("pin(") }, "pinning the default is what silenced 1.6.3")
        #expect(d.summary.contains("clientPush=true"))
    }

    @Test func agreeingFormatsNeedNoPushAndNoRebuild() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        try src.prewarm()
        #expect(!src.diagnostics.clientFormatPushed)
        #expect(src.diagnostics.counters.engineRecreations == 0)
        #expect(driver.recreations == 0)
    }

    /// A non-default device is pinned, and the sync still follows the pin.
    @Test func nonDefaultDeviceIsPinnedAndSynced() throws {
        let driver = FakeCaptureDriver(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn, clientRate: 44_100)
        let src = CoreAudioCaptureSource(device: Self.usb, policy: Self.cleanPolicy(), driver: driver, idleReleaseAfter: 0)
        try src.prewarm()
        #expect(src.diagnostics.pinApplied)
        #expect(src.diagnostics.clientFormatPushed)
        #expect(driver.events.contains("pin(30)"))
        #expect(src.device == Self.usb)
    }

    /// Formats still disagree after the sync (AVAudioEngine's cached client format did not follow):
    /// recreate the engine once, verify again, and build.
    @Test func staleCacheRebuildsTheEngineOnceThenBuilds() throws {
        let driver = FakeCaptureDriver(hardwareRate: 48_000, clientRate: 44_100)
        driver.staleCache = true
        let src = source(driver)
        try src.prewarm()
        #expect(driver.recreations == 1)
        #expect(src.diagnostics.engineRebuilds == 1)
        #expect(src.diagnostics.counters.engineRecreations == 1)
        #expect(src.diagnostics.formatsAgree)
        #expect(src.phase == .prepared)
        #expect(driver.tapInstalled)
        #expect(src.diagnostics.summary.contains("engineRebuilds=1"))
        // Sync ran on both attempts; the recreate happened between them.
        let e = driver.events
        let recreate = try #require(e.firstIndex(of: "recreate"))
        #expect(e[..<recreate].contains("sync") && e[recreate...].contains("sync"))
    }

    /// Disagree twice: only then `.formatMismatch`, with no tap left behind and nothing prepared.
    @Test func disagreeingTwiceThrowsFormatMismatch() throws {
        let driver = FakeCaptureDriver(hardwareRate: 48_000, clientRate: 44_100)
        driver.staleCache = true
        driver.recreateFixes = false
        let src = source(driver)
        #expect(throws: AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100)) { try src.prewarm() }
        #expect(driver.recreations == 1, "exactly one rebuild before giving up")
        #expect(src.phase == .stopped)
        #expect(!driver.tapInstalled)
        #expect(!driver.events.contains("prepare"))
        #expect(!src.isRunning)
    }

    // MARK: A4 — the capture state machine (pure)

    @Test func lifecycleTransitions() {
        var l = CaptureLifecycle()
        #expect(l.phase == .stopped)
        #expect(l.handle(.prewarm) == [.buildGraph]); #expect(l.phase == .prepared)
        #expect(l.handle(.prewarm) == [], "prewarm is idempotent")
        #expect(l.handle(.start) == [.startEngine]); #expect(l.phase == .running)
        #expect(l.handle(.start) == [])
        #expect(l.handle(.stop) == [.pauseEngine, .scheduleIdleRelease]); #expect(l.phase == .paused)
        #expect(l.handle(.prewarm) == [], "a paused graph is already built: no re-enumeration")
        #expect(l.handle(.start) == [.cancelIdleRelease, .resumeEngine]); #expect(l.phase == .running)
        #expect(l.handle(.release(.idle)) == [], "a live turn is never idle")
        #expect(l.phase == .running)
        #expect(l.handle(.stop) == [.pauseEngine, .scheduleIdleRelease])
        #expect(l.handle(.release(.idle)) == [.cancelIdleRelease, .teardown, .stopRouteMonitor]); #expect(l.phase == .stopped)
        #expect(l.handle(.stop) == [])
        #expect(l.handle(.release(.mute)) == [])
        #expect(l.handle(.start) == [.buildGraph, .startEngine]); #expect(l.phase == .running)
        #expect(l.handle(.release(.mute)) == [.cancelIdleRelease, .teardown, .stopRouteMonitor]); #expect(l.phase == .stopped)
    }

    @Test func pausedGraphStopsFullyOnEveryReleaseReason() {
        for reason in CaptureReleaseReason.allCases {
            var l = CaptureLifecycle(phase: .paused)
            let steps = l.handle(.release(reason))
            #expect(l.phase == .stopped, "\(reason)")
            #expect(steps.contains(.teardown), "\(reason)")
            // A device change keeps the monitor that noticed it; every other release stops it.
            #expect(steps.contains(.stopRouteMonitor) == (reason != .deviceChange), "\(reason)")
        }
    }

    @Test func failedStepsLeaveTheTruePhase() {
        var l = CaptureLifecycle()
        l.handle(.start)
        l.stepFailed(.buildGraph)
        #expect(l.phase == .stopped)
        l.handle(.prewarm)
        l.handle(.start)
        l.stepFailed(.startEngine)
        #expect(l.phase == .prepared)
    }

    // MARK: A4 — the real source over the fake driver

    /// prepared → running → paused → running, with the microphone closed at prepare and pause, and
    /// no HAL call at all on the warm resume.
    @Test func graphIsKeptBetweenTurnsAndResumeMakesNoHALCalls() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)

        try src.prewarm()
        #expect(src.phase == .prepared)
        #expect(!driver.engineRunning, "prewarm must not open the microphone")
        #expect(driver.monitoring, "the route monitor runs as soon as a graph exists")

        try src.start()
        #expect(src.phase == .running)
        #expect(src.diagnostics.counters.coldStarts == 1)

        src.stop()
        #expect(src.phase == .paused)
        #expect(!driver.engineRunning, "paused means the microphone is closed")
        #expect(driver.tapInstalled, "the tap stays installed between turns")
        #expect(driver.monitoring, "a device change between turns must still be seen")
        #expect(!driver.events.contains("stop"), "a turn's end is a pause, not a full stop")

        let before = src.diagnostics.counters
        driver.clearEvents()
        try src.prewarm()            // AudioPipeline.start() prewarms before every start
        try src.start()
        let after = src.diagnostics.counters
        #expect(src.phase == .running)
        #expect(after.halCalls == before.halCalls, "paused → running must not enumerate, pin or touch formats")
        #expect(after.enumerations == before.enumerations)
        #expect(after.pinWrites == before.pinWrites)
        #expect(after.graphBuilds == before.graphBuilds)
        #expect(after.warmResumes == 1)
        #expect(driver.events == ["start"], "the whole warm path is one engine.start()")
        src.stop()
    }

    @Test func hardMuteStopsThePausedGraphAndTheNextStartRebuilds() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        try src.start()
        src.stop()
        src.release(reason: .mute)
        #expect(src.phase == .stopped)
        #expect(!driver.tapInstalled)
        #expect(!driver.monitoring)
        #expect(driver.events.contains("stop"))
        #expect(src.diagnostics.lastRelease == .mute)
        #expect(src.diagnostics.counters.fullStops == 1)

        let builds = src.diagnostics.counters.graphBuilds
        try src.start()
        #expect(src.diagnostics.counters.graphBuilds == builds + 1, "after a full stop the next press is cold")
        #expect(src.diagnostics.counters.coldStarts == 2)
        src.stop()
    }

    @Test func quitReleasesEvenARunningGraph() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        try src.start()
        src.release(reason: .quit)
        #expect(src.phase == .stopped)
        #expect(!driver.engineRunning)
        #expect(!driver.monitoring)
    }

    @Test func idleReleaseTearsDownAPausedGraph() async throws {
        let driver = FakeCaptureDriver()
        let src = source(driver, idle: 0.05)
        try src.start()
        src.stop()
        #expect(src.phase == .paused)
        // The monitor is stopped just after the source's lock is released, so wait for both.
        try await waitUntil { src.phase == .stopped && !driver.monitoring }
        #expect(src.diagnostics.lastRelease == .idle)
        #expect(!driver.tapInstalled)
    }

    @Test func aResumedTurnCancelsTheIdleRelease() async throws {
        let driver = FakeCaptureDriver()
        let src = source(driver, idle: 0.1)
        try src.start()
        src.stop()
        try src.start()               // resumes before the idle deadline
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(src.phase == .running, "an idle timer from the previous pause fired on a live turn")
        src.stop()
        src.release(reason: .quit)
    }

    /// V4.9: the route monitor runs while paused, so a device change between turns rebuilds for the
    /// new device before the next press — here the USB mic in use is pulled and the policy falls
    /// back to the built-in one. (A new default alone does not move a device still present: the
    /// policy keeps the current input by design.)
    @Test func routeChangeWhilePausedRebuildsForTheNewDevice() throws {
        let driver = FakeCaptureDriver(devices: [Self.builtIn, Self.usb], defaultDevice: Self.usb)
        let src = source(driver)
        var routes: [String] = []
        src.onDeviceChanged = { routes.append("\($0?.name ?? "none")->\($1?.name ?? "none")") }
        try src.start()
        #expect(src.device == Self.usb)
        src.stop()

        driver.unplug(Self.usb)
        #expect(routes == ["Scarlett Solo->MacBook Pro Microphone"])
        #expect(src.device == Self.builtIn)
        #expect(src.phase == .prepared, "rebuilt for the new device, microphone still closed")
        #expect(!driver.engineRunning)
        #expect(src.diagnostics.lastRelease == .deviceChange)
        #expect(driver.monitoring, "the monitor that saw the change keeps watching")
        #expect(src.diagnostics.deviceName == "MacBook Pro Microphone")
        try src.start()
        #expect(src.phase == .running)
        src.stop()
    }

    /// A route change mid-turn rebuilds and keeps capturing.
    @Test func routeChangeWhileRunningRestartsOnTheNewDevice() throws {
        let driver = FakeCaptureDriver(devices: [Self.builtIn, Self.usb], defaultDevice: Self.usb)
        let src = source(driver)
        try src.start()
        driver.unplug(Self.usb)
        #expect(src.phase == .running)
        #expect(driver.engineRunning)
        #expect(src.device == Self.builtIn)
        src.release(reason: .quit)
    }

    /// A new default that is not an improvement leaves a paused graph alone: no HAL rebuild.
    @Test func aNewDefaultDoesNotMoveADeviceStillPresent() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        try src.start()
        src.stop()
        let builds = src.diagnostics.counters.graphBuilds
        driver.changeDefault(to: Self.airPods)
        #expect(src.device == Self.builtIn)
        #expect(src.phase == .paused)
        #expect(src.diagnostics.counters.graphBuilds == builds)
        src.release(reason: .quit)
    }

    /// After a full release nothing watches the route, so the next build decides afresh instead of
    /// reopening the device the old graph happened to use.
    @Test func prewarmAfterAReleaseReEnumeratesTheDevice() throws {
        let driver = FakeCaptureDriver(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn)
        let src = source(driver)
        try src.prewarm()
        #expect(src.device == Self.builtIn)
        src.release(reason: .idle)
        driver.defaultDevice = Self.usb            // changed while nothing was watching
        let enumerations = src.diagnostics.counters.enumerations
        try src.prewarm()
        #expect(src.device == Self.usb)
        #expect(src.diagnostics.counters.enumerations > enumerations)
    }

    /// A prewarm that lands between a release dropping its lock and the listeners actually being
    /// removed re-arms the monitor, and the release must not leave that new graph unwatched.
    @Test func aPrewarmRacingAReleaseKeepsItsRouteMonitor() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        try src.start()
        src.stop()
        driver.onStopMonitoring = { try? src.prewarm() }
        src.release(reason: .idle)
        #expect(src.phase == .prepared, "the racing prewarm rebuilt the graph")
        #expect(driver.monitoring, "a graph that exists must still see device changes")
        src.release(reason: .quit)
        #expect(!driver.monitoring)
    }

    @Test func buffersReachTheSinkAndTheFirstBufferIsTimedPerTurn() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        let received = Samples()
        src.sink = { received.add($0.count) }
        try src.start()
        driver.deliver()
        #expect(received.count > 0)
        let cold = try #require(src.diagnostics.lastFirstBufferMs)
        #expect(cold >= 0)
        #expect(!src.diagnostics.lastStartWasWarm)

        src.stop()
        driver.deliver()                          // paused: the engine delivers nothing
        let afterPause = received.count
        try src.start()
        driver.deliver()
        #expect(received.count > afterPause)
        #expect(src.diagnostics.lastStartWasWarm, "the second turn resumed the kept graph")
        src.stop()
    }

    @Test func aFailedStartLeavesThePreparedGraphUsable() throws {
        let driver = FakeCaptureDriver()
        let src = source(driver)
        driver.failNextStart = .engineStartFailed("HAL busy")
        #expect(throws: AudioCaptureError.self) { try src.start() }
        #expect(src.phase == .prepared)
        try src.start()
        #expect(src.phase == .running)
        src.stop()
    }

    @Test func noDeviceAtAllThrowsAndBuildsNothing() {
        let driver = FakeCaptureDriver(devices: [], defaultDevice: nil)
        let src = source(driver)
        #expect(throws: AudioCaptureError.noInputDevice) { try src.prewarm() }
        #expect(src.phase == .stopped)
        #expect(!driver.monitoring)
    }

    // MARK: AcousticCaptureSource over a kept graph

    /// V4.7 — the wrapper's prewarm used to *start* the inner source for pre-roll, which with a
    /// launch-time prewarm would have lit the mic indicator from launch to quit.
    @Test func wrapperPrewarmKeepsTheMicrophoneClosed() throws {
        let driver = FakeCaptureDriver()
        let inner = source(driver)
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)   // pre-roll 0.5 s
        try src.prewarm()
        #expect(inner.phase == .prepared)
        #expect(!driver.engineRunning, "prewarm opened the microphone")
        #expect(src.prerollFlushed == 0)

        try src.start()
        #expect(inner.phase == .running)
        src.stop()
        #expect(inner.phase == .paused)
        src.release(reason: .mute)
        #expect(inner.phase == .stopped)
        #expect(inner.diagnostics.lastRelease == .mute)
    }

    /// V4.23 — a press that opened the microphone itself gets no pad: nothing was running before it.
    @Test func aPressThatOpensTheMicrophoneIsNotPadded() throws {
        let driver = FakeCaptureDriver()
        let src = AcousticCaptureSource(wrapping: source(driver),
                                        profile: RobustnessProfile(noiseSuppression: false, prerollSeconds: 0.5))
        let received = Samples()
        src.sink = { received.add($0.count) }
        try src.prewarm()
        driver.deliver()              // engine not running: nothing can be captured
        try src.start()
        #expect(src.prerollFlushed == 0)
        #expect(received.count == 0)
        src.release(reason: .quit)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            try #require(Date() < deadline, "timed out waiting for condition")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
