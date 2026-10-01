import AVFoundation
import CoreAudio
import Foundation
import Shared

/// Where 16 kHz mono samples come from. Implementations push converted samples into `sink`
/// from whatever thread they like; `AudioPipeline` owns the ring buffer behind the sink.
public protocol AudioCaptureSource: AnyObject, Sendable {
    var device: AudioDeviceInfo? { get }
    /// Called with 16 kHz mono Float samples. Must be set before `start()`.
    var sink: ((UnsafeBufferPointer<Float>) -> Void)? { get set }
    /// Called after a route change has been applied (old, new).
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)? { get set }
    /// Build the graph for the chosen device **without opening the microphone** (V4.7: the app calls
    /// this at launch, so the mic indicator must stay off). Idempotent.
    func prewarm() throws
    func start() throws
    /// End the turn. A source that can keep its graph between turns (`CoreAudioCaptureSource`) pauses
    /// here with the microphone closed; `release(reason:)` is the full teardown.
    func stop()
    /// Re-point capture at another device without losing already-captured samples.
    func switchDevice(to device: AudioDeviceInfo?) throws
    /// Full teardown of whatever the source keeps between turns (V4.7): hard mute, quit, a device
    /// change or a long idle. The default is `stop()`, for sources that keep nothing.
    func release(reason: CaptureReleaseReason)
}

public extension AudioCaptureSource {
    func release(reason: CaptureReleaseReason) { stop() }
}

/// Why a kept capture graph was torn down completely (V4.7). Everything else only pauses it.
public enum CaptureReleaseReason: String, Sendable, Equatable, CaseIterable {
    case mute, quit, deviceChange, idle
    /// The engine was swapped (a model landed): nobody will start this graph again.
    case replaced
    /// The graph opened and delivered nothing but silence (`CaptureSilenceWatchdog`). A kept graph
    /// is the *reason* that can persist for a whole session — a warm resume re-runs nothing — so a
    /// silent capture is released rather than paused, and the next press builds a cold one.
    case silent
}

/// A capture source that can describe the graph it actually resolved to. Implemented by the two
/// HAL sources (`CoreAudioCaptureSource`, `VoiceProcessingCaptureSource`); wrappers forward it.
///
/// R1.4 added this for one reason: the recorder's manifest used to name the *profile's* intent
/// (`aec=appleVoiceProcessing`) while the graph line in the same manifest said `vp=false`. Twenty
/// real-room recordings were filed with that contradiction. A source that can be asked what it
/// resolved to lets the manifest state the truth instead of the intent, whichever source is wrapped.
public protocol CaptureGraphDescribing: AnyObject {
    var diagnostics: AudioCaptureDiagnostics { get }
}

public enum AudioCaptureError: Error, Equatable {
    case noInputDevice
    case engineStartFailed(String)
    case deviceSelectionFailed(Int32)
    /// The AUHAL hardware format and `AVAudioEngine`'s cached client format disagree. This is the
    /// 1.6.3 "capture started, zero blocks" failure: `engine.start()` still succeeds, `isRunning`
    /// is true, and the input tap silently never fires. Reported as a start failure so the app can
    /// never again claim a working microphone in this state.
    case formatMismatch(hardware: Double, client: Double)
    /// Capture started and stayed silent: not one audio block arrived inside the watchdog window.
    case noAudio(seconds: TimeInterval)
    /// The microphone is not ours to open: TCC has no grant for this code identity, or the user
    /// revoked it. Distinct from `.noInputDevice` because the two need opposite instructions —
    /// "Choose microphone" (A01) versus "Open Microphone settings" (P01) — and reporting a denied
    /// grant as "No microphone found" is what sent users looking at their hardware.
    case notPermitted(status: String)
    /// Another owner already holds the capture graph and outranks this caller. Reported instead of
    /// the silent no-op that used to hand a second caller a stream it had not configured.
    case busy(owner: String)
    /// V4.10 — the device did not open inside its start budget (`PipelineAudioSource.budget(for:)`).
    /// Names the device: "start timed out" never told anyone *which* microphone was slow.
    case startTimedOut(device: String, seconds: TimeInterval)
}

extension AudioCaptureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noInputDevice:
            return "no input device"
        case .engineStartFailed(let why):
            return "engine start failed: \(why)"
        case .deviceSelectionFailed(let status):
            return "could not select the input device (OSStatus \(status))"
        case .formatMismatch(let hardware, let client):
            return "audio format mismatch: hardware \(Int(hardware)) Hz vs client \(Int(client)) Hz — the input tap would never fire"
        case .noAudio(let seconds):
            return "capture started but no audio block arrived within \(String(format: "%.1f", seconds))s"
        case .busy(let owner):
            return "the microphone is already in use by \(owner)"
        case .startTimedOut(let device, let seconds):
            return "\(device) did not start within \(String(format: "%.0f", seconds))s"
        case .notPermitted(let status):
            return "microphone access is \(status) for this copy of VoicePlus"
        }
    }
}

/// V4.10 / A2 — the copy for the two start failures the design names, by recovery-catalogue id
/// (`Fixtures/design/design_copy.json` → `errors`). The id mapping itself is the catalogue's
/// (`EngineMessage.classify`: a timeout is one more way of failing to open the device → A03); this is
/// the sentence that also names the device, for whichever surface has room for it. The pill keeps
/// its own "Nothing was typed" subtitle underneath.
public enum CaptureRecoveryCopy {
    /// A03 · Audio — "Input source cannot be selected or opened".
    public static let startFailedID = "A03"
    public static let startFailedHeadline = "Couldn\u{2019}t start this microphone"
    /// A04 · Audio — "Sample-rate or device-format mismatch".
    public static let formatMismatchID = "A04"
    public static let formatMismatchHeadline = "This microphone needs reconnecting"

    /// The A03 sentence for a start that ran out of budget, naming the device that was slow.
    public static func startTimedOut(device: String, seconds: TimeInterval) -> String {
        "\(startFailedHeadline) \u{2014} \(device) didn\u{2019}t open within \(Int(seconds.rounded())) s"
    }
}

extension AudioCaptureError: LocalizedError {
    /// Only the cases with a design sentence of their own. Everything else returns nil, so every
    /// other case keeps its `description` wording wherever the error's own text is read (since S9
    /// the UI shows the recovery catalogue's headline; this text goes to the log).
    public var errorDescription: String? {
        switch self {
        case .startTimedOut(let device, let seconds):
            return CaptureRecoveryCopy.startTimedOut(device: device, seconds: seconds)
        case .formatMismatch:
            return CaptureRecoveryCopy.formatMismatchHeadline
        default:
            return nil
        }
    }
}

/// What the capture graph actually resolved to. Filled in during `prewarm()`; printed by
/// `--mic-selftest` and logged once per graph build.
///
/// `nodeInputRate` vs `nodeOutputRate` is the whole 1.6.3 bug on one line: when they disagree the
/// tap is installed against a format the hardware is not producing and never fires.
public struct AudioCaptureDiagnostics: Sendable, Equatable {
    public var deviceName = "-"
    public var deviceID: UInt32 = 0
    public var pinApplied = false
    public var pinSkipReason: String?
    public var pinStatus: Int32 = 0
    /// True when the hardware sample rate had to be pushed onto the AUHAL client scope. Since V4.9
    /// the push is attempted on every graph build, including the system-default path.
    public var clientFormatPushed = false
    /// `AVAudioInputNode.inputFormat(forBus: 0)` — follows the hardware.
    public var nodeInputRate: Double = 0
    public var nodeInputChannels = 0
    /// `AVAudioInputNode.outputFormat(forBus: 0)` — AVAudioEngine's cached client format.
    public var nodeOutputRate: Double = 0
    public var nodeOutputChannels = 0
    /// AUHAL `kAudioUnitProperty_StreamFormat`, input scope bus 1 (hardware side).
    public var halHardwareRate: Double = 0
    public var halHardwareChannels = 0
    /// AUHAL `kAudioUnitProperty_StreamFormat`, output scope bus 1 (client side).
    public var halClientRate: Double = 0
    public var halClientChannels = 0
    /// Format the tap was actually installed with.
    public var tapRate: Double = 0
    public var tapChannels = 0
    public var voiceProcessing = false
    /// V4.9 — how many times this graph build threw the `AVAudioEngine` away because the formats
    /// still disagreed after the client-format sync (0 or 1; a second disagreement throws).
    public var engineRebuilds = 0
    /// V4.7 — where the graph is between turns, and why it was last fully torn down.
    public var phase: CapturePhase = .stopped
    public var lastRelease: CaptureReleaseReason?
    /// V4.7 — `start()` → first tap buffer for the most recent turn, and whether it resumed a kept
    /// graph (warm) or built/started one (cold). nil until a buffer has arrived.
    public var lastFirstBufferMs: Double?
    public var lastStartWasWarm = false
    /// Running totals across graph builds (never reset by a rebuild), so a test can prove a warm
    /// resume makes no HAL calls.
    public var counters = CaptureCounters()

    public init() {}

    public var formatsAgree: Bool {
        nodeInputRate > 0 && nodeInputChannels > 0 && abs(nodeInputRate - nodeOutputRate) < 1
    }

    public var summary: String {
        let pin = pinApplied ? "applied(status=\(pinStatus),clientPush=\(clientFormatPushed))" : "skipped(\(pinSkipReason ?? "-"),clientPush=\(clientFormatPushed))"
        return "device=\(deviceName)#\(deviceID) pin=\(pin)"
            + " node.inputFormat=\(rate(nodeInputRate))Hz/\(nodeInputChannels)ch"
            + " node.outputFormat=\(rate(nodeOutputRate))Hz/\(nodeOutputChannels)ch"
            + " hal.hw=\(rate(halHardwareRate))Hz/\(halHardwareChannels)ch"
            + " hal.client=\(rate(halClientRate))Hz/\(halClientChannels)ch"
            + " tap=\(rate(tapRate))Hz/\(tapChannels)ch vp=\(voiceProcessing)"
            + (engineRebuilds > 0 ? " engineRebuilds=\(engineRebuilds)" : "")
    }

    private func rate(_ d: Double) -> String { String(format: "%.0f", d) }
}

/// V4.7 — what the capture graph has cost, counted at the driver edge.
public struct CaptureCounters: Sendable, Equatable {
    /// Device-list and default-device queries.
    public var enumerations = 0
    /// `kAudioOutputUnitProperty_CurrentDevice` writes.
    public var pinWrites = 0
    /// Client-scope stream-format pushes attempted.
    public var formatSyncs = 0
    /// Format snapshots read off the node and the AUHAL.
    public var formatReads = 0
    public var graphBuilds = 0
    public var engineRecreations = 0
    public var coldStarts = 0
    public var warmResumes = 0
    public var pauses = 0
    public var fullStops = 0

    public init() {}

    /// Every HAL property call the source makes. A warm `paused → running` adds zero.
    public var halCalls: Int { enumerations + pinWrites + formatSyncs + formatReads }
}

// MARK: - V4.9 graph rebuild policy (pure)

/// A1 / V4.9 — what a graph build does when the node's formats still disagree after the
/// client-format sync: recreate the `AVAudioEngine` once, then give up with `.formatMismatch`.
public enum GraphRebuildPolicy {
    public enum Decision: Equatable, Sendable { case accept, rebuild, fail }

    public static let maxRebuilds = 1

    public static func decide(formatsAgree: Bool, rebuildsSoFar: Int, maxRebuilds: Int = maxRebuilds) -> Decision {
        if formatsAgree { return .accept }
        return rebuildsSoFar < maxRebuilds ? .rebuild : .fail
    }
}

// MARK: - V4.7 capture lifecycle (pure)

/// Where the capture graph is. Between turns it is `paused`: tap installed, AUHAL pinned, engine
/// paused, microphone closed — so the next `start()` is one `engine.start()` and nothing else.
public enum CapturePhase: String, Sendable, Equatable {
    /// Nothing built (launch, or after a full release).
    case stopped
    /// Graph built and tap installed, engine never started (`prewarm()` at launch).
    case prepared
    /// Engine running: the microphone is open.
    case running
    /// Between turns: engine paused with the tap left installed; the microphone is closed.
    case paused
}

/// A4 — the capture state machine. Pure: it decides the steps, `CoreAudioCaptureSource` performs
/// them against the driver. `prepared → running → paused → running`, and `paused → stopped` on
/// mute, quit, device change or idle.
public struct CaptureLifecycle: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case prewarm
        case start
        case stop
        case release(CaptureReleaseReason)
    }

    public enum Step: Equatable, Sendable {
        /// Enumerate, pin, sync the client format, verify, install the tap, prepare. HAL work.
        case buildGraph
        /// `engine.start()` on a graph that has never run (cold).
        case startEngine
        /// `engine.start()` from paused: no enumeration, no pin, no format work (warm).
        case resumeEngine
        case pauseEngine
        /// Remove the tap and `engine.stop()`.
        case teardown
        case stopRouteMonitor
        case scheduleIdleRelease
        case cancelIdleRelease
    }

    public private(set) var phase: CapturePhase

    public init(phase: CapturePhase = .stopped) { self.phase = phase }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Step] {
        switch (phase, event) {
        case (.stopped, .prewarm):
            phase = .prepared
            return [.buildGraph]
        case (.stopped, .start):
            phase = .running
            return [.buildGraph, .startEngine]
        case (.prepared, .start):
            phase = .running
            return [.startEngine]
        case (.paused, .start):
            phase = .running
            return [.cancelIdleRelease, .resumeEngine]
        case (.running, .stop):
            phase = .paused
            return [.pauseEngine, .scheduleIdleRelease]
        case (.running, .release(.idle)):
            return []                         // a live turn is never idle
        case (.stopped, .release):
            return []
        case (_, .release(let reason)):
            phase = .stopped
            // A device change rebuilds for the new device at once; the route monitor that noticed
            // the change keeps running. Every other release leaves nothing behind.
            return reason == .deviceChange ? [.cancelIdleRelease, .teardown]
                                           : [.cancelIdleRelease, .teardown, .stopRouteMonitor]
        default:
            // prewarm on a built graph, start while running, stop while not running: nothing to do.
            return []
        }
    }

    /// A step threw: the phase becomes what the graph really is.
    public mutating func stepFailed(_ step: Step) {
        switch step {
        case .buildGraph: phase = .stopped
        case .startEngine, .resumeEngine: phase = .prepared
        default: break
        }
    }
}

// MARK: - The HAL / AVAudioEngine edge

/// The formats a graph build reads back to verify itself.
public struct CaptureGraphFormats: Sendable, Equatable {
    public var nodeInputRate: Double = 0
    public var nodeInputChannels = 0
    public var nodeOutputRate: Double = 0
    public var nodeOutputChannels = 0
    public var halHardwareRate: Double = 0
    public var halHardwareChannels = 0
    public var halClientRate: Double = 0
    public var halClientChannels = 0
    public init() {}
}

/// Everything `CoreAudioCaptureSource` asks of the HAL and `AVAudioEngine`, so the lifecycle,
/// the rebuild policy and the HAL-call accounting can be exercised without a microphone.
/// Live: `AVAudioEngineCaptureDriver`. Not thread-safe; the source serialises every call.
public protocol CaptureGraphDriver: AnyObject {
    func inputDevices() -> [AudioDeviceInfo]
    func defaultInputDevice() -> AudioDeviceInfo?
    func defaultInputDeviceID() -> AudioObjectID?
    /// Whether the input node has an AUHAL to pin at all.
    var hasInputUnit: Bool { get }
    /// `kAudioOutputUnitProperty_CurrentDevice` on the input AUHAL.
    func setCurrentDevice(_ id: AudioObjectID) -> OSStatus
    /// Copies the AUHAL hardware sample rate onto its client scope. True when a change was written.
    func syncClientFormat() -> Bool
    func readFormats() -> CaptureGraphFormats
    /// Installs the input tap with the hardware-side format and returns the format used.
    func installTap(bufferSize: AVAudioFrameCount, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioFormat
    func removeTap()
    func prepare()
    func start() throws
    func pause()
    func stop()
    /// Throws the `AVAudioEngine` away and makes a fresh one (new AUHAL, fresh cached client format).
    func recreateEngine()
    func startMonitoring(onDefaultInputChanged: @escaping (AudioDeviceInfo?) -> Void,
                         onDeviceListChanged: @escaping ([AudioDeviceInfo]) -> Void)
    func stopMonitoring()
    /// `AVAudioEngineConfigurationChangeNotification`: the engine has rebuilt its own graph because
    /// the input hardware format changed under it (another app pushed the device to a different
    /// rate, a wake, a same-device route change). **The engine invalidates installed taps when this
    /// happens** and stops itself, which the HAL listeners in `AudioDeviceMonitor` cannot see: they
    /// watch the *default device* and the *device list*, and neither changed. Defaulted to a no-op
    /// so fake drivers need not implement it.
    func observeConfigurationChanges(_ onChange: @escaping () -> Void)
    func stopObservingConfigurationChanges()
}

public extension CaptureGraphDriver {
    func observeConfigurationChanges(_ onChange: @escaping () -> Void) {}
    func stopObservingConfigurationChanges() {}
}

// MARK: - CoreAudioCaptureSource

/// Real capture: `AVAudioEngine` input node, with the HAL device pinned through the underlying
/// AudioUnit (`kAudioOutputUnitProperty_CurrentDevice`) *only when it is not already the system
/// default* — see `pin(deviceID:)` for why pinning the default is what silenced 1.6.3.
///
/// V4.7: the graph is kept between turns. `stop()` pauses the engine with the tap installed and the
/// AUHAL pinned (microphone closed); the next `start()` resumes it without enumerating or pinning.
/// `release(reason:)` — hard mute, quit, device change, or `idleReleaseAfter` of idle — is the only
/// full stop. The route monitor runs whenever a graph exists, so a device change between turns is
/// seen and rebuilt for before the next press.
/// Clean-room; FluidVoice is a design reference only.
/// The live driver needs a microphone + TCC permission — exercised by `VoicePlusApp --mic-selftest`;
/// everything else runs against a fake driver in `EngineTests`.
public final class CoreAudioCaptureSource: AudioCaptureSource, CaptureGraphDescribing, NarrowbandInputReporting, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    /// Snapshot of the resolved capture graph. Valid after `prewarm()`.
    public var diagnostics: AudioCaptureDiagnostics { diagLock.withLock { diag } }
    public var phase: CapturePhase { lock.withLock { lifecycle.phase } }
    public var isRunning: Bool { phase == .running }
    /// V5 C3 — see `NarrowbandInputReporting`.
    public var avoidedNarrowbandInput: AudioDeviceInfo? { diagLock.withLock { avoidedNarrowband } }
    /// How long a paused graph is kept before it is fully released. 0 or less keeps it forever.
    public let idleReleaseAfter: TimeInterval
    public static let defaultIdleRelease: TimeInterval = 600

    private let driver: any CaptureGraphDriver
    /// The device the caller pinned at init (`--mic-selftest --device`), if any. Otherwise the
    /// policy decides afresh on every build from `stopped`.
    private let requestedDevice: AudioDeviceInfo?
    private var lifecycle = CaptureLifecycle()
    private var converter: AudioConverter16k?
    private let converterLock = NSLock()
    private let diagLock = NSLock()
    private var diag = AudioCaptureDiagnostics()
    private let lock = NSLock()
    private let policy: InputSelectionPolicy
    /// V5 C3 — the narrowband headset the policy avoided on its last decision (`diagLock`).
    private var avoidedNarrowband: AudioDeviceInfo?
    private var monitoring = false
    private var idleWork: DispatchWorkItem?
    private let idleQueue = DispatchQueue(label: "in.adityakatare.voiceplus.audio.idle", qos: .utility)
    private let turnLock = NSLock()
    private var turnStartedAt: UInt64?
    private var turnWarm = false
    /// Tap size ~50 ms at device rate: low latency, still cheap.
    private let tapFrames: AVAudioFrameCount = 2048

    public init(device: AudioDeviceInfo? = nil, policy: InputSelectionPolicy = InputSelectionPolicy(),
                driver: (any CaptureGraphDriver)? = nil, idleReleaseAfter: TimeInterval = CoreAudioCaptureSource.defaultIdleRelease) {
        self.device = device
        self.requestedDevice = device
        self.policy = policy
        self.driver = driver ?? AVAudioEngineCaptureDriver()
        self.idleReleaseAfter = idleReleaseAfter
    }

    deinit {
        idleWork?.cancel()
        if lifecycle.phase != .stopped {
            driver.removeTap()
            driver.stop()
        }
        if monitoring { driver.stopMonitoring() }
    }

    public func prewarm() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try perform(.prewarm)
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try perform(.start)
    }

    /// Ends the turn: the engine pauses, the tap and the pin stay (V4.7). The microphone is closed.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        _ = try? perform(.stop)
    }

    public func release(reason: CaptureReleaseReason) {
        lock.lock()
        let stopMonitor = (try? perform(.release(reason))) ?? false
        lock.unlock()
        // Outside the lock: removing a HAL listener can wait for an in-flight route callback, and
        // that callback is itself waiting for `lock`.
        guard stopMonitor else { return }
        driver.stopMonitoring()
        driver.stopObservingConfigurationChanges()
        // A prewarm that slipped in between the two re-armed the monitor just stopped: arm it again,
        // or a device change would go unseen by a graph that exists.
        lock.withLock {
            guard monitoring else { return }
            monitoring = false
            ensureMonitoring()
        }
    }

    public func switchDevice(to newDevice: AudioDeviceInfo?) throws {
        lock.lock(); defer { lock.unlock() }
        let old = device
        let wasRunning = lifecycle.phase == .running
        _ = try perform(.release(.deviceChange))
        noteEnumeration()
        guard let target = newDevice ?? policy.choose(from: driver.inputDevices(), systemDefault: driver.defaultInputDevice()) else {
            throw AudioCaptureError.noInputDevice
        }
        // Same treatment as prewarm: pin only when needed, re-sync the client format, verify.
        // Skipping this on a route change is how a working graph turned silent after AirPods.
        _ = try perform(.prewarm, target: target)
        if wasRunning { _ = try perform(.start) }
        Log.engine.notice("audio: switched input \(old?.name ?? "none") -> \(target.name)")
        onDeviceChanged?(old, target)
    }

    /// Rebuilds the graph for whatever device the policy chooses **now**, whether or not the device
    /// changed. `switchDevice(to:)` answers "a different microphone"; this answers "the same
    /// microphone, but the graph in front of it is no longer wired to it" — which is what an
    /// `AVAudioEngine` configuration change leaves behind, tap included.
    public func rebuildGraph() throws {
        let current = lock.withLock { device }
        noteEnumeration()
        let all = driver.inputDevices()
        let stillPresent = current.map { c in all.contains { $0.uid == c.uid } } ?? false
        let chosen = policy.choose(from: all, systemDefault: driver.defaultInputDevice(),
                                   current: stillPresent ? current : nil)
        try switchDevice(to: chosen)
    }

    /// The engine rebuilt itself. A graph that is merely `paused` is the dangerous case: the next
    /// `start()` is one `engine.start()` on a tap that is no longer installed, so capture "opens",
    /// the microphone indicator lights, and not one buffer ever arrives — for every press until the
    /// idle release ten minutes later. Rebuild now, while nobody is holding the key.
    private func handleConfigurationChange() {
        let phase = lock.withLock { lifecycle.phase }
        guard phase != .stopped else { return }
        Log.engine.notice("audio: the audio engine reconfigured itself while \(phase.rawValue); rebuilding the capture graph so the tap is attached again")
        do { try rebuildGraph() } catch {
            Log.engine.error("audio: rebuilding after an engine configuration change failed: \(error)")
        }
    }

    // MARK: lifecycle steps (called with `lock` held)

    /// Runs the lifecycle's steps for `event`. Returns true when the caller must stop the route
    /// monitor after releasing `lock`.
    private func perform(_ event: CaptureLifecycle.Event, target: AudioDeviceInfo? = nil) throws -> Bool {
        let steps = lifecycle.handle(event)
        var stopMonitor = false
        for step in steps {
            do {
                switch step {
                case .buildGraph:
                    try buildGraph(for: target ?? resolveTarget())
                    ensureMonitoring()
                case .startEngine:
                    try driver.start()
                    count { $0.coldStarts += 1 }
                    markTurnStart(warm: false)
                case .resumeEngine:
                    try driver.start()
                    count { $0.warmResumes += 1 }
                    markTurnStart(warm: true)
                case .pauseEngine:
                    driver.pause()
                    count { $0.pauses += 1 }
                case .teardown:
                    driver.removeTap()
                    driver.stop()
                    converterLock.withLock { converter = nil }
                    count { $0.fullStops += 1 }
                    if case .release(let reason) = event {
                        diagLock.withLock { diag.lastRelease = reason }
                        Log.engine.info("audio: capture graph released (\(reason.rawValue))")
                    }
                case .stopRouteMonitor:
                    stopMonitor = monitoring
                    monitoring = false
                case .scheduleIdleRelease:
                    scheduleIdleRelease()
                case .cancelIdleRelease:
                    idleWork?.cancel()
                    idleWork = nil
                }
            } catch {
                lifecycle.stepFailed(step)
                diagLock.withLock { diag.phase = lifecycle.phase }
                throw error
            }
        }
        diagLock.withLock { diag.phase = lifecycle.phase }
        return stopMonitor
    }

    /// Re-enumerates on every build from `stopped` (V4.9), so a device that changed while nothing
    /// was watching (after a full release) is picked up by the next prewarm rather than the device
    /// the previous graph happened to resolve to.
    private func resolveTarget() throws -> AudioDeviceInfo {
        noteEnumeration()
        let decision = policy.decide(from: driver.inputDevices(), systemDefault: driver.defaultInputDevice())
        guard let target = requestedDevice ?? decision.device else { throw AudioCaptureError.noInputDevice }
        diagLock.withLock { avoidedNarrowband = requestedDevice == nil ? decision.avoidedNarrowbandBluetooth : nil }
        if requestedDevice == nil, let avoided = decision.avoidedNarrowbandBluetooth {
            Log.engine.notice("""
                audio: \(avoided.name) is the system input but its mic runs at \
                \(Int(avoided.sampleRate)) Hz over Bluetooth (telephony quality), so dictation is \
                using \(target.name) instead. Pick it explicitly in Settings › General if you want it.
                """)
        }
        return target
    }

    private func ensureMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        driver.observeConfigurationChanges { [weak self] in self?.handleConfigurationChange() }
        driver.startMonitoring(
            onDefaultInputChanged: { [weak self] newDefault in self?.handleRouteChange(newDefault: newDefault) },
            onDeviceListChanged: { [weak self] list in
                guard let self, let current = self.device, !list.contains(where: { $0.uid == current.uid }) else { return }
                self.handleRouteChange(newDefault: self.driver.defaultInputDevice())
            })
    }

    private func scheduleIdleRelease() {
        idleWork?.cancel()
        idleWork = nil
        guard idleReleaseAfter > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.release(reason: .idle) }
        idleWork = work
        idleQueue.asyncAfter(deadline: .now() + idleReleaseAfter, execute: work)
    }

    // MARK: internals

    private func handleRouteChange(newDefault: AudioDeviceInfo?) {
        let all = driver.inputDevices()
        let current = device
        let stillPresent = current.map { c in all.contains { $0.uid == c.uid } } ?? false
        let decision = policy.decide(from: all, systemDefault: newDefault, current: stillPresent ? current : nil)
        let chosen = decision.device
        diagLock.withLock { avoidedNarrowband = decision.avoidedNarrowbandBluetooth }
        guard chosen?.uid != current?.uid else { return }
        do { try switchDevice(to: chosen) } catch { Log.engine.error("audio: route change failed: \(error)") }
    }

    /// Pin (if needed) → sync the client format (always) → record formats → verify, recreating the
    /// engine once if they still disagree → install tap → prepare.
    /// Shared by `prewarm()` and `switchDevice(to:)` so a route change cannot regress separately.
    private func buildGraph(for target: AudioDeviceInfo) throws {
        beginDiagnostics(for: target, rebuilds: 0)
        var rebuilds = 0
        while true {
            try pin(deviceID: target.id)
            // V4.9: unconditionally, including the "already the system default" path. The 44.1 k /
            // 48 k mismatch reached users on exactly the path that used to skip this.
            syncClientFormat()
            device = target
            recordFormats()
            let d = diagnostics
            switch GraphRebuildPolicy.decide(formatsAgree: d.formatsAgree, rebuildsSoFar: rebuilds) {
            case .accept:
                installTap()
                driver.prepare()
                recordFormats()
                count { $0.graphBuilds += 1 }
                let summary = diagnostics.summary
                Log.engine.notice("audio: capture graph ready — \(summary)")
                return
            case .rebuild:
                rebuilds += 1
                Log.engine.notice("audio: formats still disagree after the client-format sync; recreating the audio engine once — \(d.summary)")
                // Tear the tap down with the engine it belongs to. The route monitor is HAL-level,
                // not engine-level, and keeps running.
                driver.removeTap()
                driver.stop()
                driver.recreateEngine()
                count { $0.engineRecreations += 1 }
                beginDiagnostics(for: target, rebuilds: rebuilds)
            case .fail:
                // The guard the 1.6.3 build did not have: refuse to report a working capture graph
                // when the hardware and client formats disagree, because that is exactly the state in
                // which the tap is installed, the engine starts, and not one buffer is delivered.
                Log.engine.error("audio: refusing to start a graph whose tap can never fire — \(d.summary)")
                throw AudioCaptureError.formatMismatch(hardware: d.nodeInputRate, client: d.nodeOutputRate)
            }
        }
    }

    /// Fresh per-build fields; the running counters and the release history survive.
    private func beginDiagnostics(for target: AudioDeviceInfo, rebuilds: Int) {
        diagLock.withLock {
            var fresh = AudioCaptureDiagnostics()
            fresh.counters = diag.counters
            fresh.lastRelease = diag.lastRelease
            fresh.lastFirstBufferMs = diag.lastFirstBufferMs
            fresh.lastStartWasWarm = diag.lastStartWasWarm
            fresh.phase = diag.phase
            fresh.deviceName = target.name
            fresh.deviceID = target.id
            fresh.engineRebuilds = rebuilds
            diag = fresh
        }
    }

    /// Points the AUHAL at `deviceID`, unless it is already the system default input.
    ///
    /// Pinning the default is a no-op that costs everything: `AudioUnitSetProperty` refreshes only
    /// the AUHAL *hardware* scope (built-in mics run at 48 kHz) while `AVAudioEngine` keeps the
    /// client format it cached at 44.1 kHz. `engine.start()` then returns success, `isRunning` is
    /// true, and the tap never fires — capture "starts" and delivers exactly zero buffers, which
    /// is precisely the 1.6.3 report. The client-format sync that follows every pin (and, since
    /// V4.9, every skipped pin too) is what makes the two agree.
    private func pin(deviceID: AudioObjectID) throws {
        guard deviceID != 0, driver.hasInputUnit else {
            diagLock.withLock { diag.pinSkipReason = "no input audio unit" }
            return
        }
        noteEnumeration()
        if driver.defaultInputDeviceID() == deviceID {
            diagLock.withLock { diag.pinSkipReason = "already the system default input" }
            return
        }
        count { $0.pinWrites += 1 }
        let status = driver.setCurrentDevice(deviceID)
        diagLock.withLock { diag.pinStatus = status }
        guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        diagLock.withLock { diag.pinApplied = true }
    }

    private func syncClientFormat() {
        guard driver.hasInputUnit else { return }
        count { $0.formatSyncs += 1 }
        let pushed = driver.syncClientFormat()
        diagLock.withLock { diag.clientFormatPushed = pushed }
    }

    private func recordFormats() {
        count { $0.formatReads += 1 }
        let f = driver.readFormats()
        diagLock.withLock {
            diag.nodeInputRate = f.nodeInputRate
            diag.nodeInputChannels = f.nodeInputChannels
            diag.nodeOutputRate = f.nodeOutputRate
            diag.nodeOutputChannels = f.nodeOutputChannels
            diag.halHardwareRate = f.halHardwareRate
            diag.halHardwareChannels = f.halHardwareChannels
            diag.halClientRate = f.halClientRate
            diag.halClientChannels = f.halClientChannels
        }
    }

    private func installTap() {
        let format = driver.installTap(bufferSize: tapFrames) { [weak self] buffer in self?.deliver(buffer) }
        diagLock.withLock { diag.tapRate = format.sampleRate; diag.tapChannels = Int(format.channelCount) }
        converterLock.withLock { converter = AudioConverter16k(inputFormat: format) }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        noteFirstBuffer()
        guard let sink else { return }
        let samples = converter(matching: buffer.format).convert(buffer)
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { sink($0) }
    }

    /// The tap can hand back a different format than the one it was installed with (route change,
    /// voice processing rebuilding the node). Rebuild rather than resample from the wrong format.
    private func converter(matching format: AVAudioFormat) -> AudioConverter16k {
        converterLock.lock(); defer { converterLock.unlock() }
        if let c = converter, c.inputFormat.sampleRate == format.sampleRate, c.inputFormat.channelCount == format.channelCount {
            return c
        }
        let c = AudioConverter16k(inputFormat: format)
        converter = c
        return c
    }

    private func noteEnumeration() { count { $0.enumerations += 1 } }

    private func count(_ update: (inout CaptureCounters) -> Void) {
        diagLock.withLock { update(&diag.counters) }
    }

    private func markTurnStart(warm: Bool) {
        turnLock.withLock {
            turnStartedAt = DispatchTime.now().uptimeNanoseconds
            turnWarm = warm
        }
    }

    /// First tap buffer of a turn: record `start()` → first buffer. On the audio thread, once per turn.
    private func noteFirstBuffer() {
        let pending = turnLock.withLock { () -> (UInt64, Bool)? in
            guard let started = turnStartedAt else { return nil }
            turnStartedAt = nil
            return (started, turnWarm)
        }
        guard let (started, warm) = pending else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        diagLock.withLock {
            diag.lastFirstBufferMs = ms
            diag.lastStartWasWarm = warm
        }
    }
}

// MARK: - Live driver

/// The real HAL + `AVAudioEngine` behind `CoreAudioCaptureSource`. Needs a microphone and TCC.
public final class AVAudioEngineCaptureDriver: CaptureGraphDriver, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var monitor: AudioDeviceMonitor?
    /// AUHAL bus 1 is the input (microphone) element.
    private static let inputBus: AudioUnitElement = 1
    /// The engine-configuration observer and the handler it calls. Kept so the observer can be
    /// re-registered against the *new* engine object after `recreateEngine()` — the notification is
    /// posted by the engine instance, so an observer left on the discarded one hears nothing.
    private var configurationObserver: NSObjectProtocol?
    private var onConfigurationChange: (() -> Void)?

    public init() {}

    deinit { stopObservingConfigurationChanges() }

    public func inputDevices() -> [AudioDeviceInfo] { AudioDeviceEnumerator.inputDevices() }
    public func defaultInputDevice() -> AudioDeviceInfo? { AudioDeviceEnumerator.defaultInputDevice() }
    public func defaultInputDeviceID() -> AudioObjectID? { AudioDeviceEnumerator.defaultInputDeviceID() }

    public var hasInputUnit: Bool { engine.inputNode.audioUnit != nil }

    public func setCurrentDevice(_ id: AudioObjectID) -> OSStatus {
        guard let unit = engine.inputNode.audioUnit else { return kAudioUnitErr_Uninitialized }
        var id = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    /// Copies the AUHAL hardware sample rate onto the client scope so `AVAudioEngine`'s node
    /// format follows the device. Returns true when a change was written.
    public func syncClientFormat() -> Bool {
        guard let unit = engine.inputNode.audioUnit,
              let hardware = Self.streamFormat(unit, scope: kAudioUnitScope_Input), hardware.mSampleRate > 0,
              var client = Self.streamFormat(unit, scope: kAudioUnitScope_Output) else { return false }
        guard client.mSampleRate != hardware.mSampleRate else { return false }
        client.mSampleRate = hardware.mSampleRate
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, Self.inputBus,
                                          &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr {
            Log.engine.error("audio: could not push \(hardware.mSampleRate) Hz onto the client scope (OSStatus \(status))")
        }
        return status == noErr
    }

    public func readFormats() -> CaptureGraphFormats {
        let input = engine.inputNode
        let nodeIn = input.inputFormat(forBus: 0)
        let nodeOut = input.outputFormat(forBus: 0)
        let hardware = input.audioUnit.flatMap { Self.streamFormat($0, scope: kAudioUnitScope_Input) }
        let client = input.audioUnit.flatMap { Self.streamFormat($0, scope: kAudioUnitScope_Output) }
        var f = CaptureGraphFormats()
        f.nodeInputRate = nodeIn.sampleRate
        f.nodeInputChannels = Int(nodeIn.channelCount)
        f.nodeOutputRate = nodeOut.sampleRate
        f.nodeOutputChannels = Int(nodeOut.channelCount)
        f.halHardwareRate = hardware?.mSampleRate ?? 0
        f.halHardwareChannels = Int(hardware?.mChannelsPerFrame ?? 0)
        f.halClientRate = client?.mSampleRate ?? 0
        f.halClientChannels = Int(client?.mChannelsPerFrame ?? 0)
        return f
    }

    public func installTap(bufferSize: AVAudioFrameCount, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioFormat {
        let input = engine.inputNode
        // `outputFormat(forBus:)` is AVAudioEngine's cached client format and can lag the hardware;
        // `inputFormat(forBus:)` follows the device. A tap installed with a format the hardware is
        // not producing never fires, so prefer the hardware side and fall back only if it is empty.
        let hardware = input.inputFormat(forBus: 0)
        let cached = input.outputFormat(forBus: 0)
        let format = (hardware.sampleRate > 0 && hardware.channelCount > 0) ? hardware : cached
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in onBuffer(buffer) }
        return format
    }

    public func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    public func prepare() { engine.prepare() }
    public func start() throws {
        do { try engine.start() } catch { throw AudioCaptureError.engineStartFailed(error.localizedDescription) }
    }
    public func pause() { engine.pause() }
    public func stop() { engine.stop() }

    public func recreateEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        // The notification comes from the engine object, so the observer has to follow it.
        if let handler = onConfigurationChange { observeConfigurationChanges(handler) }
    }

    public func observeConfigurationChanges(_ onChange: @escaping () -> Void) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        onConfigurationChange = onChange
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in onChange() }
    }

    public func stopObservingConfigurationChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        onConfigurationChange = nil
    }

    public func startMonitoring(onDefaultInputChanged: @escaping (AudioDeviceInfo?) -> Void,
                                onDeviceListChanged: @escaping ([AudioDeviceInfo]) -> Void) {
        let monitor = self.monitor ?? AudioDeviceMonitor()
        monitor.onDefaultInputChanged = onDefaultInputChanged
        monitor.onDeviceListChanged = onDeviceListChanged
        monitor.start()
        self.monitor = monitor
    }

    public func stopMonitoring() { monitor?.stop() }

    static func streamFormat(_ unit: AudioUnit, scope: AudioUnitScope) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, inputBus, &asbd, &size) == noErr else { return nil }
        return asbd
    }
}
