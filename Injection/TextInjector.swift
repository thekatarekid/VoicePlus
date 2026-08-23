import Foundation
import Shared

/// The layered injector (T1). Per request: focus check → adapter lookup → history-routed method order →
/// try each method, verify by AX readback where possible, record the outcome locally, stop at first success.
public final class TextInjector: Injector {
    public let system: SystemAccess
    public let registry: AdapterRegistry
    public let router: MethodRouter
    public let focusGuard: FocusGuard
    public let paster: ClipboardPaster
    public var clock: () -> Date = Date.init

    public init(system: SystemAccess, registry: AdapterRegistry = .standard(), store: InjectionOutcomeStore = InMemoryOutcomeStore()) {
        self.system = system
        self.registry = registry
        self.router = MethodRouter(store: store)
        self.focusGuard = FocusGuard(system: system)
        self.paster = ClipboardPaster(system: system)
    }

    public func inject(_ request: InjectionRequest) -> InjectionOutcome {
        guard focusGuard.matches(request.expectedFocus) else { return abort(request) }
        guard let focus = system.frontmostApp() ?? request.expectedFocus else {
            Log.injection.error("no frontmost app; nothing injected")
            return .failed(attempts: [])
        }
        let adapter = registry.adapter(for: focus.bundleID)
        let focusedBefore = try? system.focusedElement()
        let text = adapter.prepare(request.text, focused: focusedBefore)
        let methods = router.order(adapter.methodOrder, for: focus.bundleID)
        var attempts: [InjectionMethod] = []
        Log.injection.debug("inject \(text.count) chars into \(focus.bundleID) via \(adapter.id): \(methods.map(\.rawValue))")

        for method in methods {
            guard focusGuard.matches(request.expectedFocus) else { return abort(request) }
            let before = try? system.focusedElement()
            let started = clock()
            let attempted: Bool
            var failure: String?
            do {
                attempted = try perform(method, text: text, focus: focus, focused: before, adapter: adapter)
            } catch {
                attempted = true
                failure = "\(error)"
            }
            guard attempted else { continue }   // method not applicable here; don't pollute history
            attempts.append(method)

            var verified = false
            var landed = failure == nil
            if landed, let before, before.isReadable, let after = try? system.focusedElement(), let afterValue = after.value {
                verified = Self.readbackConfirms(before: before, after: afterValue, text: text)
                if !verified {
                    landed = false
                    failure = "readback unchanged"
                }
            }
            let latency = Int((clock().timeIntervalSince(started) * 1000).rounded())
            router.store.record(InjectionOutcomeRecord(timestamp: started, utteranceID: request.utteranceID, appBundleID: focus.bundleID,
                                                       method: method.rawValue, succeeded: landed, latencyMs: latency,
                                                       detail: failure ?? (verified ? "verified" : "unverified")))
            if landed {
                Log.injection.info("\(method.rawValue) landed in \(focus.bundleID) (\(verified ? "verified" : "unverified"))")
                return .injected(method: method, verified: verified)
            }
            Log.injection.warning("\(method.rawValue) failed in \(focus.bundleID): \(failure ?? "?")")
        }
        return .failed(attempts: attempts)
    }

    /// Delivers queued requests whose target app is frontmost again.
    @discardableResult
    public func flushQueue() -> [InjectionOutcome] {
        focusGuard.dequeueDeliverable().map { inject($0) }
    }

    // MARK: Internals

    private func abort(_ request: InjectionRequest) -> InjectionOutcome {
        focusGuard.enqueue(request)
        return .abortedFocusChanged(expected: request.expectedFocus, actual: system.frontmostApp())
    }

    /// Returns `false` when the method is not applicable to this element (skipped silently).
    private func perform(_ method: InjectionMethod, text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, adapter: AppAdapter) throws -> Bool {
        switch method {
        case .ax:
            guard system.isAccessibilityTrusted, let focused else { return false }
            if focused.isSelectedTextSettable {
                try system.setFocusedSelectedText(text)
                return true
            }
            if focused.isValueSettable, let value = focused.value, let sel = focused.selectedRange {
                var units = Array(value.utf16)
                let clamped = max(0, min(sel.lowerBound, units.count))..<max(0, min(sel.upperBound, units.count))
                units.replaceSubrange(clamped, with: Array(text.utf16))
                try system.setFocusedValue(String(decoding: units, as: UTF16.self))
                let caret = clamped.lowerBound + text.utf16.count
                try? system.setFocusedSelectedRange(caret..<caret)
                return true
            }
            return false
        case .keystroke:
            guard system.isAccessibilityTrusted else { return false }
            try system.postUnicodeKeystrokes(text, toPID: focus.pid)
            return true
        case .adapter:
            guard system.isAccessibilityTrusted else { return false }
            return try adapter.injectViaAdapter(text, focus: focus, focused: focused, system: system)
        case .paste:
            try paster.paste(text, toPID: focus.pid)
            return true
        }
    }

    static func readbackConfirms(before: FocusedElementInfo, after: String, text: String) -> Bool {
        guard let value = before.value else { return false }
        if let sel = before.selectedRange {
            var units = Array(value.utf16)
            let clamped = max(0, min(sel.lowerBound, units.count))..<max(0, min(sel.upperBound, units.count))
            units.replaceSubrange(clamped, with: Array(text.utf16))
            if String(decoding: units, as: UTF16.self) == after { return true }
        }
        // Adapters may wrap the text (bracketed paste) or the app may normalise whitespace.
        return after != value && after.contains(text)
    }
}
