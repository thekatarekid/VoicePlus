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
    public let embedder: any SpeakerEmbedder
    public var speakerGate: SpeakerGate
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
    public private(set) var lastRejection: String?
    /// R3.3 — has the user asked for speaker filtering? **Off until asked**, and enrolling a voice
    /// does not turn it on: V3 §8 has the dependency the other way round ("enrollment is requested
    /// when enabling speaker filtering"), and a setting the user never chose must not start
    /// suppressing their dictation. The Settings toggle that writes this belongs to the settings
    /// item; this is where the policy reads it.
    ///
    /// With it off, `SpeakerGate` behaves exactly as it did before R3.3. With it on, an uncertain
    /// result and an absent embedding model both suppress — see `SpeakerFilter`.
    public var speakerFilteringEnabled = false
    /// The filter as it stands right now: the gate, plus whether the loaded embedder can identify a
    /// speaker at all. On a machine with no WeSpeaker weights that answer is no, and the status is
    /// `.modelUnavailable` — which suppresses insertion and says so, rather than implying a check.
    public var speakerFilter: SpeakerFilter {
        SpeakerFilter(isOn: speakerFilteringEnabled, gate: speakerGate, embedder: embedder)
    }
    /// The honest sentence for the current filter state, or nil when there is nothing to say.
    public var speakerFilterMessage: String? { speakerFilter.status.message }
    let lock = NSLock()
    var claimed = false

    public init(flags: FeatureFlagService,
                mute: MuteController = MuteController(store: UserDefaultsMuteStore()),
                detector: DirectedSpeechDetector = DirectedSpeechDetector(),
                embedder: (any SpeakerEmbedder)? = nil,
                profiles: SpeakerProfileStore = SpeakerProfileStore()) {
        self.flags = flags
        self.mute = mute
        self.detector = detector
        let emb = embedder ?? SpeakerEmbedderFactory.make()
        self.embedder = emb
        self.profiles = profiles
        self.speakerGate = SpeakerGate(profile: profiles.profile, threshold: SpeakerGate.defaultThreshold(for: emb))
        self.notYouCorrection = NotYouCorrection(teacher: DetectorTeacher(detector: detector), profile: profiles)
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
    public func markNotYou() {
        if notYouCorrection.notYou() == nil { detector.markNotYou() }
    }

    public func markWasMe() { detector.markWasMe() }

    /// Enrollment finished (onboarding-2): persist + arm the gate. Deliberately does **not** turn
    /// `speakerFilteringEnabled` on — enrolling a voice is not the same as asking for every other
    /// voice to be suppressed, and on a machine with no embedding weights that would silence
    /// dictation outright.
    public func install(profile: SpeakerProfile) {
        profiles.save(profile)
        speakerGate.profile = profile
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
    private let lock = NSLock()
    private var cached: SpeakerProfile??

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory().appendingPathComponent("speaker-profile.json")
    }

    public var profile: SpeakerProfile? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = try? SpeakerProfile.load(from: url)
        cached = .some(loaded)
        return loaded
    }

    public func save(_ profile: SpeakerProfile) {
        lock.lock(); defer { lock.unlock() }
        cached = .some(profile)
        do { try profile.save(to: url) } catch { Log.app.error("speaker profile save failed: \(error)") }
    }

    /// R7.2 — Voice › Enrollment offers Delete (`DESIGN.md` §9.4). Removing the file is the whole
    /// of it: the next `profile` read misses the cache and finds nothing.
    public func delete() {
        lock.lock(); defer { lock.unlock() }
        cached = .some(nil)
        try? FileManager.default.removeItem(at: url)
    }

    public func addNegative(_ e: SpeakerEmbedding) {
        guard var p = profile else { return }
        p.addNegative(e)
        save(p)
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
        markNotYou()
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
