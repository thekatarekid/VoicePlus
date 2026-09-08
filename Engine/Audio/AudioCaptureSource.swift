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
    /// Allocate the graph / open the device without delivering audio (hotkey-down). Idempotent.
    func prewarm() throws
    func start() throws
    func stop()
    /// Re-point capture at another device without losing already-captured samples.
    func switchDevice(to device: AudioDeviceInfo?) throws
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
    /// Another owner already holds the capture graph and outranks this caller. Reported instead of
    /// the silent no-op that used to hand a second caller a stream it had not configured.
    case busy(owner: String)
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
    /// True when the hardware sample rate had to be pushed onto the AUHAL client scope after a pin.
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

    public init() {}

    public var formatsAgree: Bool {
        nodeInputRate > 0 && nodeInputChannels > 0 && abs(nodeInputRate - nodeOutputRate) < 1
    }

    public var summary: String {
        let pin = pinApplied ? "applied(status=\(pinStatus),clientPush=\(clientFormatPushed))" : "skipped(\(pinSkipReason ?? "-"))"
        return "device=\(deviceName)#\(deviceID) pin=\(pin)"
            + " node.inputFormat=\(rate(nodeInputRate))Hz/\(nodeInputChannels)ch"
            + " node.outputFormat=\(rate(nodeOutputRate))Hz/\(nodeOutputChannels)ch"
            + " hal.hw=\(rate(halHardwareRate))Hz/\(halHardwareChannels)ch"
            + " hal.client=\(rate(halClientRate))Hz/\(halClientChannels)ch"
            + " tap=\(rate(tapRate))Hz/\(tapChannels)ch vp=\(voiceProcessing)"
    }

    private func rate(_ d: Double) -> String { String(format: "%.0f", d) }
}

/// Real capture: `AVAudioEngine` input node, with the HAL device pinned through the underlying
/// AudioUnit (`kAudioOutputUnitProperty_CurrentDevice`) *only when it is not already the system
/// default* — see `pin(deviceID:)` for why pinning the default is what silenced 1.6.3.
/// Clean-room; FluidVoice is a design reference only.
/// Untestable without a microphone + TCC permission — exercised by `VoicePlusApp --mic-selftest`.
public final class CoreAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    /// Snapshot of the resolved capture graph. Valid after `prewarm()`.
    public var diagnostics: AudioCaptureDiagnostics { diagLock.withLock { diag } }
    private let engine = AVAudioEngine()
    private var converter: AudioConverter16k?
    private let converterLock = NSLock()
    private let diagLock = NSLock()
    private var diag = AudioCaptureDiagnostics()
    private var prewarmed = false
    private(set) public var isRunning = false
    private let lock = NSLock()
    private let monitor = AudioDeviceMonitor()
    private let policy: InputSelectionPolicy
    /// Tap size ~50 ms at device rate: low latency, still cheap.
    private let tapFrames: AVAudioFrameCount = 2048
    /// AUHAL bus 1 is the input (microphone) element.
    private static let inputBus: AudioUnitElement = 1

    public init(device: AudioDeviceInfo? = nil, policy: InputSelectionPolicy = InputSelectionPolicy()) {
        self.device = device
        self.policy = policy
    }

    public func prewarm() throws {
        lock.lock(); defer { lock.unlock() }
        guard !prewarmed else { return }
        let decision = policy.decide(from: AudioDeviceEnumerator.inputDevices(), systemDefault: AudioDeviceEnumerator.defaultInputDevice())
        let target = device ?? decision.device
        guard let target else { throw AudioCaptureError.noInputDevice }
        if device == nil, let avoided = decision.avoidedNarrowbandBluetooth {
            Log.engine.notice("""
                audio: \(avoided.name) is the system input but its mic runs at \
                \(Int(avoided.sampleRate)) Hz over Bluetooth (telephony quality), so dictation is \
                using \(target.name) instead. Pick it explicitly in Settings › General if you want it.
                """)
        }
        try buildGraph(for: target)
        prewarmed = true
        monitor.onDefaultInputChanged = { [weak self] newDefault in self?.handleRouteChange(newDefault: newDefault) }
        monitor.onDeviceListChanged = { [weak self] list in
            guard let self, let current = self.device, !list.contains(where: { $0.uid == current.uid }) else { return }
            self.handleRouteChange(newDefault: AudioDeviceEnumerator.defaultInputDevice())
        }
        monitor.start()
    }

    public func start() throws {
        try prewarm()
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        do { try engine.start() } catch { throw AudioCaptureError.engineStartFailed(error.localizedDescription) }
        isRunning = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard prewarmed else { return }
        engine.inputNode.removeTap(onBus: 0)
        if isRunning { engine.stop() }
        monitor.stop()
        isRunning = false
        prewarmed = false
    }

    public func switchDevice(to newDevice: AudioDeviceInfo?) throws {
        lock.lock(); defer { lock.unlock() }
        let old = device
        let wasRunning = isRunning
        if prewarmed {
            engine.inputNode.removeTap(onBus: 0)
            if isRunning { engine.stop() }
        }
        guard let target = newDevice ?? policy.choose(from: AudioDeviceEnumerator.inputDevices(), systemDefault: AudioDeviceEnumerator.defaultInputDevice()) else {
            isRunning = false
            throw AudioCaptureError.noInputDevice
        }
        converterLock.withLock { converter = nil }
        // Same treatment as prewarm: pin only when needed, re-sync the client format, verify.
        // Skipping this on a route change is how a working graph turned silent after AirPods.
        do { try buildGraph(for: target) } catch { isRunning = false; throw error }
        if wasRunning {
            do { try engine.start() } catch { isRunning = false; throw AudioCaptureError.engineStartFailed(error.localizedDescription) }
        }
        Log.engine.notice("audio: switched input \(old?.name ?? "none") -> \(target.name)")
        onDeviceChanged?(old, target)
    }

    // MARK: internals

    private func handleRouteChange(newDefault: AudioDeviceInfo?) {
        let all = AudioDeviceEnumerator.inputDevices()
        let current = device
        let stillPresent = current.map { c in all.contains { $0.uid == c.uid } } ?? false
        let chosen = policy.choose(from: all, systemDefault: newDefault, current: stillPresent ? current : nil)
        guard chosen?.uid != current?.uid else { return }
        do { try switchDevice(to: chosen) } catch { Log.engine.error("audio: route change failed: \(error)") }
    }

    /// Pin (if needed) → record formats → verify they agree → install tap → prepare.
    /// Shared by `prewarm()` and `switchDevice(to:)` so a route change cannot regress separately.
    private func buildGraph(for target: AudioDeviceInfo) throws {
        diagLock.withLock {
            diag = AudioCaptureDiagnostics()
            diag.deviceName = target.name
            diag.deviceID = target.id
        }
        try pin(deviceID: target.id)
        device = target
        recordFormats()
        try verifyFormats()
        installTap()
        engine.prepare()
        recordFormats()
        let summary = diagnostics.summary
        Log.engine.notice("audio: capture graph ready — \(summary)")
    }

    /// Points the AUHAL at `deviceID`, unless it is already the system default input.
    ///
    /// Pinning the default is a no-op that costs everything: `AudioUnitSetProperty` refreshes only
    /// the AUHAL *hardware* scope (built-in mics run at 48 kHz) while `AVAudioEngine` keeps the
    /// client format it cached at 44.1 kHz. `engine.start()` then returns success, `isRunning` is
    /// true, and the tap never fires — capture "starts" and delivers exactly zero buffers, which
    /// is precisely the 1.6.3 report. When a pin is genuinely needed (an explicitly chosen
    /// non-default input) the new hardware rate is pushed onto the client scope so the two agree.
    private func pin(deviceID: AudioObjectID) throws {
        guard deviceID != 0, let unit = engine.inputNode.audioUnit else {
            diagLock.withLock { diag.pinSkipReason = "no input audio unit" }
            return
        }
        if AudioDeviceEnumerator.defaultInputDeviceID() == deviceID {
            diagLock.withLock { diag.pinSkipReason = "already the system default input" }
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        diagLock.withLock { diag.pinStatus = status }
        guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        let pushed = syncClientFormat(unit: unit)
        diagLock.withLock { diag.pinApplied = true; diag.clientFormatPushed = pushed }
    }

    /// Copies the AUHAL hardware sample rate onto the client scope so `AVAudioEngine`'s node
    /// format follows the pinned device. Returns true when a change was written.
    private func syncClientFormat(unit: AudioUnit) -> Bool {
        guard let hardware = Self.streamFormat(unit, scope: kAudioUnitScope_Input), hardware.mSampleRate > 0,
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

    private func recordFormats() {
        let input = engine.inputNode
        let nodeIn = input.inputFormat(forBus: 0)
        let nodeOut = input.outputFormat(forBus: 0)
        let hardware = input.audioUnit.flatMap { Self.streamFormat($0, scope: kAudioUnitScope_Input) }
        let client = input.audioUnit.flatMap { Self.streamFormat($0, scope: kAudioUnitScope_Output) }
        diagLock.withLock {
            diag.nodeInputRate = nodeIn.sampleRate
            diag.nodeInputChannels = Int(nodeIn.channelCount)
            diag.nodeOutputRate = nodeOut.sampleRate
            diag.nodeOutputChannels = Int(nodeOut.channelCount)
            diag.halHardwareRate = hardware?.mSampleRate ?? 0
            diag.halHardwareChannels = Int(hardware?.mChannelsPerFrame ?? 0)
            diag.halClientRate = client?.mSampleRate ?? 0
            diag.halClientChannels = Int(client?.mChannelsPerFrame ?? 0)
        }
    }

    /// The guard the 1.6.3 build did not have: refuse to report a working capture graph when the
    /// hardware and client formats disagree, because that is exactly the state in which the tap is
    /// installed, the engine starts, and not one buffer is ever delivered.
    private func verifyFormats() throws {
        let d = diagnostics
        guard d.formatsAgree else {
            Log.engine.error("audio: refusing to start a graph whose tap can never fire — \(d.summary)")
            throw AudioCaptureError.formatMismatch(hardware: d.nodeInputRate, client: d.nodeOutputRate)
        }
    }

    private func installTap() {
        let input = engine.inputNode
        // `outputFormat(forBus:)` is AVAudioEngine's cached client format and can lag the hardware;
        // `inputFormat(forBus:)` follows the device. A tap installed with a format the hardware is
        // not producing never fires, so prefer the hardware side and fall back only if it is empty.
        let hardware = input.inputFormat(forBus: 0)
        let cached = input.outputFormat(forBus: 0)
        let format = (hardware.sampleRate > 0 && hardware.channelCount > 0) ? hardware : cached
        diagLock.withLock { diag.tapRate = format.sampleRate; diag.tapChannels = Int(format.channelCount) }
        converterLock.withLock { converter = AudioConverter16k(inputFormat: format) }
        input.installTap(onBus: 0, bufferSize: tapFrames, format: format) { [weak self] buffer, _ in
            guard let self, let sink = self.sink else { return }
            let samples = self.converter(matching: buffer.format).convert(buffer)
            guard !samples.isEmpty else { return }
            samples.withUnsafeBufferPointer { sink($0) }
        }
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

    static func streamFormat(_ unit: AudioUnit, scope: AudioUnitScope) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, inputBus, &asbd, &size) == noErr else { return nil }
        return asbd
    }
}
