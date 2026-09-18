import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H2 (V4.49) at the controller: holds build the voice, enrolling turns filtering on and arms the
/// latch runtime's guard, the filter only ever looks at latch segments, and "Not you" lifts the
/// threshold. Voices are synthetic: the first sample of a clip is an angle θ and the scripted
/// embedder returns (cos θ, sin θ), so similarity is cos(Δθ). No microphone, no CoreML.
@Suite("H2 — passive enrollment and the latch speaker guard")
struct PassiveEnrollmentLatchTests {
    /// An identifying cosine embedder whose output is readable off the clip.
    final class ScriptedEmbedder: SpeakerEmbedder, @unchecked Sendable {
        let name: String
        let dimension = 2
        let identifiesSpeakers: Bool
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        init(name: String = "test-wespeaker", identifies: Bool = true) {
            self.name = name; self.identifiesSpeakers = identifies
        }
        func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
            lock.withLock { _calls += 1 }
            guard let theta = samples.first else { throw SpeakerError.tooShort(samples: 0) }
            return SpeakerEmbedding(vector: [cos(theta), sin(theta)], embedder: name, metric: .cosine)
        }
    }

    /// The runtime only needs a delivery to exist; these tests ask its guard directly.
    final class NullDelivery: LatchDelivering, @unchecked Sendable {
        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool { true }
        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String { "" }
        func insertHeld(into target: String) -> Int { 0 }
    }

    static func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("h2-profile-\(UUID().uuidString).json")
    }

    static func controller(_ embedder: any SpeakerEmbedder = ScriptedEmbedder(),
                           url: URL = storeURL()) -> LatchController {
        LatchController(flags: FeatureFlagService.inMemory([:]),
                        mute: MuteController(store: InMemoryMuteStore()),
                        embedder: embedder,
                        profiles: SpeakerProfileStore(url: url))
    }

    /// Two seconds of "voice θ".
    static func clip(_ theta: Float) -> [Float] { [theta] + [Float](repeating: 0.01, count: 31_999) }

    /// Ten qualifying holds of the user (θ ≈ 0).
    @discardableResult
    static func enroll(_ controller: LatchController) -> [PassiveEnrollmentResult] {
        (0..<10).map { controller.observeHoldUtterance(samples: clip(Float($0 % 2) * 0.05), speechSeconds: 2) }
    }

    // MARK: Ten holds → a voice, and filtering on

    @Test("ten holds with ≥ 1.5 s of speech learn the voice; filtering turns on; the pill hears once")
    func tenHoldsLearnTheVoice() throws {
        let controller = Self.controller()
        var learned: [SpeakerProfile] = []
        controller.onVoiceLearned = { learned.append($0) }
        #expect(!controller.speakerFilteringEnabled)
        #expect(controller.passiveEnrollment.learnedCount == 0)

        // Short holds ("send it") do not count and are not embedded.
        #expect(controller.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 0.8) == .tooShort(speechSeconds: 0.8))
        #expect(controller.passiveEnrollment.learnedCount == 0)

        let results = Self.enroll(controller)
        #expect(Array(results.prefix(9)) == (1...9).map(PassiveEnrollmentResult.learned))
        guard case .voiceLearned(let profile) = results[9] else {
            Issue.record("the tenth hold must learn the voice, got \(results[9])"); return
        }
        #expect(profile.utteranceCount == 10)
        #expect(learned.count == 1, "\"Voice learned\" is said once")
        #expect(LatchController.voiceLearnedMessage == "Voice learned")
        #expect(controller.speakerFilteringEnabled)
        #expect(controller.hasEnrolledVoice)
        #expect(controller.speakerFilter.status == .active)
        #expect(controller.profiles.profile == profile, "persisted")
        #expect(controller.profiles.passiveEnrollment == nil, "progress is cleared once the voice is learned")

        // Nothing more to learn, and nothing said twice.
        #expect(controller.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 3) == .alreadyEnrolled)
        #expect(learned.count == 1)
    }

    @Test("progress survives a relaunch")
    func progressSurvivesRelaunch() {
        let url = Self.storeURL()
        let first = Self.controller(url: url)
        for i in 0..<4 { first.observeHoldUtterance(samples: Self.clip(Float(i) * 0.01), speechSeconds: 2) }
        #expect(first.passiveEnrollment.learnedCount == 4)

        let relaunched = Self.controller(url: url)
        #expect(relaunched.passiveEnrollment.learnedCount == 4)
        #expect(abs(relaunched.passiveEnrollment.progress - 0.4) < 1e-9)
        for i in 0..<5 { relaunched.observeHoldUtterance(samples: Self.clip(Float(i) * 0.01), speechSeconds: 2) }
        guard case .voiceLearned = relaunched.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2) else {
            Issue.record("holds from before the relaunch must count toward the ten"); return
        }
    }

    // MARK: MFCC — "Voice filtering unavailable", filtering stays off (X03)

    @Test("the fallback learns nothing, runs no embedder, and enrolling keeps filtering off (X03)")
    func fallbackKeepsFilteringOff() throws {
        let fallback = ScriptedEmbedder(name: "mfcc-mean", identifies: false)
        let controller = Self.controller(fallback)
        #expect(controller.voiceFilterAvailability == .unavailable(label: "Voice filtering unavailable", recovery: .X03))
        #expect(controller.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 3) == .unavailable)
        #expect(fallback.calls == 0, "no identification is possible, so nothing is computed")

        // A prompted enrollment built on the fallback: saved, but filtering stays off.
        let profile = SpeakerProfile(centroid: try fallback.embed(Self.clip(0)), utteranceCount: 3, enrolledAt: Date())
        #expect(controller.install(profile: profile) == .filteringUnavailable(.X03))
        #expect(!controller.speakerFilteringEnabled)
        #expect(controller.profiles.profile == profile, "the voice is kept for when the weights arrive")
        #expect(controller.insertionDecision(for: .latchSegment, samples: Self.clip(2)).allowsInsertion,
                "filtering off: the latch is not silenced by a backend that cannot identify anyone")
    }

    // MARK: install(profile:) arms the runtime's guard; latch segments only

    @Test("install turns filtering on and assigns LatchRuntime.speakerGuard; far is refused, near passes")
    func installAssignsTheGuard() throws {
        let controller = Self.controller()
        let runtime = LatchRuntime(delivery: NullDelivery())
        var segment: [Float]? = nil
        controller.attach(runtime: runtime, segmentAudio: { segment })
        #expect(runtime.speakerGuard == nil, "no voice enrolled: no filter configured")

        let centroid = SpeakerEmbedding(vector: [1, 0], embedder: "test-wespeaker", metric: .cosine)
        #expect(controller.install(profile: SpeakerProfile(centroid: centroid, utteranceCount: 3, enrolledAt: Date())) == .filtering)
        #expect(controller.speakerFilteringEnabled)
        let guardFn = try #require(runtime.speakerGuard)

        segment = Self.clip(1.2)                               // cos 1.2 ≈ 0.36 < 0.6
        #expect(guardFn() == .suppress(.mismatch))
        #expect(controller.lastRejection == SpeakerFilter.SuppressionReason.mismatch.rawValue)
        segment = Self.clip(0.2)                               // cos 0.2 ≈ 0.98
        #expect(guardFn().allowsInsertion)
        segment = nil                                          // no audio: uncertain is not yes
        #expect(guardFn() == .suppress(.uncertain))

        controller.speakerFilteringEnabled = false
        #expect(runtime.speakerGuard == nil, "switching filtering off clears the guard")
        controller.speakerFilteringEnabled = true
        #expect(runtime.speakerGuard != nil)
    }

    @Test("a hold is never filtered: no embedding, no verdict — even with filtering on")
    func holdIsNeverFiltered() {
        let embedder = ScriptedEmbedder()
        let controller = Self.controller(embedder)
        Self.enroll(controller)
        #expect(controller.speakerFilter.status == .active)

        let stranger = Self.clip(2.5)                          // cos 2.5 < 0
        let before = embedder.calls
        #expect(controller.insertionDecision(for: .hold, samples: stranger) == .allow(similarity: nil))
        #expect(embedder.calls == before, "the hold's audio is not even embedded")
        // The same audio closing a latch segment is refused.
        #expect(controller.insertionDecision(for: .latchSegment, samples: stranger) == .suppress(.mismatch))
        // And a hold after enrollment is only ever "already enrolled" — never a refusal.
        #expect(controller.observeHoldUtterance(samples: stranger, speechSeconds: 3) == .alreadyEnrolled)
    }

    // MARK: "Not you" adjusts the threshold

    @Test("\"Not you\" after a latch segment lifts the threshold, live and on disk")
    func notYouLiftsTheThreshold() throws {
        let url = Self.storeURL()
        let controller = Self.controller(url: url)
        Self.enroll(controller)                                // centroid at θ ≈ 0.025
        let impostor = Self.clip(0.8)                          // similarity ≈ 0.71: let through at 0.6
        #expect(controller.insertionDecision(for: .latchSegment, samples: impostor).allowsInsertion)
        #expect(controller.speakerGate.effectiveThreshold == 0.6)

        controller.markNotYou()                                // the pill's "Not you": about the voice
        let floor = try #require(controller.profiles.profile?.thresholdFloor)
        #expect(floor > 0.7 && floor < 0.8, "just past the rejected voice's similarity")
        #expect(controller.speakerGate.effectiveThreshold == floor, "the live gate took the correction")
        #expect(controller.insertionDecision(for: .latchSegment, samples: impostor) == .suppress(.mismatch))
        #expect(controller.insertionDecision(for: .latchSegment, samples: Self.clip(0.05)).allowsInsertion,
                "the user still gets through")

        // Relaunch: the correction was persisted.
        let relaunched = Self.controller(url: url)
        #expect(relaunched.speakerGate.effectiveThreshold == floor)
    }

    @Test("spoken \"not you\" while filtering is active is a voice correction; otherwise it is about addressing")
    func spokenNotYouReason() {
        #expect(LatchController.notYouReason(for: "not you", filteringActive: true) == .notMe)
        #expect(LatchController.notYouReason(for: "not you", filteringActive: false) == .notTalkingToYou)
        #expect(LatchController.notYouReason(for: "that wasn't me", filteringActive: false) == .notMe)
        #expect(LatchController.notYouReason(for: "wasn't talking to you", filteringActive: true) == .notTalkingToYou)

        let controller = Self.controller()
        Self.enroll(controller)
        #expect(controller.insertionDecision(for: .latchSegment, samples: Self.clip(0.7)).allowsInsertion)
        var ctx = StageContext()
        ctx.extra[WakeVerbPreRoute.modeKey] = WakeVerbPreRoute.latchedValue
        #expect(controller.preRoute("Not you.", context: ctx) != nil)
        #expect(controller.consumeClaim())
        #expect(controller.profiles.profile?.thresholdFloor != nil, "the spoken correction reached the profile")
    }

    // MARK: Launch, delete, weights arriving

    @Test("a launch with an enrolled voice starts filtering; deleting the voice stops it")
    func launchAndDelete() throws {
        let url = Self.storeURL()
        let first = Self.controller(url: url)
        Self.enroll(first)

        let relaunched = Self.controller(url: url)
        #expect(relaunched.speakerFilteringEnabled, "enrolled once, filtering stays on across launches")
        let runtime = LatchRuntime(delivery: NullDelivery())
        relaunched.attach(runtime: runtime, segmentAudio: { nil })
        #expect(runtime.speakerGuard != nil)

        relaunched.profiles.delete()
        #expect(!relaunched.speakerFilteringEnabled)
        #expect(relaunched.speakerGate.profile == nil)
        #expect(runtime.speakerGuard == nil)
        #expect(relaunched.passiveEnrollment.learnedCount == 0, "learning starts over after a delete")

        // A voice another embedder built does not turn filtering on.
        let other = Self.controller(ScriptedEmbedder(name: "another-backend"), url: url)
        other.install(profile: SpeakerProfile(centroid: SpeakerEmbedding(vector: [1, 0], embedder: "test-wespeaker"),
                                              utteranceCount: 3, enrolledAt: Date()))
        #expect(!other.speakerFilteringEnabled)
    }

    @Test("a factory-chosen fallback is replaced once the weights arrive; an injected one is kept")
    func weightsArriving() {
        let controller = Self.controller(ScriptedEmbedder(name: "mfcc-mean", identifies: false))
        let weights = FileManager.default.temporaryDirectory
        #expect(!controller.refreshEmbedderIfWeightsArrived(locate: { weights }, load: { _ in ScriptedEmbedder() }),
                "an injected embedder is the caller's choice")

        controller.allowsEmbedderRefresh = true                // as if the factory had chosen it
        #expect(!controller.refreshEmbedderIfWeightsArrived(locate: { nil }, load: { _ in ScriptedEmbedder() }))
        #expect(controller.refreshEmbedderIfWeightsArrived(locate: { weights }, load: { _ in ScriptedEmbedder() }))
        #expect(controller.embedder.identifiesSpeakers)
        #expect(controller.voiceFilterAvailability == .available)
        #expect(controller.speakerGate.threshold == 0.6)
        // Now holds teach it.
        #expect(controller.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2) == .learned(1))
    }

    @Test("segment audio hands over what arrived since the last take, bounded")
    func segmentAudio() {
        let audio = LatchSegmentAudio(maxSeconds: 1)
        #expect(audio.take() == nil)
        audio.append([1, 2, 3])
        audio.append([4])
        #expect(audio.take() == [1, 2, 3, 4])
        #expect(audio.take() == nil, "each segment is taken once")
        audio.append([Float](repeating: 0.5, count: 20_000))
        #expect(audio.take()?.count == audio.maxSamples)
    }
}
