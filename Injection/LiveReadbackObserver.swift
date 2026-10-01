import ApplicationServices
import Foundation
import Shared

/// Q3 — `AXObserver` pacing for `ReadbackSettler`: block up to `timeoutMilliseconds` until the
/// focused element of `pid` posts a value- or selection-changed notification.
///
/// The observer's source is added to the *current* run loop in a private mode and only that mode is
/// run, so nothing else (timers, UI events) is serviced re-entrantly while the injector waits.
/// K18 — never observes our own process (own pid → `nil`, the settler falls back to polling).
extension LiveSystemAccess: ReadbackChangeWaiting {
    static let settleRunLoopMode = CFRunLoopMode("com.voiceplus.readback-settle" as CFString)

    public func waitForFocusedChange(pid: Int32, timeoutMilliseconds: Int) -> Bool? {
        guard timeoutMilliseconds > 0, isAccessibilityTrusted, let app = AXGuard.application(pid: pid) else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement   // swiftlint:disable:this force_cast

        let flag = ChangeFlag()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<ChangeFlag>.fromOpaque(refcon).takeUnretainedValue().changed = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }
        let refcon = Unmanaged.passUnretained(flag).toOpaque()
        var registered = 0
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            if AXObserverAddNotification(observer, element, name as CFString, refcon) == .success { registered += 1 }
        }
        defer {
            for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
        }
        // The app does not post either notification (common in Electron): poll instead.
        guard registered > 0 else { return nil }
        let source = AXObserverGetRunLoopSource(observer)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, Self.settleRunLoopMode)
        defer { CFRunLoopRemoveSource(loop, source, Self.settleRunLoopMode) }
        _ = CFRunLoopRunInMode(Self.settleRunLoopMode, Double(timeoutMilliseconds) / 1000, true)
        return withExtendedLifetime(flag) { flag.changed }
    }

    private final class ChangeFlag { var changed = false }
}
