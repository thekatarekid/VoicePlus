import AVFoundation
import CoreAudio
import Foundation
import Shared

/// `CoreAudioCaptureSource` twin whose input unit runs Apple's voice-processing I/O
/// (AEC + noise suppression + AGC, `AVAudioInputNode.setVoiceProcessingEnabled`). This is the
/// primary AEC path (see AEC.swift for why).
///
/// Two hard-won safety rails, both measured on real hardware while chasing the 1.6.3 "capture
/// started, zero blocks" report:
///   * the voice-processing tap hands back a **5-channel discrete** layout, which `AVAudioConverter`
///     downmixes to digital silence — `AudioConverter16k` now takes channel 0 explicitly;
///   * if voice processing accepts the mode but then delivers nothing, the graph is rebuilt as a
///     plain tap after `fallbackTimeout`. Producing silence forever is never an option.
/// Untestable without a mic + TCC permission — exercised by `VoicePlusApp --mic-selftest`.
public final class VoiceProcessingCaptureSource: AudioCaptureSource, CaptureGraphDescribing, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    /// True once the input unit accepted voice processing.
    private(set) public var voiceProcessingActive = false
    /// True once voice processing was turned off because it delivered no audio.
    private(set) public var didFallBackToPlainTap = false
    /// Seconds to wait for the first buffer after `start()` before giving up on voice processing
    /// and rebuilding as a plain tap. 0 disables the fallback.
    public var fallbackTimeout: TimeInterval = 1.5
    /// Snapshot of the resolved graph, mirroring `CoreAudioCaptureSource.diagnostics`.
    public var diagnostics: AudioCaptureDiagnostics { diagLock.withLock { diag } }
    private let engine = AVAudioEngine()
    private var converter: AudioConverter16k?
    private let converterLock = NSLock()
    private let diagLock = NSLock()
    private var diag = AudioCaptureDiagnostics()
    private var prewarmed = false
    private(set) public var isRunning = false
    private let lock = NSLock()
    private let policy: InputSelectionPolicy
    private let tapFrames: AVAudioFrameCount = 2048
    private var sawBuffer = false
    private var watchdog: DispatchWorkItem?
    /// Sticky once the fallback has fired: a device that refused to deliver under voice processing
    /// does not get a second chance inside the same session.
    private var forcePlainTap = false

    public init(device: AudioDeviceInfo? = nil, policy: InputSelectionPolicy = InputSelectionPolicy()) {
        self.device = device
        self.policy = policy
    }

    public func prewarm() throws {
        lock.lock(); defer { lock.unlock() }
        guard !prewarmed else { return }
        let target = device ?? policy.choose(from: AudioDeviceEnumerator.inputDevices(), systemDefault: AudioDeviceEnumerator.defaultInputDevice())
        guard let target else { throw AudioCaptureError.noInputDevice }
        diagLock.withLock {
            diag = AudioCaptureDiagnostics()
            diag.deviceName = target.name
            diag.deviceID = target.id
        }
        // Voice processing must be enabled before the device is pinned or a tap installed.
        let wantVP = !forcePlainTap && AppleVoiceProcessing.isSupported
        voiceProcessingActive = wantVP && AppleVoiceProcessing.enable(on: engine)
        if forcePlainTap { AppleVoiceProcessing.enable(on: engine, enabled: false) }
        diagLock.withLock { diag.voiceProcessing = self.voiceProcessingActive }
        try pin(target: target)
        device = target
        installTap()
        engine.prepare()
        prewarmed = true
        let summary = diagnostics.summary
        Log.engine.notice("audio: voice-processing capture — \(summary)")
    }

    public func start() throws {
        try prewarm()
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        do { try engine.start() } catch {
            lock.unlock()
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
        isRunning = true
        let arm = voiceProcessingActive && fallbackTimeout > 0 && !sawBuffer
        lock.unlock()
        if arm { armFallbackWatchdog() }
    }

    public func stop() {
        cancelFallbackWatchdog()
        lock.lock(); defer { lock.unlock() }
        guard prewarmed else { return }
        engine.inputNode.removeTap(onBus: 0)
        if isRunning { engine.stop() }
        isRunning = false
        prewarmed = false
    }

    public func switchDevice(to newDevice: AudioDeviceInfo?) throws {
        let old = device
        let wasRunning = isRunning
        stop()
        device = newDevice
        try prewarm()
        if wasRunning { try start() }
        onDeviceChanged?(old, device)
    }

    // MARK: internals

    private func pin(target: AudioDeviceInfo) throws {
        guard let unit = engine.inputNode.audioUnit, target.id != 0 else {
            diagLock.withLock { diag.pinSkipReason = "no input audio unit" }
            return
        }
        // Same rule as `CoreAudioCaptureSource`: pinning the device the node already uses only
        // desynchronises the AUHAL hardware scope from AVAudioEngine's cached client format.
        if AudioDeviceEnumerator.defaultInputDeviceID() == target.id {
            diagLock.withLock { diag.pinSkipReason = "already the system default input" }
            return
        }
        var id = target.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        diagLock.withLock { diag.pinStatus = status }
        guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        diagLock.withLock { diag.pinApplied = true }
    }

    private func installTap() {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let cached = input.outputFormat(forBus: 0)
        let format = Self.tapFormat(hardware: hardware, cached: cached)
        diagLock.withLock {
            diag.tapRate = format.sampleRate
            diag.tapChannels = Int(format.channelCount)
            diag.nodeInputRate = hardware.sampleRate
            diag.nodeInputChannels = Int(hardware.channelCount)
            diag.nodeOutputRate = cached.sampleRate
            diag.nodeOutputChannels = Int(cached.channelCount)
        }
        converterLock.withLock { converter = AudioConverter16k(inputFormat: format) }
        input.installTap(onBus: 0, bufferSize: tapFrames, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.noteBufferArrived()
            guard let sink = self.sink else { return }
            let samples = self.converter(matching: buffer.format).convert(buffer)
            guard !samples.isEmpty else { return }
            samples.withUnsafeBufferPointer { sink($0) }
        }
    }

    /// V5 C1 — the format the tap is installed with: the hardware's when it reports one (44.1 or
    /// 48 kHz, 1–5 channels under voice processing), else the node's cached output format.
    static func tapFormat(hardware: AVAudioFormat, cached: AVAudioFormat) -> AVAudioFormat {
        (hardware.sampleRate > 0 && hardware.channelCount > 0) ? hardware : cached
    }

    /// The converter for a delivered buffer's format; rebuilt when the device renegotiates
    /// (e.g. 48 → 44.1 kHz on a route change). Internal for tests.
    func converter(matching format: AVAudioFormat) -> AudioConverter16k {
        converterLock.lock(); defer { converterLock.unlock() }
        if let c = converter, c.inputFormat.sampleRate == format.sampleRate, c.inputFormat.channelCount == format.channelCount {
            return c
        }
        let c = AudioConverter16k(inputFormat: format)
        converter = c
        return c
    }

    private func noteBufferArrived() {
        lock.lock()
        let first = !sawBuffer
        sawBuffer = true
        let item = first ? watchdog : nil
        if first { watchdog = nil }
        lock.unlock()
        item?.cancel()
    }

    private func armFallbackWatchdog() {
        let window = fallbackTimeout
        let item = DispatchWorkItem { [weak self] in self?.fallBackToPlainTapIfSilent(after: window) }
        lock.lock(); watchdog?.cancel(); watchdog = item; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window, execute: item)
    }

    private func cancelFallbackWatchdog() {
        lock.lock(); let item = watchdog; watchdog = nil; lock.unlock()
        item?.cancel()
    }

    /// Voice processing accepted the mode and then produced nothing: rebuild the graph without it
    /// rather than metering silence for the rest of the session.
    private func fallBackToPlainTapIfSilent(after window: TimeInterval) {
        lock.lock()
        let silent = isRunning && !sawBuffer && !forcePlainTap
        if silent { forcePlainTap = true }
        watchdog = nil
        lock.unlock()
        guard silent else { return }
        Log.engine.error("audio: Apple voice processing delivered no audio in \(String(format: "%.1f", window))s; rebuilding as a plain tap")
        stop()
        do {
            try start()
            didFallBackToPlainTap = true
            Log.engine.notice("audio: plain-tap fallback active (voice processing disabled)")
        } catch {
            Log.engine.error("audio: plain-tap fallback failed: \(error)")
        }
    }
}
