import Engine
import Foundation
import Pipeline
import Shared

/// P5 integration — hands-free gate: `DirectedSpeechDetector` (RAM-only ring) decides whether
/// speech was addressed to the machine, `SpeakerGate` rejects other voices, the hard mute wins
/// over everything, and "not you" teaches both.
///
/// Audio flows in through `appendAudio` + `handle(_:)` (VAD events); when a speech segment ends
/// and every gate passes, `onShouldCapture` fires — that is what starts the engine in hands-free
/// mode. Nothing here persists audio.
public final class HandsFreeController: @unchecked Sendable {
    public let detector: DirectedSpeechDetector
    public let embedder: any SpeakerEmbedder
    public var speakerGate: SpeakerGate
    public let mute: MuteController
    public let flags: FeatureFlagService
    public let profiles: SpeakerProfileStore
    public private(set) var notYouCorrection: NotYouCorrection!

    /// The app answers "is hands-free mode on right now?" (double-tap state).
    public var isHandsFree: () -> Bool = { false }
    /// Fires when a directed, user-voiced segment ends → start capture.
    public var onShouldCapture: ((DirectedSpeechDecision) -> Void)?
    /// Last reason a segment was dropped ("muted" / "not directed" / "speaker") — pill/debug.
    public private(set) var lastRejection: String?
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
        guard isEnabled, isHandsFree() else { return false }
        guard !mute.isMuted else { lastRejection = "muted"; return false }
        guard decision.directed else { lastRejection = "not directed"; return false }
        var embedding: SpeakerEmbedding?
        if speakerGate.profile != nil {
            let samples = utteranceSamples ?? detector.ring.samples(in: decision.utterance)
            let verdict = speakerGate.verdict(for: samples, embedder: embedder)
            guard speakerGate.shouldAccept(verdict, handsFree: true) else {
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

    /// Enrollment finished (onboarding-2): persist + arm the gate.
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

/// P5.4 — "not you" spoken correction, claimed by the gatekeeper only in hands-free mode so it
/// is never typed. Shares the lander's claim-consumer mechanism with the act hook.
extension HandsFreeController: GatekeeperPreRouting {
    static let notYouPhrases: Set<String> = ["not you", "not me", "that wasn't me", "that was not me", "wasn't talking to you"]

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard WakeVerbPreRoute.isHandsFree(context) else { return nil }
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
