import CoreAudio
import Foundation
import Shared

/// A capture-capable audio device as seen by CoreAudio HAL.
public struct AudioDeviceInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable {
        case builtIn, bluetooth, usb, aggregate, virtual, displayPort, other
    }
    public var id: UInt32          // AudioObjectID; 0 for fixtures
    public var uid: String         // stable across reboots; used for preferences
    public var name: String
    public var transport: Transport
    public var sampleRate: Double
    public var inputChannels: Int

    public init(id: UInt32, uid: String, name: String, transport: Transport, sampleRate: Double, inputChannels: Int) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
        self.sampleRate = sampleRate; self.inputChannels = inputChannels
    }

    public static let fixture = AudioDeviceInfo(id: 0, uid: "fixture", name: "Fixture replayer", transport: .virtual, sampleRate: 16_000, inputChannels: 1)
}

/// CoreAudio HAL device enumeration. Pure queries; safe to call from any thread.
public enum AudioDeviceEnumerator {
    public static func inputDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { info(for: $0) }.filter { $0.inputChannels > 0 }
    }

    public static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    public static func defaultInputDevice() -> AudioDeviceInfo? {
        defaultInputDeviceID().flatMap { info(for: $0) }
    }

    public static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid: String = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name: String = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        let channels = inputChannelCount(id)
        let rate: Double = scalarProperty(id, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeInput) ?? 0
        let transportRaw: UInt32 = scalarProperty(id, kAudioDevicePropertyTransportType) ?? 0
        return AudioDeviceInfo(id: id, uid: uid, name: name, transport: transport(transportRaw), sampleRate: rate, inputChannels: channels)
    }

    static func transport(_ raw: UInt32) -> AudioDeviceInfo.Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeThunderbolt: return .displayPort
        default: return .other
        }
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func scalarProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.pointee
    }
}

/// Watches the HAL default-input device and the device list; fires on AirPods connect, clamshell,
/// 3.5 mm plug, etc. Callbacks arrive on `queue`.
public final class AudioDeviceMonitor: @unchecked Sendable {
    public var onDefaultInputChanged: ((AudioDeviceInfo?) -> Void)?
    public var onDeviceListChanged: (([AudioDeviceInfo]) -> Void)?
    private let queue = DispatchQueue(label: "in.adityakatare.voiceplus.audio.devices")
    private var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var block: AudioObjectPropertyListenerBlock?
    private(set) public var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            for i in 0..<Int(count) {
                switch addresses[i].mSelector {
                case kAudioHardwarePropertyDefaultInputDevice:
                    self.onDefaultInputChanged?(AudioDeviceEnumerator.defaultInputDevice())
                case kAudioHardwarePropertyDevices:
                    self.onDeviceListChanged?(AudioDeviceEnumerator.inputDevices())
                default: break
                }
            }
        }
        self.block = block
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &defaultAddress, queue, block)
        AudioObjectAddPropertyListenerBlock(system, &listAddress, queue, block)
        isRunning = true
    }

    public func stop() {
        guard isRunning, let block else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, queue, block)
        AudioObjectRemovePropertyListenerBlock(system, &listAddress, queue, block)
        self.block = nil
        isRunning = false
    }

    deinit { stop() }
}
