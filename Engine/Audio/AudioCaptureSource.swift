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
}

/// Real capture: `AVAudioEngine` input node with the HAL device pinned explicitly through the
/// underlying AudioUnit (`kAudioOutputUnitProperty_CurrentDevice`), so we never depend on the
/// system default silently changing under us. Clean-room; FluidVoice is a design reference only.
/// Untestable without a microphone + TCC permission — exercised manually.
public final class CoreAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    private let engine = AVAudioEngine()
    private var converter: AudioConverter16k?
    private var prewarmed = false
    private(set) public var isRunning = false
    private let lock = NSLock()
    private let monitor = AudioDeviceMonitor()
    private let policy: InputSelectionPolicy
    /// Tap size ~50 ms at device rate: low latency, still cheap.
    private let tapFrames: AVAudioFrameCount = 2048

    public init(device: AudioDeviceInfo? = nil, policy: InputSelectionPolicy = InputSelectionPolicy()) {
        self.device = device
        self.policy = policy
    }

    public func prewarm() throws {
        lock.lock(); defer { lock.unlock() }
        guard !prewarmed else { return }
        let target = device ?? policy.choose(from: AudioDeviceEnumerator.inputDevices(), systemDefault: AudioDeviceEnumerator.defaultInputDevice())
        guard let target else { throw AudioCaptureError.noInputDevice }
        try pin(deviceID: target.id)
        device = target
        installTap()
        engine.prepare()
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
        try pin(deviceID: target.id)
        device = target
        converter = nil
        installTap()
        engine.prepare()
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

    private func pin(deviceID: AudioObjectID) throws {
        guard deviceID != 0, let unit = engine.inputNode.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AudioConverter16k(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: format) { [weak self] buffer, _ in
            guard let self, let converter = self.converter, let sink = self.sink else { return }
            let samples = converter.convert(buffer)
            samples.withUnsafeBufferPointer { sink($0) }
        }
    }
}
