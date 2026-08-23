import AVFoundation
import CoreAudio
import Foundation
import Shared
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// System-audio capture. Design ported from Muesli (Muesli-HQ/muesli, MIT License): a CoreAudio
// process tap as the primary source, a heartbeat watchdog that restarts a silent tap, and a
// ScreenCaptureKit audio-only stream as the fallback. Re-implemented here against our
// `AudioCaptureSource` contract; no Muesli source text is reproduced verbatim.

/// Heartbeat contract for sources the watchdog supervises.
public protocol HeartbeatSource: AudioCaptureSource {
    /// Wall-clock of the last delivered buffer (nil before the first one).
    var lastDelivery: Date? { get }
}

/// Decides, from heartbeats alone, whether a capture source needs a restart or a fallback.
/// Pure and clock-injected so the policy is testable without hardware.
/// Policy (Muesli): silence longer than `staleAfter` → restart; more than `maxRestarts`
/// consecutive restarts without a heartbeat → fall back; any heartbeat resets the restart count.
public struct CaptureWatchdog: Sendable, Equatable {
    public enum Action: Equatable, Sendable { case none, restart, fallback }
    public var staleAfter: TimeInterval
    public var maxRestarts: Int
    /// Grace period after a (re)start before silence counts as stale.
    public var startupGrace: TimeInterval
    public private(set) var restarts = 0
    public private(set) var startedAt: Date?
    public private(set) var fellBack = false

    public init(staleAfter: TimeInterval = 5, maxRestarts: Int = 2, startupGrace: TimeInterval = 3) {
        self.staleAfter = staleAfter; self.maxRestarts = maxRestarts; self.startupGrace = startupGrace
    }

    public mutating func started(at now: Date) { startedAt = now }

    public mutating func evaluate(lastDelivery: Date?, now: Date) -> Action {
        guard !fellBack, let startedAt else { return .none }
        if let last = lastDelivery, last >= startedAt {
            restarts = 0
            return now.timeIntervalSince(last) > staleAfter ? escalate(now) : .none
        }
        // Nothing since (re)start: allow the grace period, then treat as stale.
        return now.timeIntervalSince(startedAt) > max(startupGrace, staleAfter) ? escalate(now) : .none
    }

    private mutating func escalate(_ now: Date) -> Action {
        if restarts >= maxRestarts { fellBack = true; return .fallback }
        restarts += 1
        startedAt = now
        return .restart
    }
}

/// Orchestrates primary (process tap) + fallback (ScreenCaptureKit) behind one `AudioCaptureSource`.
/// Deliveries from whichever source is active go to `sink`; the watchdog ticks on `queue`.
public final class SystemAudioRecorder: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)? { didSet { wire(primary); wire(fallback) } }
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public var device: AudioDeviceInfo? { active?.device }
    public enum Stage: Equatable, Sendable { case idle, primary, fallback, failed }
    private(set) public var stage: Stage = .idle
    public var onStageChanged: ((Stage) -> Void)?

    private let primary: (any HeartbeatSource)?
    private let fallback: (any HeartbeatSource)?
    private var active: (any HeartbeatSource)?
    private var watchdog: CaptureWatchdog
    private let clock: @Sendable () -> Date
    private let tickInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "voiceplus.meeting.watchdog")
    private let lock = NSLock()

    /// Default wiring: process tap when the OS has it, SCK otherwise/fallback.
    public static func live() -> SystemAudioRecorder {
        var primary: (any HeartbeatSource)?
        if #available(macOS 14.2, *) { primary = ProcessTapSystemAudioSource() }
        return SystemAudioRecorder(primary: primary, fallback: ScreenCaptureSystemAudioSource())
    }

    public init(primary: (any HeartbeatSource)?, fallback: (any HeartbeatSource)?,
                watchdog: CaptureWatchdog = CaptureWatchdog(), tickInterval: TimeInterval = 1,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.primary = primary; self.fallback = fallback; self.watchdog = watchdog
        self.tickInterval = tickInterval; self.clock = clock
    }

    private func wire(_ s: (any HeartbeatSource)?) { s?.sink = sink }

    public func prewarm() throws {
        if let primary { try primary.prewarm() } else if let fallback { try fallback.prewarm() }
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard stage == .idle || stage == .failed else { return }
        if let primary, (try? primary.start()) != nil {
            active = primary; set(.primary)
        } else if let fallback {
            try fallback.start(); active = fallback; set(.fallback)
        } else {
            set(.failed); throw AudioCaptureError.noInputDevice
        }
        watchdog.started(at: clock())
        guard tickInterval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        active?.stop(); active = nil
        if stage != .failed { set(.idle) }
    }

    public func switchDevice(to device: AudioDeviceInfo?) throws { try active?.switchDevice(to: device) }

    /// One watchdog evaluation. Public so tests drive it with a fake clock instead of the timer.
    public func tick() {
        lock.lock(); defer { lock.unlock() }
        guard let current = active else { return }
        switch watchdog.evaluate(lastDelivery: current.lastDelivery, now: clock()) {
        case .none: break
        case .restart:
            Log.engine.warning("meeting: system audio silent, restarting \(stage)")
            current.stop()
            if (try? current.start()) == nil { failOver(from: current) }
        case .fallback:
            Log.engine.error("meeting: system audio tap unrecoverable, falling back")
            failOver(from: current)
        }
    }

    private func failOver(from current: any HeartbeatSource) {
        current.stop()
        guard stage == .primary, let fallback, (try? fallback.start()) != nil else {
            active = nil; set(.failed); timer?.cancel(); timer = nil; return
        }
        active = fallback
        var wd = CaptureWatchdog(staleAfter: watchdog.staleAfter, maxRestarts: watchdog.maxRestarts, startupGrace: watchdog.startupGrace)
        wd.started(at: clock()); watchdog = wd
        set(.fallback)
        onDeviceChanged?(current.device, fallback.device)
    }

    private func set(_ s: Stage) { stage = s; onStageChanged?(s) }
}

// MARK: - CoreAudio process tap (macOS 14.2+)

/// Global system-output tap via `CATapDescription` + a private aggregate device with the tap as
/// a sub-tap, read through an IOProc and resampled to 16 kHz mono. Needs the
/// `NSAudioCaptureUsageDescription` TCC grant. Untestable without hardware.
@available(macOS 14.2, *)
public final class ProcessTapSystemAudioSource: HeartbeatSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public let device: AudioDeviceInfo? = AudioDeviceInfo(id: 0, uid: "system-tap", name: "System audio (process tap)", transport: .virtual, sampleRate: 16_000, inputChannels: 1)
    private(set) public var lastDelivery: Date?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AudioConverter16k?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "voiceplus.meeting.tap")
    private let lock = NSLock()
    private(set) public var isRunning = false
    /// Processes excluded from the tap (e.g. our own PID, so we never record ourselves).
    public var excludedProcessObjectIDs: [AudioObjectID] = []

    public init() {}

    public func prewarm() throws {}

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessObjectIDs)
        desc.uuid = UUID()
        desc.muteBehavior = CATapMuteBehavior.unmuted
        desc.name = "VoicePlus meeting tap"
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw AudioCaptureError.engineStartFailed("process tap: \(status)") }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else { teardown(); throw AudioCaptureError.noInputDevice }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoicePlus meeting aggregate",
            kAudioAggregateDeviceUIDKey: "in.adityakatare.voiceplus.meeting.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { teardown(); throw AudioCaptureError.engineStartFailed("aggregate: \(status)") }
        aggregateID = agg

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { teardown(); throw AudioCaptureError.engineStartFailed("tap format: \(status)") }
        format = fmt
        converter = AudioConverter16k(inputFormat: fmt)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInput, _, _, _ in
            self?.deliver(inInput)
        }
        guard status == noErr, let procID else { teardown(); throw AudioCaptureError.engineStartFailed("ioproc: \(status)") }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { teardown(); throw AudioCaptureError.engineStartFailed("start: \(status)") }
        isRunning = true
        Log.engine.notice("meeting: process tap started (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch)")
    }

    public func stop() { lock.lock(); defer { lock.unlock() }; teardown() }
    public func switchDevice(to device: AudioDeviceInfo?) throws {}

    private func deliver(_ list: UnsafePointer<AudioBufferList>) {
        guard let format, let converter, let sink else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil), buffer.frameLength > 0 else { return }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        lastDelivery = Date()
        samples.withUnsafeBufferPointer { sink($0) }
    }

    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        isRunning = false
    }

    static func defaultOutputUID() -> String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - ScreenCaptureKit fallback (audio only)

/// `SCStream` with only an `.audio` output attached: no screen frames are ever delivered or
/// stored. Requires Screen Recording TCC. Untestable without a display session.
public final class ScreenCaptureSystemAudioSource: NSObject, HeartbeatSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public let device: AudioDeviceInfo? = AudioDeviceInfo(id: 0, uid: "system-sck", name: "System audio (ScreenCaptureKit)", transport: .virtual, sampleRate: 16_000, inputChannels: 1)
    private(set) public var lastDelivery: Date?
    private(set) public var isRunning = false
    #if canImport(ScreenCaptureKit)
    private var stream: SCStream?
    #endif
    private var converter: AudioConverter16k?
    private let queue = DispatchQueue(label: "voiceplus.meeting.sck")

    public override init() { super.init() }
    public func prewarm() throws {}

    public func start() throws {
        #if canImport(ScreenCaptureKit)
        guard !isRunning else { return }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<SCStream, Error> = .failure(AudioCaptureError.noInputDevice)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw AudioCaptureError.noInputDevice }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // Keep the (mandatory) video leg as cheap as possible; no screen output is attached.
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: filter, configuration: config, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                result = .success(s)
            } catch { result = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 10) == .success else { throw AudioCaptureError.engineStartFailed("sck: timeout") }
        switch result {
        case .success(let s): stream = s; isRunning = true; Log.engine.notice("meeting: SCK audio fallback started")
        case .failure(let e): throw AudioCaptureError.engineStartFailed("sck: \(e.localizedDescription)")
        }
        #else
        throw AudioCaptureError.engineStartFailed("ScreenCaptureKit unavailable")
        #endif
    }

    public func stop() {
        #if canImport(ScreenCaptureKit)
        guard let s = stream else { return }
        stream = nil; isRunning = false
        Task { try? await s.stopCapture() }
        #endif
    }

    public func switchDevice(to device: AudioDeviceInfo?) throws {}
}

#if canImport(ScreenCaptureKit)
extension ScreenCaptureSystemAudioSource: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let sink, let fd = sampleBuffer.formatDescription else { return }
        var asbd = fd.audioStreamBasicDescription ?? AudioStreamBasicDescription()
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        if converter == nil || converter?.inputFormat != format { converter = AudioConverter16k(inputFormat: format) }
        let abl = AudioBufferList.allocate(maximumBuffers: 8)
        defer { free(abl.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 8), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer, deallocator: nil) else { return }
        withExtendedLifetime(block) {}
        let samples = converter?.convert(pcm) ?? []
        guard !samples.isEmpty else { return }
        lastDelivery = Date()
        samples.withUnsafeBufferPointer { sink($0) }
    }
}
#endif
