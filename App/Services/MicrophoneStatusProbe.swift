import AppKit
import AVFoundation
import Foundation
import Shared

// MARK: - Q10 · Live microphone status

/// Reads the microphone authorization *now*. Never cached on our side: every call goes to
/// `AVCaptureDevice.authorizationStatus(for: .audio)`.
public protocol MicrophoneAuthorizationReading: AnyObject {
    func currentAuthorization() -> AVAuthorizationStatus
}

/// Opens the microphone for a moment and reports whether real (non-zero) audio arrived. This is the
/// ground truth the status API is not: a grant made while the process runs can leave the status API
/// answering `.denied` while a fresh capture already works (the "Later" path).
public protocol MicrophoneCaptureTrying: AnyObject {
    func tryCapture(completion: @escaping @Sendable (Bool) -> Void)
}

public final class LiveMicrophoneAuthorizationReader: MicrophoneAuthorizationReading {
    public init() {}
    public func currentAuthorization() -> AVAuthorizationStatus {
        if ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1" { return .authorized }
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

/// A half-second `AVAudioEngine` capture on a background queue. A TCC-denied process receives
/// zero-filled buffers, so "any non-zero sample" separates granted from denied without a prompt
/// (it is only ever run when the status API already reads `.denied`, never `.notDetermined`).
/// Untested in CI: needs a real microphone and a real TCC row.
public final class LiveMicrophoneCaptureTrial: MicrophoneCaptureTrying {
    public static let window: TimeInterval = 0.5

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var value: Bool { lock.withLock { raised } }
    }

    public init() {}

    public func tryCapture(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { completion(false); return }
            let heard = Flag()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData else { return }
                let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
                if samples.contains(where: { $0 != 0 }) { heard.raise() }
            }
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                completion(false)
                return
            }
            let deadline = Date().addingTimeInterval(Self.window)
            while !heard.value && Date() < deadline { usleep(20_000) }
            engine.stop()
            input.removeTap(onBus: 0)
            completion(heard.value)
        }
    }
}

/// The one place the app asks "may the microphone open?". Re-reads the status API on every call
/// (on activation, before any refusal, on a TCC change, and on the watcher's tick) instead of
/// trusting a launch-time answer, and lets a successful fresh capture override a stale `.denied`.
///
/// Rules:
/// * status API `.authorized` → authorized.
/// * status API `.denied` but a fresh capture succeeded since → authorized (stale-denied, fresh-granted).
/// * otherwise the status API's answer, synchronously — a fresh denial refuses on the very call that
///   sees it, never a tick later.
/// A `.denied` read on activation / TCC change / refusal kicks one background capture trial
/// (spaced by `trialSpacing`, never stacked); its result feeds the next probe and the trial observers
/// (`RelaunchAdvisor` only advises a relaunch when that trial actually fails).
public final class MicrophoneStatusProbe: @unchecked Sendable {
    public enum Reason: String, Sendable {
        case tick, becameActive, beforeRefusal, tccChanged, captureTrial
        /// Reasons that may start a capture trial when the status API reads `.denied`.
        var mayTrial: Bool { self == .becameActive || self == .beforeRefusal || self == .tccChanged }
    }

    public static let trialSpacing: TimeInterval = 5
    /// Distributed notifications that announce a TCC database change. Not documented by Apple;
    /// observing a name that never fires costs nothing, and activation covers the common path.
    public static let tccChangeNotifications = ["com.apple.TCC.access.changed", "com.apple.tcc.access.changed"]

    public static let shared = MicrophoneStatusProbe()

    private let reader: MicrophoneAuthorizationReading
    private let trial: MicrophoneCaptureTrying
    public var clock: () -> Date

    private let lock = NSLock()
    private var lastEffective: AVAuthorizationStatus?
    private var verifiedByCapture = false
    private var trialInFlight = false
    private var lastTrialAt: Date?
    private var trialObservers: [(Bool) -> Void] = []
    private var distributedObservers: [NSObjectProtocol] = []

    /// Fired when the effective status changes (and on the first read).
    public var onChange: ((AVAuthorizationStatus, Reason) -> Void)?

    public init(reader: MicrophoneAuthorizationReading = LiveMicrophoneAuthorizationReader(),
                trial: MicrophoneCaptureTrying = LiveMicrophoneCaptureTrial(),
                clock: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.trial = trial
        self.clock = clock
    }

    deinit {
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Called with each capture trial's result, on whatever thread the trial finished on.
    public func addTrialObserver(_ observer: @escaping (Bool) -> Void) {
        lock.withLock { trialObservers.append(observer) }
    }

    /// Re-read now. Never returns a cached status-API answer.
    @discardableResult
    public func probe(_ reason: Reason) -> AVAuthorizationStatus {
        let raw = reader.currentAuthorization()
        let (effective, changed): (AVAuthorizationStatus, Bool) = lock.withLock {
            let effective: AVAuthorizationStatus = (raw == .authorized || (raw == .denied && verifiedByCapture))
                ? .authorized : raw
            let changed = effective != lastEffective
            lastEffective = effective
            return (effective, changed)
        }
        if changed {
            Log.app.notice("microphone: status \(Self.label(effective)) (api=\(Self.label(raw)), via \(reason.rawValue))")
            onChange?(effective, reason)
        }
        if reason.mayTrial, raw == .denied, effective != .authorized { startTrial(reason) }
        return effective
    }

    /// The capture layer saw a real capture succeed or fail; same weight as a trial.
    public func noteCaptureOutcome(succeeded: Bool) { record(trialSucceeded: succeeded, reason: .captureTrial) }

    /// A TCC change: drop any capture verdict (the grant may have moved either way) and re-check.
    public func noteTCCChanged() {
        lock.withLock { verifiedByCapture = false; lastTrialAt = nil }
        probe(.tccChanged)
    }

    /// Observe the TCC-change notifications. Idempotent.
    public func startObserving() {
        guard lock.withLock({ distributedObservers.isEmpty }) else { return }
        let center = DistributedNotificationCenter.default()
        let tokens = Self.tccChangeNotifications.map { name in
            center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.noteTCCChanged()
            }
        }
        lock.withLock { distributedObservers = tokens }
    }

    // MARK: Internals

    private func startTrial(_ reason: Reason) {
        let now = clock()
        let go: Bool = lock.withLock {
            guard !trialInFlight else { return false }
            if reason != .tccChanged, let last = lastTrialAt, now.timeIntervalSince(last) < Self.trialSpacing { return false }
            trialInFlight = true
            lastTrialAt = now
            return true
        }
        guard go else { return }
        Log.app.notice("microphone: status API reads denied (\(reason.rawValue)) — trying a fresh capture")
        trial.tryCapture { [weak self] ok in self?.record(trialSucceeded: ok, reason: .captureTrial) }
    }

    private func record(trialSucceeded ok: Bool, reason: Reason) {
        let observers: [(Bool) -> Void] = lock.withLock {
            trialInFlight = false
            verifiedByCapture = ok
            return trialObservers
        }
        Log.app.notice("microphone: fresh capture \(ok ? "succeeded — the grant is in force" : "failed")")
        for observer in observers { observer(ok) }
        probe(reason)
    }

    public static func permissionStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func label(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}

/// Test double for the status API.
public final class MockMicrophoneAuthorizationReader: MicrophoneAuthorizationReading {
    public var status: AVAuthorizationStatus
    public private(set) var reads = 0
    public init(_ status: AVAuthorizationStatus) { self.status = status }
    public func currentAuthorization() -> AVAuthorizationStatus { reads += 1; return status }
}

/// Test double for a capture trial: completes synchronously with `result`, or holds the completion
/// when `result` is nil until `finish(_:)`.
public final class MockMicrophoneCaptureTrial: MicrophoneCaptureTrying {
    public var result: Bool?
    public private(set) var attempts = 0
    private var pending: (@Sendable (Bool) -> Void)?
    public init(result: Bool?) { self.result = result }
    public func tryCapture(completion: @escaping @Sendable (Bool) -> Void) {
        attempts += 1
        if let result { completion(result) } else { pending = completion }
    }
    public func finish(_ ok: Bool) { let p = pending; pending = nil; p?(ok) }
}
