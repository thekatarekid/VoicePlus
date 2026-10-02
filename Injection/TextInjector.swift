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
    /// Q3 — readback is judged only after the field has had a moment to apply the write
    /// (`AXObserver` value/selection change, else 30 ms polls, up to 400 ms).
    public var readbackSettler = ReadbackSettler.standard

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
            return self.deliverReport(item.request, segmentID: item.segmentID, turnID: item.turnID).outcome
        }
    }

    public func inject(_ request: InjectionRequest) -> InjectionOutcome {
        deliver(request, segmentID: nil)
    }

    // MARK: Turn commit guard (S3)

    /// S3 — "inserted exactly once": every commit that goes through `commit(_:key:)` is keyed by
    /// `TurnID` + target revision, and a second commit for the same key posts nothing.
    public let turnCommits = TurnCommitGuard()

    public func commit(_ request: InjectionRequest, key: TurnCommitKey) -> TurnCommitResult {
        turnCommits.commit(key) { deliverReport(request, segmentID: nil, turnID: key.turnID) }
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
        deliverReport(request, segmentID: segmentID, turnID: nil).outcome
    }

    /// The stack, with the one fact `InjectionOutcome` cannot carry: whether the method that ended
    /// the attempt posted and *then* threw — part of the payload may be in the field (design §12,
    /// `DeliveryOutcome.partial`). `turnID` rides onto any text this attempt holds.
    private func deliverReport(_ request: InjectionRequest, segmentID: SegmentID?, turnID: TurnID?) -> TurnCommitReport {
        // FX1 — a write into VoicePlus's own window runs on the main thread, start to finish.
        if !Thread.isMainThread, targetsOwnProcess(request) {
            return deliverOnMain(request, segmentID: segmentID, turnID: turnID)
        }
        guard focusGuard.matches(request.expectedFocus) else {
            return TurnCommitReport(abort(request, segmentID: segmentID, turnID: turnID))
        }
        guard let focus = system.frontmostApp() ?? request.expectedFocus else {
            Log.injection.error("no frontmost app; nothing injected")
            return TurnCommitReport(.failed(attempts: []))
        }
        // Both refusals happen before any method runs, so nothing can have been posted.
        if let policy, policy.neverInjectBundleIDs.contains(focus.bundleID) {
            return TurnCommitReport(refuse(.neverInject, request: request, segmentID: segmentID, focus: focus, turnID: turnID))
        }
        let own = OwnProcess.owns(focus)
        // Q2 — the tree must exist before the first read (cached per pid: free after key-down).
        if !own { (system as? AppAccessibilityEnabling)?.enableAppAccessibility(pid: focus.pid) }
        let focusedBefore = readFocused(own: own)
        // N4 — a password field, or a blind write (no readable field) while macOS secure input is on.
        if let block = secureBlock(focusedBefore) {
            Log.injection.notice("N4: \(block.rawValue); nothing written")
            return TurnCommitReport(refuse(.secureField, request: request, segmentID: segmentID, focus: focus, turnID: turnID))
        }

        // FX1 — our own window never gets the AX-first default: it gets the in-process path.
        // N5 — the bundle-id adapter is only the starting point: a terminal surface gets the
        // terminal plan, web content the ⇧↩ keystroke plan (never a bare ↩, never an AX write).
        let base: AppAdapter = own ? ownProcessAdapter : registry.adapter(for: focus.bundleID)
        let context = own ? SurfaceWriteContext() : writeContext(request, focus: focus, focused: focusedBefore)
        let adapter = own ? base : WritePlanner.adapter(base: base, context: context)
        let text = adapter.prepare(request.text, focused: focusedBefore)
        // N16 — in a newline-safe plan paste never jumps ahead of keystrokes.
        var methods = router.order(adapter.methodOrder, for: focus.bundleID,
                                   keepKeystrokeBeforePaste: adapter is NewlineSafeAdapter)
        // N3 — the delivery ladder: a readable field is not required to write.
        if !own {
            let decision = ladderDecision(request, focus: focus, focused: focusedBefore, context: context)
            lastLadderDecision = decision
            switch decision {
            case .deliver(let method, let verify):
                Log.injection.notice("N3 ladder: deliver via \(method.rawValue)\(verify ? "" : " (unverified)") into \(focus.bundleID)")
                methods = DeliveryLadder.order(methods, ladder: method, fieldReadable: SecureInputGuard.isReadable(focusedBefore),
                                               adapter: adapter)
            case .hold(let reason), .notes(let reason):
                // Only window changes reach here (focus and secure checks ran above): hold, never write.
                Log.injection.notice("N3 ladder: \(reason.rawValue); held, nothing written")
                return TurnCommitReport(abort(request, segmentID: segmentID, turnID: turnID,
                                              reason: reason == .notEditable ? reason.rawValue : DeliveryReason.destinationChanged))
            }
        }
        var attempts: [InjectionMethod] = []
        Log.injection.debug("inject \(text.count) chars into \(focus.bundleID) via \(adapter.id): \(methods.map(\.rawValue))")

        for method in methods {
            // Safe to obey a focus change here: on this path nothing has been posted yet.
            guard focusGuard.matches(request.expectedFocus) else {
                return TurnCommitReport(abort(request, segmentID: segmentID, turnID: turnID))
            }
            var before = readFocused(own: own)
            // N4 — re-checked right before each write: secure input can come on mid-turn.
            if let block = secureBlock(before) {
                Log.injection.notice("N4: \(block.rawValue) before \(method.rawValue); nothing written")
                return TurnCommitReport(refuse(.secureField, request: request, segmentID: segmentID, focus: focus, turnID: turnID))
            }
            // Q1 — a browser's line break depends on the page (⌥↩ in a Sheets cell, ⇧↩ elsewhere).
            if adapter is NewlineSafeAdapter, text.contains("\n"), before != nil, before?.documentURL == nil,
               let reader = system as? FocusedDocumentURLReading {
                before?.documentURL = reader.focusedDocumentURL()
            }
            let postsBefore = system.postCount
            // FX1 — kept at notice (info/debug are not persisted), so the last write before a freeze
            // is always in the log: what, where, how.
            Log.injection.notice("write: \(text.count) chars into \(focus.bundleID) via \(method.rawValue)\(own ? " (own process, in-process)" : "")")
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
            // Q3 — settle before judging: re-read until confirmed or the 400 ms budget runs out.
            let settled = readbackSettler.settle(system: system, pid: own ? nil : focus.pid, before: before,
                                                 read: { readFocused(own: own) },
                                                 judge: { adapter.verifyReadback(text: text, before: before, after: $0) },
                                                 clock: clock)
            let verdict = settled.verdict
            // Q4 — unreadable (could not run) vs unconfirmed (ran, text absent): the pill's neutral vs sticky row.
            LandingVerdictLedger.shared.record(LandingVerdict(readback: verdict), text: request.text, utteranceID: request.utteranceID)
            let detail = thrown.map { "posted, then threw: \($0) — \(verdict.detail)" } ?? verdict.detail
            Log.injection.debug("readback \(focus.bundleID): \(settled.detail)")
            // `succeeded` is the router's signal, not the delivery verdict: it means "worth trying
            // first again". Confirmed counts, and so does *unavailable* — an app that exposes
            // nothing to read back (a terminal, an Electron canvas) is not evidence against the
            // method. Only readback that ran and showed nothing counts against it.
            record(method: method.rawValue, request: request, bundleID: focus.bundleID, started: started,
                   latency: latency, succeeded: verdict != .unconfirmed, detail: detail)
            Log.injection.info("\(method.rawValue) posted into \(focus.bundleID): \(detail)")
            return TurnCommitReport(.injected(method: method, verified: verdict.isConfirmed),
                                    postedThenThrew: thrown != nil,
                                    landing: LandingVerdict(readback: verdict),
                                    settleMilliseconds: settled.settleMilliseconds)
        }
        return TurnCommitReport(.failed(attempts: attempts))
    }

    // MARK: FX1 — our own process

    /// FX1 — the adapter for VoicePlus's own windows (in-process insert, never AX).
    let ownProcessAdapter = OwnProcessAdapter()
    /// FX1 — how long an own-process write waits for the main thread before holding the text.
    public var mainThreadWriteTimeout = MainThreadHop.writeStartTimeout

    /// FX1 — the request is aimed at, or would land in, VoicePlus itself. Either side is enough:
    /// the snapshot says where the text was meant to go, the frontmost app where it would go now.
    func targetsOwnProcess(_ request: InjectionRequest) -> Bool {
        OwnProcess.owns(request.expectedFocus) || OwnProcess.owns(system.frontmostApp())
    }

    /// FX1 — the focused element for readback. Our own text view is read in-process (main thread).
    private func readFocused(own: Bool) -> FocusedElementInfo? {
        if own, let local = system as? InProcessTextDelivering, let info = local.ownFocusedText() { return info }
        return try? system.focusedElement()
    }

    /// N5 — the structural facts the write plan is chosen from (resolver kind, web-area ancestor,
    /// runtime sniffed from the bundle). Each probe is optional: a system that cannot answer is
    /// treated as "no evidence", which keeps the bundle-id adapter.
    private func writeContext(_ request: InjectionRequest, focus: FocusSnapshot, focused: FocusedElementInfo?) -> SurfaceWriteContext {
        SurfaceWriteContext(kind: request.surfaceKind,
                            isInWebArea: (system as? WebAreaProbing)?.focusedIsInWebArea() ?? false,
                            runtime: (system as? AppRuntimeReading)?.appRuntime(pid: focus.pid),
                            hints: focused?.hints ?? [])
    }

    /// N3 — the last ladder decision (diagnostics and tests).
    public private(set) var lastLadderDecision: DeliveryLadder.Decision?

    /// N3 — the ladder over the live facts. The focus and secure checks already passed.
    private func ladderDecision(_ request: InjectionRequest, focus: FocusSnapshot, focused: FocusedElementInfo?,
                                context: SurfaceWriteContext) -> DeliveryLadder.Decision {
        var window = DeliveryLadder.WindowState.unknown
        if let expected = request.expectedWindowToken, let reader = system as? FocusedWindowReading {
            window = DeliveryLadder.windowState(expected: expected, current: reader.focusedWindowToken(pid: focus.pid),
                                                expectedStillExists: reader.windowExists(pid: focus.pid, token: expected))
        }
        return DeliveryLadder.decide(focusSame: true, window: window,
                                     secureInput: SecureInputGuard.isActive(on: system),
                                     fieldReadable: SecureInputGuard.isReadable(focused),
                                     surface: request.surfaceKind ?? (context.isTerminal ? .terminal : nil),
                                     multiline: request.text.contains(where: \.isNewline),
                                     webContent: context.isWebContent,
                                     passwordField: focused?.isSecure == true)
    }

    /// N4 — the pre-write safety check (password field; secure input on with no readable field).
    private func secureBlock(_ focused: FocusedElementInfo?) -> SecureInputGuard.Block? {
        SecureInputGuard.blocksWrite(focused: focused, secureInput: SecureInputGuard.isActive(on: system))
    }

    /// FX1 — runs the whole stack on the main thread. If the main thread does not pick it up in
    /// time nothing was posted and nothing will be: the text is held for Insert here / Copy, never
    /// written late and never lost.
    private func deliverOnMain(_ request: InjectionRequest, segmentID: SegmentID?, turnID: TurnID?) -> TurnCommitReport {
        do {
            return try MainThreadHop.run(startTimeout: mainThreadWriteTimeout) { [self] in
                deliverReport(request, segmentID: segmentID, turnID: turnID)
            }
        } catch {
            Log.injection.fault("own-process write: the main thread did not take it (\(error)); \(request.text.count) chars held, nothing posted")
            return TurnCommitReport(abort(request, segmentID: segmentID, turnID: turnID))
        }
    }

    // MARK: Internals

    /// Focus moved before anything was posted: hold the text and let the user place it.
    private func abort(_ request: InjectionRequest, segmentID: SegmentID?, turnID: TurnID? = nil,
                       reason: String = DeliveryReason.destinationChanged) -> InjectionOutcome {
        let actual = system.frontmostApp()
        focusGuard.hold(request, reason: reason,
                        segmentID: segmentID, destination: request.expectedFocus, turnID: turnID)
        return .abortedFocusChanged(expected: request.expectedFocus, actual: actual)
    }

    /// Declined to post at all. A never-inject app keeps the text as held (the user can still place
    /// it somewhere); a password field does not — dictation into one is never what was wanted, and
    /// holding it would keep a secret in memory.
    private func refuse(_ refusal: InjectionRefusal, request: InjectionRequest,
                        segmentID: SegmentID?, focus: FocusSnapshot, turnID: TurnID? = nil) -> InjectionOutcome {
        Log.injection.notice("refused to inject into \(focus.bundleID): \(refusal.rawValue)")
        record(method: Self.refusedMethodTag, request: request, bundleID: focus.bundleID, started: clock(),
               latency: 0, succeeded: false, detail: refusal.rawValue)
        if refusal.holdsText {
            focusGuard.hold(request, reason: refusal.rawValue, segmentID: segmentID, destination: focus, turnID: turnID)
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
            // Q1 / N5 — a line break is ⇧↩ (⌥↩ in a sheet cell), never a bare ↩, in every plan.
            if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
                try NewlineSafety.type(text, newline: WritePlanner.newlineCombo(adapter: adapter, focused: focused),
                                       toPID: focus.pid, system: system)
                return true
            }
            try system.postUnicodeKeystrokes(text, toPID: focus.pid)
            return true
        case .adapter:
            // The own-process path is AppKit's own editing API: it needs no accessibility permission.
            guard system.isAccessibilityTrusted || adapter is OwnProcessAdapter else { return false }
            return try adapter.injectViaAdapter(text, focus: focus, focused: focused, system: system)
        case .paste:
            try paster.paste(text, toPID: focus.pid)
            return true
        }
    }
}

// MARK: - S3 — the turn commit guard

/// What a turn's one insert is keyed by: the turn, and the revision of the destination it was
/// validated against. The turn controller passes the key-down snapshot's revision; an explicit
/// re-target (Insert here into a new field) is a new revision. The same key never posts twice.
public struct TurnCommitKey: Hashable, Sendable, CustomStringConvertible {
    public var turnID: TurnID
    public var revision: Int

    public init(turnID: TurnID, revision: Int) {
        self.turnID = turnID
        self.revision = revision
    }

    public var description: String { "\(turnID.description)@\(revision)" }
}

/// One commit's result as the stack saw it.
public struct TurnCommitReport: Equatable, Sendable {
    public var outcome: InjectionOutcome
    /// The method that ended the attempt posted and then threw: some of the text may be in the
    /// field. Never "nothing was typed", never retried (design §12).
    public var postedThenThrew: Bool
    /// Q3/Q4 — what the settled readback said about a write that posted (`nil` when nothing posted).
    public var landing: LandingVerdict?
    /// Q3 — how long readback waited for the field to settle before judging (for Q13 diagnostics).
    public var settleMilliseconds: Int?

    public init(_ outcome: InjectionOutcome, postedThenThrew: Bool = false,
                landing: LandingVerdict? = nil, settleMilliseconds: Int? = nil) {
        self.outcome = outcome
        self.postedThenThrew = postedThenThrew
        self.landing = landing
        self.settleMilliseconds = settleMilliseconds
    }

    /// The delivery outcome, with the partial case `InjectionOutcome` cannot express: a method that
    /// posted, threw, and could not be confirmed by readback is `.partial` (D07), not a clean
    /// unconfirmed delivery (D06).
    public var delivery: DeliveryOutcome {
        if postedThenThrew, case let .injected(method, verified) = outcome, !verified {
            return .partial(method: method.rawValue)
        }
        return outcome.delivery
    }
}

public enum TurnCommitResult: Equatable, Sendable {
    /// The first commit for this key: the stack ran.
    case committed(TurnCommitReport)
    /// This key was already committed (or is being committed right now): nothing was posted.
    /// `previous` is the first commit's report once it is known.
    case duplicate(TurnCommitKey, previous: TurnCommitReport?)

    public var report: TurnCommitReport? {
        switch self {
        case .committed(let report): return report
        case .duplicate(_, let previous): return previous
        }
    }

    public var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

/// An injector that can commit once per turn. `TextInjector` is one; the lander wraps any other
/// injector (a test spy, a holding injector) in its own `TurnCommitGuard`.
public protocol TurnCommitting: AnyObject {
    func commit(_ request: InjectionRequest, key: TurnCommitKey) -> TurnCommitResult
}

extension TextInjector: TurnCommitting {}

/// S3 — the idempotent commit guard: the first `commit` for a key runs the delivery, every later one
/// (a duplicate key-up, a stale callback, a retry from anywhere) returns `.duplicate` without
/// running anything. The key is claimed *before* the delivery runs, so two racing commits cannot
/// both post. Remembers the last `memory` keys.
public final class TurnCommitGuard: @unchecked Sendable {
    public var memory = 256
    private let lock = NSLock()
    private var order: [TurnCommitKey] = []
    private var reports: [TurnCommitKey: TurnCommitReport?] = [:]

    public init() {}

    public func hasCommitted(_ key: TurnCommitKey) -> Bool { lock.withLock { reports[key] != nil } }

    /// Runs `deliver` only for the first commit of `key`.
    public func commit(_ key: TurnCommitKey, _ deliver: () -> TurnCommitReport) -> TurnCommitResult {
        let duplicate = lock.withLock { () -> TurnCommitResult? in
            if let previous = reports[key] { return .duplicate(key, previous: previous) }
            reports[key] = .some(nil)
            order.append(key)
            while order.count > max(1, memory) { reports[order.removeFirst()] = nil }
            return nil
        }
        if let duplicate {
            Log.injection.notice("commit guard: turn \(key.description) already committed; nothing posted")
            return duplicate
        }
        let report = deliver()
        lock.withLock { if reports[key] != nil { reports[key] = .some(report) } }
        return .committed(report)
    }
}
