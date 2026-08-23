import AVFoundation
import CoreAudio
import Foundation
import Shared

/// `CoreAudioCaptureSource` twin whose input unit runs Apple's voice-processing I/O
/// (AEC + noise suppression + AGC, `AVAudioInputNode.setVoiceProcessingEnabled`). This is the
/// primary AEC path (see AEC.swift for why). Falls back to plain capture if the device refuses
/// voice processing. Untestable without a mic + TCC permission — exercised manually.
public final class VoiceProcessingCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    /// True once the input unit accepted voice processing.
    private(set) public var voiceProcessingActive = false
    private let engine = AVAudioEngine()
    private var converter: AudioConverter16k?
    private var prewarmed = false
    private(set) public var isRunning = false
    private let lock = NSLock()
    private let policy: InputSelectionPolicy
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
        // Voice processing must be enabled before the device is pinned or a tap installed.
        voiceProcessingActive = AppleVoiceProcessing.isSupported && AppleVoiceProcessing.enable(on: engine)
        if let unit = engine.inputNode.audioUnit, target.id != 0 {
            var id = target.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        }
        device = target
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AudioConverter16k(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: format) { [weak self] buffer, _ in
            guard let self, let converter = self.converter, let sink = self.sink else { return }
            converter.convert(buffer).withUnsafeBufferPointer { sink($0) }
        }
        engine.prepare()
        prewarmed = true
        Log.engine.notice("audio: voice-processing capture on \(target.name) (vp=\(self.voiceProcessingActive))")
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
}
