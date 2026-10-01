import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import Shared

// V5 M-d — live readers for the new detection signals. They only *observe*: no audio is read, no
// screen is captured, and the browser probe reads one window title / document URL through AXGuard
// (never our own process). Each emits `MeetingSignal`s; `MeetingSignalSources` bundles them for the
// coordinator. Untested against real hardware (needs a real call) → T1.

/// One live source of detection signals.
public protocol MeetingSignalSource: AnyObject {
    func start(emit: @escaping (MeetingSignal) -> Void)
    func stop()
    /// Re-read now (the coordinator's 30 s tick); sources that only push may ignore it.
    func refresh()
}

/// Mic in use by another process. On macOS 14.2+ the HAL's process objects tell us *which* process
/// is capturing input, so our own capture never counts; earlier, the default input device's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is used and our own capture (`ownCaptureActive`)
/// masks it (we cannot then tell a call apart from ourselves — we report false).
public final class MicInUseMonitor: MeetingSignalSource, @unchecked Sendable {
    public var ownCaptureActive: () -> Bool = { false }
    private var emit: ((MeetingSignal) -> Void)?
    private var last: Bool?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "voiceplus.meeting.mic")

    public init() {}

    public func start(emit: @escaping (MeetingSignal) -> Void) {
        self.emit = emit
        // Polled every 5 s: process-object listeners are not reliable across HAL restarts, and a
        // 5 s lag on "a call started" is fine for a prompt.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil; emit = nil; last = nil }

    public func refresh() {
        let now = Self.inputCapturedElsewhere(ownCaptureActive: ownCaptureActive())
        guard now != last else { return }
        last = now
        emit?(.micInUseElsewhere(now))
    }

    static func inputCapturedElsewhere(ownCaptureActive: Bool) -> Bool {
        if #available(macOS 14.2, *), let viaProcesses = otherProcessCapturingInput() { return viaProcesses }
        return !ownCaptureActive && defaultInputRunningSomewhere()
    }

    @available(macOS 14.2, *)
    static func otherProcessCapturingInput() -> Bool? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return ids.isEmpty ? false : nil }
        let own = ProcessInfo.processInfo.processIdentifier
        return ids.contains { id in
            guard uint32(id, kAudioProcessPropertyIsRunningInput) == 1 else { return false }
            return pid(id) != own
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func defaultInputRunningSomewhere() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 } ?? false
    }
}

/// Known call apps running (NSWorkspace launch/terminate notifications; no polling).
public final class CallAppMonitor: MeetingSignalSource, @unchecked Sendable {
    private var emit: ((MeetingSignal) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var last: [CallApp]?
    public var runningBundleIDs: () -> [String] = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }

    public init() {}

    public func start(emit: @escaping (MeetingSignal) -> Void) {
        self.emit = emit
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    public func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll(); emit = nil; last = nil
    }

    public func refresh() {
        let apps = CallAppCatalog.running(in: runningBundleIDs())
        guard apps != last else { return }
        last = apps
        emit?(.callApps(apps))
    }
}

/// The frontmost browser's focused-window title and document URL, via AXGuard. A meeting tab is
/// *sticky*: switching to another app keeps it (the call goes on in the background); it clears when
/// that browser is frontmost on a non-meeting page, or quits.
public final class BrowserMeetingProbe: MeetingSignalSource, @unchecked Sendable {
    private var emit: ((MeetingSignal) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var current: BrowserMeetingTab?
    private var timer: Timer?

    public init() {}

    public func start(emit: @escaping (MeetingSignal) -> Void) {
        self.emit = emit
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, let tab = self.current, app?.bundleIdentifier == tab.browserBundleID { self.publish(nil) }
        })
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    public func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll(); timer?.invalidate(); timer = nil; emit = nil; current = nil
    }

    public func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              BrowserMeetingClassifier.isBrowser(bundle) else { return }   // not a browser: keep what we had
        let (title, url) = Self.focusedWindow(pid: app.processIdentifier)
        if title == nil && url == nil { return }   // AX not granted / unreadable: no evidence either way
        publish(BrowserMeetingClassifier.classify(browserBundleID: bundle, url: url, title: title))
    }

    private func publish(_ tab: BrowserMeetingTab?) {
        guard tab != current else { return }
        current = tab
        emit?(.browserMeeting(tab))
    }

    static func focusedWindow(pid: pid_t) -> (String?, URL?) {
        guard AXIsProcessTrusted(), let root = AXGuard.application(pid: pid) else { return (nil, nil) }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window, CFGetTypeID(win) == AXUIElementGetTypeID() else { return (nil, nil) }
        let element = win as! AXUIElement
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        var doc: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &doc)
        let url = (doc as? String).flatMap(URL.init(string:))
        return (title as? String, url)
    }
}

/// Every M-d live source, started and stopped together.
public final class MeetingSignalSources: @unchecked Sendable {
    public let sources: [any MeetingSignalSource]
    public init(sources: [any MeetingSignalSource] = [MicInUseMonitor(), CallAppMonitor(), BrowserMeetingProbe()]) {
        self.sources = sources
    }
    public func start(emit: @escaping (MeetingSignal) -> Void) { sources.forEach { $0.start(emit: emit) } }
    public func stop() { sources.forEach { $0.stop() } }
    public func refresh() { sources.forEach { $0.refresh() } }
}
