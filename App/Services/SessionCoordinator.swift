import AppKit
import Engine
import Foundation
import Shared

/// R3.1 — **one** owner of start, stop and cancel, and of who may hold the microphone (V3 §4.6).
///
/// Before this existed, four callers opened capture on their own account: the hotkey
/// (`DictationCoordinator`), the menu, onboarding's mic check and dictation test, and meeting
/// capture. Each one knew how to start; none of them knew about the others. The ranked graph owner
/// in `PipelineAudioSource.Owner` stopped them from corrupting each other's *audio graph*, but
/// nothing said which of them was allowed to *ask* — so a meeting could begin under a held hotkey,
/// and onboarding's meter could be taken over with no way to say what happened.
///
/// This class is that missing layer, and deliberately only that layer:
///
/// * it decides who wins (`requestMicrophone`), mapping every requester onto the **existing**
///   `PipelineAudioSource.Owner` ranks rather than inventing a second arbitration scheme;
/// * it tells the loser (`onStandDown`) instead of letting it go quietly flat;
/// * it owns the mode (`hold` / `latched`) and every event that must end a session outright — hard
///   mute (V3 §4.4), screen lock and sleep (§8), Escape (§4.3).
///
/// **V5 O1 — arbiter of intent, not owner of the microphone.** Since O1 the microphone is one capture
/// graph with many subscribers (`AudioPipeline.Broadcaster`). What this class arbitrates is who
/// *claims the next utterance* (`activeRequester`, an intent claim — dictation, the menu, onboarding,
/// diagnostics), not who may hear audio. The meeting and the ambient timeline are **recorders**
/// (`Requester.isRecorder`): they keep everything while on, are never pre-empted by a claim and never
/// pre-empt one, and are tracked separately (`activeRecorders`). Only hard mute, lock and sleep stand
/// a recorder down.
///
/// It does **not** open or close the capture graph itself. `DictationCoordinator` → `RealEngine` →
/// `PipelineAudioSource.start(for:)` is still the only path to the microphone; a second one here
/// would be the duplicate the build doc forbids.
public final class SessionCoordinator {
    /// Everyone who can ask for the microphone.
    public enum Requester: String, CaseIterable, Sendable {
        /// The dictation hotkey. Outranks everything: a key the user is holding must never lose.
        case hotkey
        /// Menu bar / "Start dictation".
        case menu
        /// Meeting capture. V5 O1: a recorder — it never takes the utterance claim.
        case meeting
        /// Onboarding's mic check and dictation test.
        case onboarding
        /// `--mic-selftest` and friends.
        case diagnostics
        /// V5 O1 — the ambient timeline. A recorder, like `.meeting`.
        case ambient

        /// V5 O1 — recorders keep audio; they never claim an utterance, never pre-empt a claim and
        /// are never pre-empted by one.
        public var isRecorder: Bool { self == .meeting || self == .ambient }

        /// The capture graph's recorder slot for a recorder requester (nil for claims).
        public var recorder: PipelineAudioSource.Recorder? {
            switch self {
            case .meeting: return .meeting
            case .ambient: return .ambient
            case .hotkey, .menu, .onboarding, .diagnostics: return nil
            }
        }

        /// Rank *within* this layer. Higher wins; equal ranks preempt in arrival order, which is
        /// what makes "menu then hotkey" work the way the user expects.
        public var rank: Int {
            switch self {
            case .hotkey: return 3
            case .menu: return 2
            case .meeting: return 1
            case .onboarding, .diagnostics, .ambient: return 0
            }
        }

        /// How this requester shows up to the capture graph. Dictation-shaped requesters are the
        /// graph's `.engine` owner; the meter and diagnostics keep their own lower-ranked slots, so
        /// the two rankings can never disagree about who beats whom. V5 O1: recorders own nothing —
        /// they attach as `PipelineAudioSource.Recorder` (`recorder`), so this is nil for them.
        public var audioOwner: PipelineAudioSource.Owner? {
            switch self {
            case .hotkey, .menu: return .engine
            case .onboarding: return .meter
            case .diagnostics: return .diagnostics
            case .meeting, .ambient: return nil
            }
        }

        /// Does this requester dictate (i.e. produce text through `DictationCoordinator`)?
        public var dictates: Bool { self == .hotkey || self == .menu }
    }

    public enum Mode: Equatable, Sendable {
        case idle
        /// Push-to-talk: capture only while the gesture is held (V3 §4.2).
        case hold
        /// Latched: capture continues across endpoints until the user stops it (V3 §4.3).
        case latched
    }

    /// Why a request was refused, in the words the surfaces use.
    public enum Refusal: Error, Equatable, Sendable {
        /// A higher-ranked requester holds the microphone.
        case busy(Requester)
        /// Hard mute. Nothing opens the microphone while muted, and unmuting is always a gesture.
        case muted
        /// The screen locked or the machine slept. Capture never resumes on its own (V3 §8).
        case awaitingRestart

        /// The catalogue headline (K04 / A09 / K05 / K02), never a requester's raw name. Surfaces
        /// take the whole entry (`RecoveryCatalog.entry(for:)`, `SessionRefusalWiring`).
        public var message: String { RecoveryCatalog.entry(for: self).headline }
    }

    /// Why a session ended, for the log and for the pill.
    public enum StopReason: String, Equatable, Sendable {
        case userStopped, escape, muted, locked, slept, preempted, deviceLost
    }

    public let dictation: DictationCoordinator
    public let mute: MuteController
    public let latch: LatchRuntime?

    /// Told to release the microphone when a higher-ranked requester takes it. The capture graph
    /// preempts the stream on its own; this is how the *owner* finds out, so a mic check can say
    /// "dictation took the microphone" rather than showing a dead meter.
    public var onStandDown: ((Requester) -> Void)?
    /// Every refusal, so a caller that cannot handle one can still show it. The app points it at
    /// the pill (`SessionRefusalWiring`): a refused dictation start is never silent.
    public var onRefusal: ((Requester, Refusal) -> Void)?
    /// A session ended, with the reason.
    public var onStopped: ((Requester, StopReason) -> Void)?

    private let lock = NSLock()
    private var holder: Requester?
    /// V5 O1 — running recorders (meeting, ambient). Never touched by claim arbitration.
    private var recorders: Set<Requester> = []
    private var requestedMode: Mode = .idle
    /// Set by lock/sleep. Cleared only by an explicit start — never by waking up (V3 §8).
    private var awaitingRestart = false

    public init(dictation: DictationCoordinator, mute: MuteController, latch: LatchRuntime? = nil) {
        self.dictation = dictation
        self.mute = mute
        self.latch = latch
        latch?.isLatched = { [weak dictation] in dictation?.latched ?? false }
        // The mode has exactly one home. `DictationCoordinator.latched` is it; this mirror exists so
        // `mode` can be read without asking two objects and getting two answers.
        //
        // B1 — it is also the one place latch entry and exit are seen, whichever path caused them
        // (the double tap, the stop tap, Escape, mute, lock, sleep, a failed start), so the latch
        // runtime connects to the capture feed here and lets go of it here.
        dictation.onLatchChanged = { [weak self] latched in
            guard let self else { return }
            self.lock.withLock { self.requestedMode = latched ? .latched : (self.holder == nil ? .idle : .hold) }
            if latched { self.latch?.enterLatch(feed: self.dictation.latchAudio) } else { self.latch?.leaveLatch() }
        }
        dictation.onLatchAudioChanged = { [weak self] in
            guard let self else { return }
            self.latch?.replaceFeed(self.dictation.latchAudio)
        }
        // B4 — the timer: runtime → coordinator → pill, on the main thread.
        latch?.onElapsed = { [weak dictation] elapsed in
            if Thread.isMainThread { dictation?.noteLatchElapsed(elapsed) }
            else { DispatchQueue.main.async { dictation?.noteLatchElapsed(elapsed) } }
        }
    }

    // MARK: The latch pause setting — B2 (V4.33)

    private var latchSettings: SettingsStore?
    private var latchSettingsObservers: [NSObjectProtocol] = []
    private var latchSettingsCenter: NotificationCenter?

    deinit { latchSettingsObservers.forEach { latchSettingsCenter?.removeObserver($0) } }

    /// Reads "Insert after a pause of" into the latch now, and again whenever it changes — live,
    /// including in the middle of a latched session. `LatchSettings.setPauseSeconds` posts the change;
    /// a write straight to `UserDefaults` is seen through its own change notification.
    public func bindLatchSettings(_ store: SettingsStore, center: NotificationCenter = .default) {
        latchSettingsObservers.forEach { latchSettingsCenter?.removeObserver($0) }
        latchSettingsCenter = center
        latchSettings = store
        applyLatchPause()
        let apply: (Notification) -> Void = { [weak self] _ in self?.applyLatchPause() }
        latchSettingsObservers = [
            center.addObserver(forName: LatchSettings.didChangeNotification, object: nil, queue: .main, using: apply),
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: apply),
        ]
    }

    /// The pause the latch is running with, from the bound store (the default when none is bound).
    public var latchPauseSeconds: TimeInterval { LatchSettings.pauseSeconds(latchSettings) }

    private func applyLatchPause() {
        guard let latch, let store = latchSettings else { return }
        let pause = LatchSettings.pauseSeconds(store)
        let wanted = LatchSettings.endpointer(pauseSeconds: pause)
        let current = latch.endpointer
        guard current.trailingSilence != wanted.trailingSilence || current.noSpeechTimeout != wanted.noSpeechTimeout
            || current.maxUtterance != wanted.maxUtterance else { return }
        latch.setPauseSeconds(pause)
        Log.app.info("latch: pause set to \(pause)s")
    }

    // MARK: State

    /// Who holds the utterance claim (V5 O1: an intent claim, not microphone ownership — recorders
    /// may be hearing the same audio at the same time).
    public var activeRequester: Requester? { lock.withLock { holder } }
    /// V5 O1 — recorders currently running, in `Requester` order.
    public var activeRecorders: [Requester] {
        lock.withLock { Requester.allCases.filter(recorders.contains) }
    }
    public var mode: Mode {
        if dictation.latched { return .latched }
        return lock.withLock { holder == nil ? .idle : requestedMode }
    }
    public var isLatched: Bool { dictation.latched }
    public var isMuted: Bool { mute.isMuted }
    /// True after a lock or sleep, until something starts a session explicitly.
    public var needsExplicitRestart: Bool { lock.withLock { awaitingRestart } }

    // MARK: Arbitration

    public enum Arbitration: Equatable, Sendable {
        case granted
        /// Granted, and this requester was displaced.
        case preempted(Requester)
        case refused(Refusal)

        public var isGranted: Bool { if case .refused = self { return false } ; return true }
    }

    /// Decides whether `requester` may hold the microphone now, and records the answer.
    ///
    /// Nothing here opens capture: the winner still goes through its own path (and therefore through
    /// `PipelineAudioSource.start(for:)`, the one place that reconfigures the graph).
    @discardableResult
    public func requestMicrophone(_ requester: Requester) -> Arbitration {
        if mute.isMuted {
            onRefusal?(requester, .muted)
            return .refused(.muted)
        }
        // V5 O1 — a recorder joins the one capture graph beside whoever holds the claim: it is
        // never refused for being outranked and never displaces anyone.
        if requester.isRecorder {
            _ = lock.withLock { recorders.insert(requester) }
            return .granted
        }
        var displaced: Requester?
        var refusal: Refusal?
        lock.withLock {
            if let current = holder, current != requester {
                // Equal ranks preempt in arrival order — that is what makes "menu, then hotkey"
                // behave the way the user expects, and it matches `PipelineAudioSource.start(for:)`,
                // which also lets an equal rank take the graph.
                guard requester.rank >= current.rank else {
                    refusal = .busy(current)
                    return
                }
                displaced = current
            }
            holder = requester
            awaitingRestart = false
        }
        if let refusal {
            onRefusal?(requester, refusal)
            return .refused(refusal)
        }
        guard let displaced else { return .granted }
        Log.app.notice("session: \(requester.rawValue) takes the microphone from \(displaced.rawValue)")
        if displaced.dictates { dictation.cancel() }
        onStandDown?(displaced)
        onStopped?(displaced, .preempted)
        return .preempted(displaced)
    }

    /// Releases the microphone if `requester` still holds it.
    public func release(_ requester: Requester) {
        if requester.isRecorder {
            _ = lock.withLock { recorders.remove(requester) }
            return
        }
        lock.withLock {
            guard holder == requester else { return }
            holder = nil
            requestedMode = .idle
        }
    }

    // MARK: Start / stop / cancel

    /// Starts a session for `requester`. Only dictation-shaped requesters drive
    /// `DictationCoordinator`; the rest get an arbitration answer and open their own capture.
    @discardableResult
    public func start(_ requester: Requester, mode: Mode = .hold) -> Arbitration {
        let verdict = requestMicrophone(requester)
        guard verdict.isGranted else { return verdict }
        // V5 O1 — a recorder opens its own subscription (`SharedMicrophoneSource`); it has no mode.
        if requester.isRecorder { return verdict }
        lock.withLock { requestedMode = mode == .idle ? .hold : mode }
        if mode == .latched, !dictation.latched { dictation.handle(.enterLatch) }
        if requester.dictates {
            latch?.sessionStarted()
            latch?.attach(dictation.engine)
            dictation.start()
        }
        return verdict
    }

    /// Stops and finalizes: the single tap in latch, the key release in hold.
    public func stop(_ requester: Requester = .hotkey, reason: StopReason = .userStopped) {
        if requester.isRecorder { return stopRecorder(requester, reason: reason) }
        guard lock.withLock({ holder == nil || holder == requester }) else { return }
        if dictation.latched { dictation.endLatch() }
        if requester.dictates { dictation.finalize() }
        release(requester)
        onStopped?(requester, reason)
    }

    /// Aborts without landing anything, and drops anything that had closed but not been delivered.
    public func cancel(_ requester: Requester = .hotkey, reason: StopReason = .userStopped) {
        if requester.isRecorder { return stopRecorder(requester, reason: reason) }
        guard lock.withLock({ holder == nil || holder == requester }) else { return }
        if dictation.latched { dictation.endLatch() }
        latch?.cancelPending(reason: reason.rawValue)
        if requester.dictates { dictation.cancel() }
        release(requester)
        onStopped?(requester, reason)
    }

    /// V5 O1 — a recorder ends on its own account; the utterance claim (and any dictation or latch
    /// it drives) is untouched.
    private func stopRecorder(_ requester: Requester, reason: StopReason) {
        guard lock.withLock({ recorders.remove(requester) }) != nil else { return }
        onStopped?(requester, reason)
    }

    /// Recorders stood down by hard mute, lock or sleep — the events that close the microphone for
    /// every subscriber. Returns them, cleared.
    private func takeRecorders() -> [Requester] {
        lock.withLock {
            let all = Requester.allCases.filter(recorders.contains)
            recorders.removeAll()
            return all
        }
    }

    /// The hotkey's gesture stream. This is the only place mode transitions happen for the hotkey.
    public func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startCapture:
            start(.hotkey, mode: dictation.latched ? .latched : .hold)
        case .finalize:
            stop(.hotkey, reason: .userStopped)
        case .cancelCapture:
            // A too-short press. Nothing was said; drop it, but a latched session (which this press
            // cannot have opened) keeps its mode — only `.finalize` and the events below end latch.
            latch?.cancelPending(reason: "cancelled")
            if dictation.latched { release(.hotkey) } else { cancel(.hotkey) }
        case .enterLatch:
            dictation.handle(.enterLatch)
            lock.withLock { holder = .hotkey; requestedMode = .latched }
            latch?.attach(dictation.engine)
        }
    }

    // MARK: Escape — V3 §4.3

    /// Escape: cancel the pending work, keep every character that is already in the field.
    ///
    /// Escape is not an undo. Nothing already inserted is retracted (the app never retracts
    /// committed text), and held text is left in the held queue, because deciding what happens to it
    /// is the user's — `Insert here` / `Copy` / `Discard`. What Escape drops is the work in flight:
    /// capture, and any segment that closed but has not been delivered.
    @discardableResult
    public func escape() -> Int {
        let dropped = latch?.cancelPending(reason: StopReason.escape.rawValue) ?? 0
        if dictation.latched { dictation.endLatch() }
        dictation.cancel()
        let holder = lock.withLock { () -> Requester? in
            let was = self.holder
            self.holder = nil
            requestedMode = .idle
            return was
        }
        onStopped?(holder ?? .hotkey, .escape)
        return dropped
    }

    // MARK: Hard mute — V3 §4.4

    /// Observes `MuteController` so hard mute stops every capture path through the one owner rather
    /// than through whichever collaborator happens to be listening.
    public func observeMute() {
        mute.observe { [weak self] model in
            guard let self else { return }
            if model.muted { self.muteEngaged() } else { self.muteReleased() }
        }
    }

    /// Hard mute: capture stops, pending insertion is cancelled, uncommitted audio is discarded, and
    /// the latch ends. Nothing auto-unmutes and nothing auto-resumes.
    public func muteEngaged() {
        latch?.cancelPending(reason: StopReason.muted.rawValue)
        dictation.setPaused(true)
        let holder = lock.withLock { () -> Requester? in
            let was = self.holder
            self.holder = nil
            requestedMode = .idle
            return was
        }
        if let holder, !holder.dictates { onStandDown?(holder) }
        for recorder in takeRecorders() {
            onStandDown?(recorder)
            onStopped?(recorder, .muted)
        }
        onStopped?(holder ?? .hotkey, .muted)
    }

    /// Unmuting only makes the microphone *available* again. It never starts a session.
    public func muteReleased() {
        dictation.setPaused(false)
    }

    // MARK: Lock and sleep — V3 §8

    public func screenDidLock() { stopForSystemEvent(.locked) }
    public func systemWillSleep() { stopForSystemEvent(.slept) }

    /// Waking up, and unlocking, are explicitly *not* a resume. The flag they clear is the one that
    /// tells the surfaces why nothing is listening.
    public func systemDidWake() { /* nothing: `awaitingRestart` stays set until an explicit start */ }
    public func screenDidUnlock() { /* same */ }

    private func stopForSystemEvent(_ reason: StopReason) {
        latch?.cancelPending(reason: reason.rawValue)
        if dictation.latched { dictation.endLatch() }
        dictation.cancel()
        let holder = lock.withLock { () -> Requester? in
            let was = self.holder
            self.holder = nil
            requestedMode = .idle
            awaitingRestart = true
            return was
        }
        if let holder, !holder.dictates { onStandDown?(holder) }
        for recorder in takeRecorders() {
            onStandDown?(recorder)
            onStopped?(recorder, reason)
        }
        Log.app.notice("session: capture stopped (\(reason.rawValue)); it will not resume on its own")
        onStopped?(holder ?? .hotkey, reason)
    }

    /// Registers the workspace notifications that carry lock and sleep. Kept out of `init` so tests
    /// (and any headless run) never touch `NSWorkspace`.
    ///
    /// B2 — and binds the latch pause to `latchSettings`, the app's own settings store by default
    /// (`UserDefaults`, which is what `AppContainer.settings` is), for the same reason: a test's
    /// latch keeps the endpointer it was given unless it binds a store itself.
    public func observeSystemEvents(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                                    distributed: Bool = true,
                                    latchSettings: SettingsStore? = UserDefaultsSettingsStore()) {
        if let latchSettings { bindLatchSettings(latchSettings) }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        }
        guard distributed else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenDidLock()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenDidUnlock()
        }
    }

    // MARK: Focus changes — V3 §8

    /// Focus moved while latched. Delivery pauses and committed text is held, named for where it was
    /// going; returning to the app is not consent to type into it. Outside latch this is a no-op:
    /// hold mode already snapshots focus at key release and `FocusGuard` refuses the insertion.
    public func focusChanged(to destination: String?) {
        guard dictation.latched, let latch else { return }
        latch.pauseDelivery(awaiting: destination)
        Log.app.notice("session: focus changed while latched; delivery is paused until a target is named")
    }

    /// The user named where the held text goes. Returns how many items were inserted.
    @discardableResult
    public func resumeDelivery(into target: String) -> Int {
        latch?.resumeDelivery(into: target) ?? 0
    }
}
