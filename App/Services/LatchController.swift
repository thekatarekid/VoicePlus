import Engine
import Foundation
import Pipeline
import Shared

/// P5 integration, R3.1 vocabulary — the **latch** gate: `DirectedSpeechDetector` (RAM-only ring)
/// decides whether speech was addressed to the machine, `SpeakerFilter` decides whether it may be
/// inserted, the hard mute wins over everything, and "not you" teaches both.
///
/// Audio flows in through `appendAudio` + `handle(_:)` (VAD events); when a speech segment ends
/// and every gate passes, `onShouldCapture` fires — that is what starts the engine while latched.
/// Nothing here persists audio.
public final class LatchController: @unchecked Sendable {
    public let detector: DirectedSpeechDetector
    /// The speaker embedder. WeSpeaker when its weights are on disk (H3), else the MFCC fallback,
    /// which cannot identify anyone ("Voice filtering unavailable"). A factory-chosen fallback is
    /// replaced by WeSpeaker the first time the weights are found after launch
    /// (`refreshEmbedderIfWeightsArrived`); an injected embedder is never replaced.
    public var embedder: any SpeakerEmbedder { speakerLock.withLock { _embedder } }
    public var speakerGate: SpeakerGate {
        get { speakerLock.withLock { _speakerGate } }
        set { speakerLock.withLock { _speakerGate = newValue } }
    }
    public let mute: MuteController
    public let flags: FeatureFlagService
    public let profiles: SpeakerProfileStore
    public private(set) var notYouCorrection: NotYouCorrection!

    /// The app answers "is the latch on right now?" (double-tap state).
    public var isLatched: () -> Bool = { false }
    /// Fires when a directed, user-voiced segment ends → start capture.
    public var onShouldCapture: ((DirectedSpeechDecision) -> Void)?
    /// Last reason a segment was dropped ("muted" / "not directed" / a
    /// `SpeakerFilter.SuppressionReason`) — pill/debug.
    public private(set) var lastRejection: String? {
        get { speakerLock.withLock { _lastRejection } }
        set { speakerLock.withLock { _lastRejection = newValue } }
    }
    /// Is speaker filtering on? R3.3 kept it off until asked; V4 §12.5 (H2) makes enrolling the ask:
    /// `install(profile:)` turns it on, and a launch with an enrolled voice starts with it on — but
    /// only when the embedder can actually identify a speaker and the profile was built by it.
    /// With the MFCC fallback it stays off (X03: "Hold-to-talk still works; speaker filtering stays
    /// off") rather than suppress every latch segment as "Voice filtering unavailable".
    ///
    /// With it off, `SpeakerGate` behaves exactly as it did before R3.3. With it on, an uncertain
    /// result and an absent embedding model both suppress — see `SpeakerFilter`. It only ever
    /// applies to latch segments: a hold is the user by definition (`insertionDecision(for:samples:)`).
    /// Setting it assigns or clears `LatchRuntime.speakerGuard` on an attached runtime.
    public var speakerFilteringEnabled: Bool {
        get { speakerLock.withLock { _speakerFilteringEnabled } }
        set {
            speakerLock.withLock { _speakerFilteringEnabled = newValue }
            syncSpeakerGuard()
        }
    }
    /// The filter as it stands right now: the gate, plus whether the loaded embedder can identify a
    /// speaker at all. On a machine with no WeSpeaker weights that answer is no, and the status is
    /// `.modelUnavailable` — which suppresses insertion and says so, rather than implying a check.
    public var speakerFilter: SpeakerFilter {
        speakerLock.withLock {
            SpeakerFilter(isOn: _speakerFilteringEnabled, gate: _speakerGate, embedder: _embedder)
        }
    }
    /// The honest sentence for the current filter state, or nil when there is nothing to say.
    public var speakerFilterMessage: String? { speakerFilter.status.message }
    let lock = NSLock()
    var claimed = false

    /// H2 — the tenth qualifying hold built the voice profile (V4.49). Fires once; the pill says
    /// `LatchController.voiceLearnedMessage` ("Voice learned").
    public var onVoiceLearned: ((SpeakerProfile) -> Void)?

    // H2/H3 state, behind its own lock: the latch guard asks from the runtime's task, holds are
    // observed off the main thread, and install/"Not you" arrive from the main thread.
    let speakerLock = NSLock()
    private var _embedder: any SpeakerEmbedder
    /// True when the factory chose the embedder: a fallback chosen that way may be upgraded once the
    /// weights land. An injected embedder is the caller's decision and is kept.
    var allowsEmbedderRefresh: Bool
    private var _speakerGate: SpeakerGate
    private var _speakerFilteringEnabled = false
    private var _lastRejection: String?
    private var passive: SpeakerEnrollment
    private weak var runtime: LatchRuntime?
    private var segmentAudio: (() -> [Float]?)?

    public init(flags: FeatureFlagService,
                mute: MuteController = MuteController(store: UserDefaultsMuteStore()),
                detector: DirectedSpeechDetector = DirectedSpeechDetector(),
                embedder: (any SpeakerEmbedder)? = nil,
                profiles: SpeakerProfileStore = SpeakerProfileStore()) {
        self.flags = flags
        self.mute = mute
        self.detector = detector
        let emb = embedder ?? SpeakerEmbedderFactory.make()
        self._embedder = emb
        self.allowsEmbedderRefresh = embedder == nil
        self.profiles = profiles
        let profile = profiles.profile
        self._speakerGate = SpeakerGate(profile: profile, threshold: SpeakerGate.defaultThreshold(for: emb))
        self._speakerFilteringEnabled = profile.map { Self.canFilter(with: emb, profile: $0) } ?? false
        self.passive = profiles.passiveEnrollment ?? SpeakerEnrollment(mode: .passive)
        self.notYouCorrection = NotYouCorrection(teacher: DetectorTeacher(detector: detector), profile: profiles)
        profiles.onChange = { [weak self] profile in self?.profileDidChange(profile) }
    }

    /// Experimental flag (P5.1 ship bar) — off by default until the recorded-corpus soak passes.
    public var isEnabled: Bool { flags.isEnabled(.directedSpeech) }

    public func appendAudio(_ samples: [Float]) { detector.appendAudio(samples) }

    /// Streaming preview + focus context feed the classifier's content features.
    public func update(preview: String) { detector.preview = preview }
    public func update(context: DirectedSpeechContext) { detector.context = context }

    /// One VAD event. Returns true when this event triggered a capture.
    @discardableResult
    public func handle(_ event: VADEvent, utteranceSamples: [Float]? = nil) -> Bool {
        let preview = detector.preview
        guard let decision = detector.handle(event) else { return false }
        guard isEnabled, isLatched() else { return false }
        guard !mute.isMuted else { lastRejection = "muted"; return false }
        guard decision.directed else { lastRejection = "not directed"; return false }
        var embedding: SpeakerEmbedding?
        // R3.3 — with filtering on, a mismatch *and* an uncertain result suppress the utterance, and
        // an absent embedding model suppresses it with an honest reason instead of a claim. With
        // filtering off the gate keeps its old, permissive behaviour.
        let filter = speakerFilter
        if filter.isOn {
            let samples = utteranceSamples ?? detector.ring.samples(in: decision.utterance)
            if case .suppress(let reason) = filter.decide(samples: samples, embedder: embedder) {
                lastRejection = reason.rawValue
                Log.app.notice("latch: dropped a segment — \(reason.rawValue)")
                return false
            }
            embedding = try? embedder.embed(samples)
        } else if speakerGate.profile != nil {
            let samples = utteranceSamples ?? detector.ring.samples(in: decision.utterance)
            let verdict = speakerGate.verdict(for: samples, embedder: embedder)
            guard speakerGate.shouldAccept(verdict, latched: true) else {
                lastRejection = "speaker"
                return false
            }
            embedding = try? embedder.embed(samples)
        }
        lastRejection = nil
        notYouCorrection.didTrigger(PendingTrigger(text: preview, embedding: embedding))
        mute.acknowledgeDirected()
        onShouldCapture?(decision)
        return true
    }

    /// "not you" — one negative online update on the classifier + the speaker profile.
    /// The correction routes through `NotYouCorrection` (whose teacher updates the detector);
    /// with no pending trigger in the window, the detector still learns from its last decision.
    ///
    /// H2 — `.notMe` (the default: the pill's "Not you" is about the voice) also reaches the
    /// profile: the rejected voice becomes a negative and the threshold is lifted just past its
    /// similarity (`SpeakerProfile.noteNotYou`), live, through the store's change hook.
    public func markNotYou(reason: DirectedSpeechExample.Reason = .notMe) {
        if notYouCorrection.notYou(reason: reason) == nil { detector.markNotYou() }
    }

    public func markWasMe() { detector.markWasMe() }

    /// Enrollment finished — prompted (onboarding-2, Voice) or passive (H2): persist, arm the gate,
    /// and turn speaker filtering on, which assigns `LatchRuntime.speakerGuard` on an attached
    /// runtime. Filtering applies to latch segments only.
    ///
    /// Only when identification is possible: with the MFCC fallback (or a profile some other
    /// embedder built) filtering stays off and the answer is X03 — "Hold-to-talk still works;
    /// speaker filtering stays off" — instead of suppressing every latch segment as unidentifiable.
    @discardableResult
    public func install(profile: SpeakerProfile) -> SpeakerInstallOutcome {
        profiles.save(profile)
        profiles.clearPassiveEnrollment()
        let identifying = speakerLock.withLock { () -> Bool in
            _speakerGate.profile = profile
            passive = SpeakerEnrollment(mode: .passive)
            return Self.canFilter(with: _embedder, profile: profile)
        }
        guard identifying else {
            Log.app.notice("speaker: voice saved, but \(SpeakerFilter.unavailableLabel) — filtering stays off (X03)")
            speakerFilteringEnabled = false
            return .filteringUnavailable(SpeakerFilter.unavailableRecovery)
        }
        speakerFilteringEnabled = true
        return .filtering
    }

    /// Menu-bar / notch glyph from the ambient model, muted badge included.
    public var ambientModel: AmbientStateModel { mute.model }
}

/// `DirectedSpeechTeacher` → the detector's online SGD step.
final class DetectorTeacher: DirectedSpeechTeacher, @unchecked Sendable {
    let detector: DirectedSpeechDetector
    init(detector: DirectedSpeechDetector) { self.detector = detector }
    func learn(_ example: DirectedSpeechExample) {
        example.label == .directed ? detector.markWasMe() : detector.markNotYou()
    }
}

/// Speaker profile persistence (JSON under Application Support) + negative/reinforce updates.
public final class SpeakerProfileStore: SpeakerProfileUpdating, @unchecked Sendable {
    private let url: URL
    /// H2 — a passive enrollment in progress (embeddings only), beside the profile:
    /// `speaker-profile.json` → `speaker-profile.passive.json`.
    private let passiveURL: URL
    private let lock = NSLock()
    private var cached: SpeakerProfile??
    /// Called after every save or delete, with the profile as it now stands. `LatchController`
    /// uses it so a "Not you" correction reaches the live gate, not just the file.
    public var onChange: ((SpeakerProfile?) -> Void)?

    public init(url: URL? = nil) {
        let url = url ?? AppPaths.supportDirectory().appendingPathComponent("speaker-profile.json")
        self.url = url
        self.passiveURL = url.deletingPathExtension().appendingPathExtension("passive.json")
    }

    public var profile: SpeakerProfile? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = try? SpeakerProfile.load(from: url)
        cached = .some(loaded)
        return loaded
    }

    public func save(_ profile: SpeakerProfile) {
        lock.withLock {
            cached = .some(profile)
            do { try profile.save(to: url) } catch { Log.app.error("speaker profile save failed: \(error)") }
        }
        onChange?(profile)
    }

    /// R7.2 — Voice › Enrollment offers Delete (`DESIGN.md` §9.4). Removing the file is the whole
    /// of it: the next `profile` read misses the cache and finds nothing. A passive enrollment in
    /// progress goes with it — deleting the voice means VoicePlus stops learning it.
    public func delete() {
        lock.withLock {
            cached = .some(nil)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: passiveURL)
        }
        onChange?(nil)
    }

    /// "Not you" (`NotYouCorrection`, reason `.notMe`): the voice becomes a negative *and* lifts the
    /// threshold just past its similarity (H2).
    public func addNegative(_ e: SpeakerEmbedding) {
        guard var p = profile else { return }
        p.noteNotYou(e)
        save(p)
    }

    // MARK: Passive enrollment progress (H2)

    /// The passive enrollment saved by the last `savePassiveEnrollment`, if any.
    public var passiveEnrollment: SpeakerEnrollment? {
        lock.withLock {
            guard let data = try? Data(contentsOf: passiveURL) else { return nil }
            return try? JSONDecoder().decode(SpeakerEnrollment.self, from: data)
        }
    }

    public func savePassiveEnrollment(_ enrollment: SpeakerEnrollment) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: passiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(enrollment).write(to: passiveURL, options: .atomic)
            } catch {
                Log.app.error("speaker: passive enrollment save failed: \(error)")
            }
        }
    }

    public func clearPassiveEnrollment() {
        lock.withLock { try? FileManager.default.removeItem(at: passiveURL) }
    }

    public func reinforce(_ e: SpeakerEmbedding) {
        guard var p = profile else { return }
        p.reinforce(e)
        save(p)
    }
}

/// P5.4 — "not you" spoken correction, claimed by the gatekeeper only while latched so it is never
/// typed. Shares the lander's claim-consumer mechanism with the act hook.
extension LatchController: GatekeeperPreRouting {
    static let notYouPhrases: Set<String> = ["not you", "not me", "that wasn't me", "that was not me", "wasn't talking to you"]

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard WakeVerbPreRoute.isLatched(context) else { return nil }
        let norm = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard Self.notYouPhrases.contains(norm) else { return nil }
        markNotYou(reason: Self.notYouReason(for: norm, filteringActive: speakerFilter.status == .active))
        lock.lock(); claimed = true; lock.unlock()
        return GatekeeperDecision(route: .none, register: context.register, routeConfidence: 1,
                                  registerConfidence: 0, routeSource: .rules, registerSource: .fallback)
    }

    public func consumeClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = claimed
        claimed = false
        return was
    }
}

// MARK: - H2/H3 — passive enrollment and the latch speaker filter

/// What `LatchController.install(profile:)` did with a finished enrollment.
public enum SpeakerInstallOutcome: Equatable, Sendable {
    /// Saved, and speaker filtering is on for latch segments.
    case filtering
    /// Saved, but the loaded embedder cannot tell voices apart (the MFCC fallback), so filtering
    /// stays off. The recovery is X03: "Couldn’t finish voice setup" — hold-to-talk still works.
    case filteringUnavailable(RecoveryID)
}

/// What one hold-to-talk utterance did for passive enrollment (V4.49). Never a verdict on the
/// hold itself: a hold always lands.
public enum PassiveEnrollmentResult: Equatable, Sendable {
    /// A usable voice is already enrolled; nothing to learn.
    case alreadyEnrolled
    /// No embedder that can identify a speaker ("Voice filtering unavailable"); nothing learned,
    /// and the embedder was not run.
    case unavailable
    /// Under `SpeakerEnrollment.minimumHoldSpeechSeconds` of VAD speech; not embedded.
    case tooShort(speechSeconds: TimeInterval)
    /// The embedder produced nothing for this audio.
    case couldNotEmbed
    /// Did not sound like the holds learned so far; not averaged in.
    case inconsistent(similarity: Float)
    /// Learned: `n` of `SpeakerEnrollment.passiveUtterances`.
    case learned(Int)
    /// The last one: the profile is built and installed. Shown once as "Voice learned".
    case voiceLearned(SpeakerProfile)
}

extension LatchController {
    /// Where an utterance came from, for the speaker filter.
    public enum UtteranceSource: Equatable, Sendable {
        /// Hold-to-talk: the user pressed the key, so it is the user. Never filtered.
        case hold
        /// A latch segment closed by an endpoint: whoever was speaking. Filtered while filtering is on.
        case latchSegment
    }

    /// The pill's one-time notice when passive enrollment finishes (V4.49).
    public static let voiceLearnedMessage = "Voice learned"

    /// Filtering needs an embedder that identifies speakers *and* a profile that embedder built —
    /// an MFCC profile's Gaussian summary means nothing to WeSpeaker's cosine space.
    static func canFilter(with embedder: any SpeakerEmbedder, profile: SpeakerProfile) -> Bool {
        embedder.identifiesSpeakers && profile.centroid.embedder == embedder.name
    }

    /// Is a voice enrolled that the current embedder can filter with?
    public var hasEnrolledVoice: Bool {
        speakerLock.withLock { _speakerGate.profile.map { Self.canFilter(with: _embedder, profile: $0) } ?? false }
    }

    /// H3 — can voice filtering work at all right now? `.unavailable("Voice filtering unavailable",
    /// X03)` while the MFCC fallback is loaded. Settings › Models and Voice show this.
    public var voiceFilterAvailability: SpeakerFilter.Availability { SpeakerFilter.availability(of: embedder) }

    /// H2 — the passive enrollment in progress ("learning N of 10": `learnedCount`, `progress`).
    public var passiveEnrollment: SpeakerEnrollment { speakerLock.withLock { passive } }

    // MARK: Passive enrollment (V4.49)

    /// One finished hold-to-talk utterance: its 16 kHz samples and how many seconds of it the VAD
    /// called speech. Until a voice is enrolled, each hold with ≥ 1.5 s of speech is embedded and
    /// learned; the tenth builds the profile, `install(profile:)` turns filtering on for latch
    /// segments, and `onVoiceLearned` fires once. Progress survives relaunches (embeddings only).
    ///
    /// The hold is never filtered, delayed or refused by this — it is the user by definition.
    /// Runs the embedder on the calling thread (a CoreML call): call it off the main thread.
    @discardableResult
    public func observeHoldUtterance(samples: [Float], speechSeconds: TimeInterval) -> PassiveEnrollmentResult {
        refreshEmbedderIfWeightsArrived()
        let embedder = self.embedder
        guard !hasEnrolledVoice else { return .alreadyEnrolled }
        // Never run a backend that cannot identify anyone: an MFCC profile could not be used for
        // filtering anyway (X03 — filtering stays off).
        guard embedder.identifiesSpeakers else { return .unavailable }
        guard SpeakerEnrollment.holdQualifies(speechSeconds: speechSeconds) else {
            return .tooShort(speechSeconds: speechSeconds)
        }
        guard !samples.isEmpty, let embedding = try? embedder.embed(samples) else { return .couldNotEmbed }
        let (outcome, snapshot) = speakerLock.withLock { () -> (SpeakerEnrollment.HoldOutcome, SpeakerEnrollment) in
            // Another hold may have finished enrollment while this one was being embedded.
            if let p = _speakerGate.profile, Self.canFilter(with: _embedder, profile: p) { return (.alreadyComplete, passive) }
            return (passive.recordHold(embedding, speechSeconds: speechSeconds), passive)
        }
        switch outcome {
        case .alreadyComplete:
            return .alreadyEnrolled
        case .tooShort(let seconds):
            return .tooShort(speechSeconds: seconds)
        case .inconsistent(let similarity):
            return .inconsistent(similarity: similarity)
        case .learned(let n):
            profiles.savePassiveEnrollment(snapshot)
            return .learned(n)
        case .complete(let profile):
            install(profile: profile)
            Log.app.notice("speaker: \(Self.voiceLearnedMessage) from \(SpeakerEnrollment.passiveUtterances) holds")
            onVoiceLearned?(profile)
            return .voiceLearned(profile)
        }
    }

    /// H3 — the weights may land after launch (they download with the speech stack). A fallback the
    /// factory chose is swapped for WeSpeaker the first time they are found; true when it was.
    @discardableResult
    public func refreshEmbedderIfWeightsArrived(
        locate: () -> URL? = { SpeakerEmbedderFactory.locateModel() },
        load: (URL) -> (any SpeakerEmbedder)? = { FluidSpeakerEmbedder.load(from: $0) }
    ) -> Bool {
        let stale = speakerLock.withLock { allowsEmbedderRefresh && !_embedder.identifiesSpeakers }
        guard stale, let directory = locate(), let loaded = load(directory), loaded.identifiesSpeakers else { return false }
        let filter = speakerLock.withLock { () -> Bool in
            _embedder = loaded
            _speakerGate.threshold = SpeakerGate.defaultThreshold(for: loaded)
            return _speakerGate.profile.map { Self.canFilter(with: loaded, profile: $0) } ?? false
        }
        Log.app.notice("speaker: WeSpeaker weights found at \(directory.path) — voice filtering available")
        if filter { speakerFilteringEnabled = true }
        return true
    }

    // MARK: The filter — latch segments only

    /// The insertion decision for one utterance. A hold is always allowed without running the
    /// embedder; a latch segment goes through the speaker filter.
    public func insertionDecision(for source: UtteranceSource, samples: [Float]) -> SpeakerFilter.Decision {
        switch source {
        case .hold: return .allow(similarity: nil)
        case .latchSegment: return decideLatchSegment(samples: samples)
        }
    }

    /// Hand the runtime this controller's speaker guard. `segmentAudio` answers "the audio of the
    /// segment that just closed" — `LatchSegmentAudio.take` over the capture stream is the intended
    /// source; nil or empty is an uncertain result, which suppresses while filtering is on
    /// (V3 §8: uncertain is not yes). The guard is assigned while filtering is on and cleared while
    /// it is off (`LatchRuntime.speakerGuard == nil` means no filter configured).
    public func attach(runtime: LatchRuntime, segmentAudio: @escaping () -> [Float]?) {
        speakerLock.withLock {
            self.runtime = runtime
            self.segmentAudio = segmentAudio
        }
        syncSpeakerGuard()
    }

    /// What the attached runtime's guard answers for the segment that just closed.
    public func latchSegmentDecision() -> SpeakerFilter.Decision {
        let audio = speakerLock.withLock { segmentAudio }
        return decideLatchSegment(samples: audio?() ?? [])
    }

    func syncSpeakerGuard() {
        let (runtime, on) = speakerLock.withLock { (self.runtime, _speakerFilteringEnabled) }
        guard let runtime else { return }
        runtime.speakerGuard = on ? { [weak self] in self?.latchSegmentDecision() ?? .allow(similarity: nil) } : nil
    }

    func decideLatchSegment(samples: [Float]) -> SpeakerFilter.Decision {
        let filter = speakerFilter
        // Off: allow. Unavailable / not enrolled: the honest refusal, without running the embedder.
        guard filter.status == .active else {
            let decision = filter.decide(.unknown)
            if let reason = decision.suppression { lastRejection = reason.rawValue }
            return decision
        }
        let embedder = self.embedder
        let embedding = samples.isEmpty ? nil : try? embedder.embed(samples)
        let decision = filter.decide(embedding.map { filter.gate.verdict(for: $0) } ?? .unknown)
        if let reason = decision.suppression {
            lastRejection = reason.rawValue
            Log.app.notice("latch: speaker filter suppressed a segment — \(reason.rawValue)")
        } else if let embedding {
            lastRejection = nil
            // So a "Not you" right after this segment knows which voice to learn from.
            notYouCorrection.didTrigger(PendingTrigger(text: "", embedding: embedding))
        }
        return decision
    }

    // MARK: Profile changes and "Not you"

    func profileDidChange(_ profile: SpeakerProfile?) {
        speakerLock.withLock {
            _speakerGate.profile = profile
            if profile == nil { passive = SpeakerEnrollment(mode: .passive) }
        }
        // Deleting the voice ends filtering: there is nothing left to compare with.
        if profile == nil, speakerFilteringEnabled { speakerFilteringEnabled = false }
    }

    /// Which correction a spoken phrase is. "not me" / "that wasn't me" are about the voice.
    /// "not you" is about the voice while filtering is active (the latch let someone else through),
    /// and about addressing otherwise. "wasn't talking to you" is always about addressing.
    static func notYouReason(for phrase: String, filteringActive: Bool) -> DirectedSpeechExample.Reason {
        switch phrase {
        case "not me", "that wasn't me", "that was not me": return .notMe
        case "not you": return filteringActive ? .notMe : .notTalkingToYou
        default: return .notTalkingToYou
        }
    }
}

/// The audio of the latch segment that just closed, for the speaker guard (H2). Append the capture
/// stream as it arrives; `take()` hands over everything since the previous take and starts over.
/// The runtime asks once per closed segment, after its final pass, so a take is that segment plus
/// the pause that closed it (and, at worst, the first moments of the next one) — enough for an
/// embedding, which needs a voice, not exact boundaries. Bounded; RAM only; nothing is stored.
public final class LatchSegmentAudio: @unchecked Sendable {
    public let maxSamples: Int
    private let lock = NSLock()
    private var buffer: [Float] = []

    public init(maxSeconds: TimeInterval = 30) { maxSamples = Int(maxSeconds * 16_000) }

    public func append(_ samples: [Float]) {
        lock.withLock {
            buffer.append(contentsOf: samples)
            if buffer.count > maxSamples { buffer.removeFirst(buffer.count - maxSamples) }
        }
    }

    /// Everything since the last take, or nil when nothing arrived.
    public func take() -> [Float]? {
        lock.withLock {
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
    }

    public func reset() { lock.withLock { buffer.removeAll() } }
}
