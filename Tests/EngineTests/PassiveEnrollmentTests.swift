import Foundation
import Testing
import Shared
@testable import Engine

/// H2 (V4.49) — passive enrollment, the "Not you" threshold, the latch filter's verdicts, and the
/// X03 label for the fallback. Synthetic cosine embeddings throughout: an angle θ becomes the unit
/// vector (cos θ, sin θ), so the similarity of two voices is exactly cos(Δθ) and every verdict is
/// arithmetic rather than audio.
@Suite("H2 — passive enrollment and the latch speaker filter")
struct PassiveEnrollmentTests {
    static func voice(_ theta: Float, embedder: String = "test-wespeaker") -> SpeakerEmbedding {
        SpeakerEmbedding(vector: [cos(theta), sin(theta)], embedder: embedder, metric: .cosine)
    }

    static func profile(_ theta: Float = 0) -> SpeakerProfile {
        SpeakerProfile(centroid: voice(theta), utteranceCount: 10, enrolledAt: Date())
    }

    // MARK: Ten holds → a profile

    @Test("ten qualifying holds build the profile; progress counts them")
    func tenHoldsBuildTheProfile() throws {
        var enrollment = SpeakerEnrollment(mode: .passive)
        #expect(enrollment.requiredCount == SpeakerEnrollment.passiveUtterances)
        #expect(SpeakerEnrollment.passiveUtterances == 10)
        #expect(enrollment.currentPrompt == nil, "passive enrollment has nothing to read aloud")
        #expect(enrollment.progress == 0)

        // Ten holds of the same speaker, a little different each time.
        let takes = (0..<10).map { Self.voice(Float($0 % 3) * 0.05) }
        for (i, take) in takes.prefix(9).enumerated() {
            #expect(enrollment.recordHold(take, speechSeconds: 2.0) == .learned(i + 1))
            #expect(enrollment.learnedCount == i + 1)
            #expect(abs(enrollment.progress - Double(i + 1) / 10) < 1e-9)
            #expect(enrollment.profile == nil, "no profile before the tenth hold")
        }
        guard case .complete(let profile) = enrollment.recordHold(takes[9], speechSeconds: 1.5) else {
            Issue.record("the tenth hold must build the profile"); return
        }
        #expect(profile.utteranceCount == 10)
        #expect(profile.centroid.similarity(Self.voice(0.05)) > 0.99)
        #expect(enrollment.progress == 1 && enrollment.step == .done)
        #expect(enrollment.recordHold(Self.voice(0), speechSeconds: 3) == .alreadyComplete)
    }

    @Test("holds under 1.5 s of speech are ignored, not counted")
    func shortHoldsDoNotCount() {
        var enrollment = SpeakerEnrollment(mode: .passive)
        #expect(!SpeakerEnrollment.holdQualifies(speechSeconds: 1.49))
        #expect(SpeakerEnrollment.holdQualifies(speechSeconds: 1.5))
        #expect(enrollment.recordHold(Self.voice(0), speechSeconds: 1.2) == .tooShort(speechSeconds: 1.2))
        #expect(enrollment.learnedCount == 0)
        #expect(enrollment.recordHold(Self.voice(0), speechSeconds: 1.5) == .learned(1))
    }

    @Test("a hold that does not sound like the others is not averaged in")
    func inconsistentHoldIsRejected() {
        var enrollment = SpeakerEnrollment(mode: .passive)
        #expect(enrollment.recordHold(Self.voice(0), speechSeconds: 2) == .learned(1))
        // Opposite direction: cos(π) = -1, far below `minConsistency`.
        guard case .inconsistent = enrollment.recordHold(Self.voice(.pi), speechSeconds: 2) else {
            Issue.record("a different voice was learned as the user's"); return
        }
        #expect(enrollment.learnedCount == 1)
    }

    @Test("a different embedder part-way through starts the count over")
    func embedderChangeStartsOver() {
        var enrollment = SpeakerEnrollment(mode: .passive)
        for _ in 0..<4 { enrollment.recordHold(Self.voice(0, embedder: "mfcc-mean"), speechSeconds: 2) }
        #expect(enrollment.learnedCount == 4)
        #expect(enrollment.recordHold(Self.voice(0, embedder: "fluid-wespeaker"), speechSeconds: 2) == .learned(1))
        #expect(enrollment.embeddings.allSatisfy { $0.embedder == "fluid-wespeaker" })
    }

    @Test("an enrollment in progress round-trips through JSON (embeddings only)")
    func progressRoundTrips() throws {
        var enrollment = SpeakerEnrollment(mode: .passive)
        for i in 0..<4 { enrollment.recordHold(Self.voice(Float(i) * 0.01), speechSeconds: 2) }
        let data = try JSONEncoder().encode(enrollment)
        let decoded = try JSONDecoder().decode(SpeakerEnrollment.self, from: data)
        #expect(decoded == enrollment)
        #expect(decoded.mode == .passive && decoded.learnedCount == 4)
    }

    @Test("prompted enrollment is unchanged: three prompts")
    func promptedIsUnchanged() {
        let enrollment = SpeakerEnrollment()
        #expect(enrollment.mode == .prompted)
        #expect(enrollment.requiredCount == SpeakerEnrollment.requiredUtterances)
        #expect(enrollment.currentPrompt == SpeakerEnrollment.prompts[0])
    }

    // MARK: The filter on latch segments

    @Test("the filter rejects a far voice (cosine < 0.6) and passes a near one")
    func filterRejectsFarPassesNear() {
        let gate = SpeakerGate(profile: Self.profile(0), threshold: 0.6)
        let filter = SpeakerFilter(isOn: true, gate: gate, canIdentify: true)
        #expect(filter.status == .active)
        let far = Self.voice(1.0)            // cos 1.0 ≈ 0.54
        let near = Self.voice(0.3)           // cos 0.3 ≈ 0.96
        #expect(Self.profile(0).centroid.similarity(far) < 0.6)
        #expect(filter.decide(gate.verdict(for: far)) == .suppress(.mismatch))
        #expect(filter.decide(gate.verdict(for: near)).allowsInsertion)
    }

    // MARK: "Not you" adjusts the threshold

    @Test("\"Not you\" lifts the threshold past the rejected voice, within a bound")
    func notYouRaisesTheThreshold() throws {
        var profile = Self.profile(0)
        var gate = SpeakerGate(profile: profile, threshold: 0.6)
        let impostor = Self.voice(0.7)       // cos 0.7 ≈ 0.765 — let through at 0.6
        let user = Self.voice(0.1)           // cos 0.1 ≈ 0.995
        #expect(gate.verdict(for: impostor).isUser)
        #expect(gate.effectiveThreshold == 0.6)

        profile.noteNotYou(impostor)
        gate.profile = profile
        let floor = try #require(profile.thresholdFloor)
        #expect(abs(floor - (cos(Float(0.7)) + SpeakerProfile.notYouStep)) < 1e-5)
        #expect(profile.negatives.count == 1)
        #expect(!gate.verdict(for: impostor).isUser, "the same voice at the same similarity is refused now")
        // A near-miss of the impostor (not identical, so the negative's veto margin is not what
        // refuses it) is refused by the raised threshold alone.
        let cousin = Self.voice(0.69)
        profile.negatives = []
        gate.profile = profile
        #expect(!gate.verdict(for: cousin).isUser)
        #expect(gate.verdict(for: user).isUser)

        // Corrections only raise the floor, and the gate caps what it applies: the user's own voice
        // stays reachable however many times "Not you" is said.
        profile.noteNotYou(Self.voice(0.2))   // cos ≈ 0.98 → floor ≈ 1.0
        gate.profile = profile
        #expect(gate.effectiveThreshold == 0.6 + SpeakerGate.maximumNotYouRaise)
        #expect(gate.verdict(for: Self.voice(0.3)).isUser, "cos 0.955 ≥ the 0.8 cap")
        profile.noteNotYou(Self.voice(0.9))   // a lower similarity never lowers the floor
        #expect(profile.thresholdFloor! >= cos(Float(0.2)))
    }

    @Test("profiles saved before H2 still load")
    func olderProfilesDecode() throws {
        let old = """
        {"centroid":{"vector":[1,0],"embedder":"fluid-wespeaker","metric":"cosine"},
         "utteranceCount":3,"enrolledAt":0}
        """
        let profile = try JSONDecoder().decode(SpeakerProfile.self, from: Data(old.utf8))
        #expect(profile.negatives.isEmpty && profile.thresholdFloor == nil)
        var corrected = profile
        corrected.noteNotYou(Self.voice(0.5, embedder: "fluid-wespeaker"))
        let again = try JSONDecoder().decode(SpeakerProfile.self, from: JSONEncoder().encode(corrected))
        #expect(again == corrected)
    }

    // MARK: X03 — the fallback's label

    @Test("the MFCC fallback is labelled \"Voice filtering unavailable\" with X03's copy")
    func fallbackCarriesTheX03Label() throws {
        #expect(SpeakerFilter.unavailableLabel == "Voice filtering unavailable")
        #expect(SpeakerFilter.modelUnavailableMessage == SpeakerFilter.unavailableLabel)
        #expect(SpeakerFilter.Status.modelUnavailable.recoveryID == .X03)
        #expect(SpeakerFilter.Status.active.recoveryID == nil)
        #expect(SpeakerFilter.availability(of: MFCCEmbedder())
                == .unavailable(label: "Voice filtering unavailable", recovery: .X03))
        #expect(SpeakerFilter.availability(of: MFCCEmbedder()).label == "Voice filtering unavailable")

        // The recovery copy is the verified design's, not retyped here.
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("design/design_copy.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let errors = try #require(json["errors"] as? [[String: Any]])
        let x03 = try #require(errors.first { $0["id"] as? String == "X03" })
        #expect(EngineMessage.headline(for: SpeakerFilter.unavailableRecovery) == x03["headline"] as? String)
        #expect((x03["trigger"] as? String)?.contains("speaker model unavailable") == true)
        #expect((x03["consequence"] as? String) == "Hold-to-talk still works; speaker filtering stays off.")
    }
}
