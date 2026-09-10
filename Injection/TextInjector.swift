import Foundation
import Shared

/// The layered injector (P1.8 T1, rules rewritten in R2.3).
///
/// Per request: focus check → never-inject / secure-field refusal → adapter lookup → history-routed
/// method order → try methods under the **readback rule**, record the outcome locally, stop.
///
/// ## The readback rule (V3 §6, §14.4)
///
/// A method that returned `true` without throwing has *possibly landed*. Readback cannot tell
/// "did not land" from "landed but the AX value is stale", and on the owner's Mac the second case
/// was the common one: seven of twenty dictations into Brave logged `keystroke failed … readback
/// unchanged` and then `paste failed … readback unchanged`, so text that had landed once landed
/// twice (V3 §2.2). Therefore:
///
/// * a method that posted anything ends the attempt — `.injected(method:, verified:)`, with
///   `verified: false` when readback could not confirm it;
/// * the **only** fall-through to the next method is a method that threw *before* posting anything,
///   which `SystemAccess.postCount` proves;
/// * `.failed` therefore means every method threw before posting — nothing can be anywhere.
///
/// Injection is append-only (V3 §14.3): there is no retraction, so an uncertain delivery is
/// surfaced as uncertain and never retried.
public final class TextInjector: Injector {
    public let system: SystemAccess
    public let registry: AdapterRegistry
    public let router: MethodRouter
    public let focusGuard: FocusGuard
    public let paster: ClipboardPaster
    /// R2.3 ordered commit queue: segments reach the field in `SegmentID` order, once each.
    public let commits = CommitQueue()
    /// The never-inject list. `nil` means no list, so nothing is refused for routing reasons.
    /// `App` installs one (see `InjectionPolicyProviding`); `Injection` never reads settings itself.
    public var policy: InjectionPolicyProviding?
    public var clock: () -> Date = Date.init

    /// `injection_outcomes.method` for a refusal — deliberately not an `InjectionMethod` raw value,
    /// so `MethodRouter` ignores it: refusing to type into a password field says nothing about
    /// whether keystrokes work there.
    static let refusedMethodTag = "refused"

    public init(system: SystemAccess, registry: AdapterRegistry = .standard(),
                store: InjectionOutcomeStore = InMemoryOutcomeStore(), policy: InjectionPolicyProviding? = nil) {
        self.system = system
        self.registry = registry
        self.router = MethodRouter(store: store)
        self.focusGuard = FocusGuard(system: system)
        self.paster = ClipboardPaster(system: system)
        self.policy = policy
        // "Insert here" is the only path from held back to delivered, and it runs the full stack
        // against whatever has focus now.
        focusGuard.inserter = { [weak self] item in
            guard let self else { return .failed(attempts: []) }
            return self.deliver(item.request, segmentID: item.segmentID)
        }
    }

    public func inject(_ request: InjectionRequest) -> InjectionOutcome {
        deliver(request, segmentID: nil)
    }

    // MARK: Ordered commit (R2.3)

    /// Offers one committed segment to the ordered queue and delivers whatever that makes ready,
    /// in `SegmentID` order. Returns one entry per segment actually delivered — empty while the
    /// queue is still waiting for an earlier index, and empty for a segment already delivered.
    @discardableResult
    public func commit(_ request: InjectionRequest, segment: SegmentID) -> [(segment: SegmentID, outcome: InjectionOutcome)] {
        release(commits.submit(CommitQueue.Entry(segment: segment, request: request)))
    }

    /// Releases every segment still waiting, in order. For end-of-session and the quit path.
    @discardableResult
    public func flushCommits() -> [(segment: SegmentID, outcome: InjectionOutcome)] {
        release(commits.flush())
    }

    private func release(_ entries: [CommitQueue.Entry]) -> [(segment: SegmentID, outcome: InjectionOutcome)] {
        entries.map { (segment: $0.segment, outcome: deliver($0.request, segmentID: $0.segment)) }
    }

    /// Pre-R2.3 name for "deliver what focus return made possible". R2.3 abolished that: returning
    /// focus never inserts anything. Held text waits for `focusGuard.insertHere()` / `copy()` /
    /// `discard()`. Kept so existing call sites compile; it delivers nothing.
    @available(*, deprecated, message: "R2.3: focus return no longer delivers. Use focusGuard.held + insertHere().")
    @discardableResult
    public func flushQueue() -> [InjectionOutcome] { [] }

    // MARK: The stack

    private func deliver(_ request: InjectionRequest, segmentID: SegmentID?) -> InjectionOutcome {
        guard focusGuard.matches(request.expectedFocus) else { return abort(request, segmentID: segmentID) }
        guard let focus = system.frontmostApp() ?? request.expectedFocus else {
            Log.injection.error("no frontmost app; nothing injected")
            return .failed(attempts: [])
        }
        // Both refusals happen before any method runs, so nothing can have been posted.
        if let policy, policy.neverInjectBundleIDs.contains(focus.bundleID) {
            return refuse(.neverInject, request: request, segmentID: segmentID, focus: focus)
        }
        let focusedBefore = try? system.focusedElement()
        if focusedBefore?.isSecure == true {
            return refuse(.secureField, request: request, segmentID: segmentID, focus: focus)
        }

        let adapter = registry.adapter(for: focus.bundleID)
        let text = adapter.prepare(request.text, focused: focusedBefore)
        let methods = router.order(adapter.methodOrder, for: focus.bundleID)
        var attempts: [InjectionMethod] = []
        Log.injection.debug("inject \(text.count) chars into \(focus.bundleID) via \(adapter.id): \(methods.map(\.rawValue))")

        for method in methods {
            // Safe to obey a focus change here: on this path nothing has been posted yet.
            guard focusGuard.matches(request.expectedFocus) else { return abort(request, segmentID: segmentID) }
            let before = try? system.focusedElement()
            let postsBefore = system.postCount
            let started = clock()
            var claimed = false
            var thrown: Error?
            do { claimed = try perform(method, text: text, focus: focus, focused: before, adapter: adapter) }
            catch { thrown = error }
            let posted = system.postCount > postsBefore

            // Not applicable to this element, and nothing reached the OS: try the next method.
            if !claimed, !posted, thrown == nil { continue }
            attempts.append(method)
            let latency = Int((clock().timeIntervalSince(started) * 1000).rounded())

            if let thrown, !posted {
                // The only fall-through the readback rule allows: it threw before anything could land.
                Log.injection.warning("\(method.rawValue) threw before posting in \(focus.bundleID): \(thrown)")
                record(method: method.rawValue, request: request, bundleID: focus.bundleID, started: started,
                       latency: latency, succeeded: false, detail: "threw before posting: \(thrown)")
                continue
            }

            // Posted, or claimed success: possibly landed. No second method may run — that is the rule.
            let verdict = adapter.verifyReadback(text: text, before: before, after: try? system.focusedElement())
            let detail = thrown.map { "posted, then threw: \($0) — \(verdict.detail)" } ?? verdict.detail
            // `succeeded` is the router's signal, not the delivery verdict: it means "worth trying
            // first again". Confirmed counts, and so does *unavailable* — an app that exposes
            // nothing to read back (a terminal, an Electron canvas) is not evidence against the
            // method. Only readback that ran and showed nothing counts against it.
            record(method: method.rawValue, request: request, bundleID: focus.bundleID, started: started,
                   latency: latency, succeeded: verdict != .unconfirmed, detail: detail)
            Log.injection.info("\(method.rawValue) posted into \(focus.bundleID): \(detail)")
            return .injected(method: method, verified: verdict.isConfirmed)
        }
        return .failed(attempts: attempts)
    }

    // MARK: Internals

    /// Focus moved before anything was posted: hold the text and let the user place it.
    private func abort(_ request: InjectionRequest, segmentID: SegmentID?) -> InjectionOutcome {
        let actual = system.frontmostApp()
        focusGuard.hold(request, reason: DeliveryReason.destinationChanged,
                        segmentID: segmentID, destination: request.expectedFocus)
        return .abortedFocusChanged(expected: request.expectedFocus, actual: actual)
    }

    /// Declined to post at all. A never-inject app keeps the text as held (the user can still place
    /// it somewhere); a password field does not — dictation into one is never what was wanted, and
    /// holding it would keep a secret in memory.
    private func refuse(_ refusal: InjectionRefusal, request: InjectionRequest,
                        segmentID: SegmentID?, focus: FocusSnapshot) -> InjectionOutcome {
        Log.injection.notice("refused to inject into \(focus.bundleID): \(refusal.rawValue)")
        record(method: Self.refusedMethodTag, request: request, bundleID: focus.bundleID, started: clock(),
               latency: 0, succeeded: false, detail: refusal.rawValue)
        if refusal.holdsText {
            focusGuard.hold(request, reason: refusal.rawValue, segmentID: segmentID, destination: focus)
        }
        return .refused(refusal)
    }

    private func record(method: String, request: InjectionRequest, bundleID: String, started: Date,
                        latency: Int, succeeded: Bool, detail: String) {
        router.store.record(InjectionOutcomeRecord(timestamp: started, utteranceID: request.utteranceID,
                                                  appBundleID: bundleID, method: method, succeeded: succeeded,
                                                  latencyMs: latency, detail: detail))
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
}
