import Engine
import Foundation
import Shared
import Testing

/// R3.3 — the speaker guard. Two rules, both from V3 §8:
///
/// * with filtering on, a **mismatch** *and* an **uncertain** result suppress insertion;
/// * with the embedding weights absent, the app says **"speaker model unavailable"** instead of
///   implying that a voice was checked.
///
/// The second one is the case this machine can actually exercise: per V3 §2.3 the WeSpeaker backend
/// has no weights here, so `SpeakerEmbedderFactory.make()` returns the MFCC fallback and
/// `FluidSpeakerEmbedder.isAvailable` is false. The matching-voice path is synthetic-audio only and
/// stays an owner check.
@Suite("Speaker filtering is honest about what it knows")
struct SpeakerFilterTests {

    /// A profile whose centroid is a known vector, so verdicts are arithmetic rather than audio.
    private static func profile(_ vector: [Float]) -> SpeakerProfile {
        SpeakerProfile(centroid: SpeakerEmbedding(vector: vector, embedder: "test", metric: .cosine),
                       utteranceCount: 3, enrolledAt: Date())
    }

    private static func embedding(_ vector: [Float]) -> SpeakerEmbedding {
        SpeakerEmbedding(vector: vector, embedder: "test", metric: .cosine)
    }

    /// Claims to identify speakers; used to exercise the "weights present" branch on a machine
    /// where the real weights are absent.
    final class IdentifyingEmbedder: SpeakerEmbedder, @unchecked Sendable {
        let name = "test-identifying"
        let dimension = 2
        let identifiesSpeakers = true
        var vector: [Float] = [1, 0]
        var shouldThrow = false
        func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
            if shouldThrow { throw SpeakerError.backendUnavailable }
            return SpeakerEmbedding(vector: vector, embedder: name, metric: .cosine)
        }
    }

    // MARK: Status

    @Test("filtering off says nothing and blocks nothing")
    func filteringOffAllowsEverything() {
        let filter = SpeakerFilter(isOn: false, gate: SpeakerGate(profile: nil), canIdentify: false)
        #expect(filter.status == .off)
        #expect(filter.status.message == nil)
        #expect(filter.decide(.other(similarity: 0)).allowsInsertion)
        #expect(filter.decide(.unknown).allowsInsertion)
    }

    @Test("filtering on with no embedding weights is 'Voice filtering unavailable', not a verdict")
    func absentWeightsAreReportedHonestly() {
        let filter = SpeakerFilter(isOn: true,
                                   gate: SpeakerGate(profile: Self.profile([1, 0])),
                                   canIdentify: false)
        #expect(filter.status == .modelUnavailable)
        // H3: the fallback's label is the design's X03 wording.
        #expect(filter.status.message == "Voice filtering unavailable")
        #expect(!filter.status.identifies, "an unavailable model must never count as identification")
        // Even a verdict that *looks* like a match cannot be trusted from a backend that does not
        // identify speakers, so the decision is the same either way — and it never says "not you".
        #expect(filter.decide(.user(similarity: 0.99)) == .suppress(.modelUnavailable))
        #expect(filter.decide(.other(similarity: 0.1)) == .suppress(.modelUnavailable))
        #expect(filter.decide(.unknown) == .suppress(.modelUnavailable))
        #expect(filter.decide(.unknown).suppression?.message == SpeakerFilter.modelUnavailableMessage)
    }

    @Test("this machine has no embedding weights, so the factory's embedder does not identify")
    func theFallbackEmbedderDoesNotClaimIdentification() {
        let embedder = SpeakerEmbedderFactory.make()
        // Whichever backend is present, the invariant is the same: `identifiesSpeakers` is true only
        // for the real embedding model.
        #expect(embedder.identifiesSpeakers == FluidSpeakerEmbedder.isAvailable)
        #expect(!MFCCEmbedder().identifiesSpeakers)
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.profile([1, 0])), embedder: embedder)
        if FluidSpeakerEmbedder.isAvailable {
            #expect(filter.status == .active)
        } else {
            #expect(filter.status == .modelUnavailable)
        }
    }

    @Test("filtering on with nothing enrolled says so instead of guessing")
    func notEnrolledIsItsOwnAnswer() {
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: true)
        #expect(filter.status == .notEnrolled)
        #expect(filter.status.message == SpeakerFilter.notEnrolledMessage)
        #expect(filter.decide(.unknown) == .suppress(.notEnrolled))
    }

    // MARK: Decisions with an identifying backend

    @Test("a mismatch suppresses insertion")
    func mismatchSuppressesInsertion() {
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.profile([1, 0])), canIdentify: true)
        #expect(filter.status == .active)
        #expect(filter.decide(.other(similarity: 0.2)) == .suppress(.mismatch))
    }

    @Test("an uncertain result suppresses insertion — uncertain is not yes")
    func uncertainSuppressesInsertion() {
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.profile([1, 0])), canIdentify: true)
        #expect(filter.decide(.unknown) == .suppress(.uncertain))
        // …and the plain gate, which has no filtering setting to consult, still allows it. The two
        // answers are different on purpose: the gate must not silence a user it cannot measure.
        #expect(SpeakerGate(profile: Self.profile([1, 0])).shouldAccept(.unknown, latched: true))
    }

    @Test("the enrolled voice is allowed through, and the similarity comes with it")
    func theEnrolledVoiceIsAllowed() {
        let gate = SpeakerGate(profile: Self.profile([1, 0]), threshold: 0.6)
        let filter = SpeakerFilter(isOn: true, gate: gate, canIdentify: true)
        let verdict = gate.verdict(for: Self.embedding([1, 0]))
        #expect(verdict.isUser)
        #expect(filter.decide(verdict) == .allow(similarity: 1))
    }

    @Test("an embedder that throws is uncertain, never a pass")
    func anEmbedderThatThrowsIsUncertain() {
        let embedder = IdentifyingEmbedder()
        embedder.shouldThrow = true
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.profile([1, 0])), embedder: embedder)
        #expect(filter.status == .active)
        #expect(filter.decide(samples: [0.1, 0.2, 0.3], embedder: embedder) == .suppress(.uncertain))
    }

    @Test("with no weights the embedder is never even run")
    func noWeightsMeansNoWork() {
        final class Counting: SpeakerEmbedder, @unchecked Sendable {
            let name = "counting"
            let dimension = 2
            var calls = 0
            func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
                calls += 1
                return SpeakerEmbedding(vector: [1, 0], embedder: name, metric: .cosine)
            }
        }
        let embedder = Counting()
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.profile([1, 0])), embedder: embedder)
        #expect(filter.status == .modelUnavailable)
        #expect(filter.decide(samples: [0.1, 0.2], embedder: embedder) == .suppress(.modelUnavailable))
        #expect(embedder.calls == 0, "an answer that was already known still cost an embedding")
    }

    @Test("every suppression reason has a sentence, and none of them claims an identification")
    func everyReasonSaysSomethingTrue() {
        for reason in SpeakerFilter.SuppressionReason.allCases {
            #expect(!reason.message.isEmpty)
            if reason == .modelUnavailable || reason == .notEnrolled {
                #expect(!reason.message.lowercased().contains("your voice"),
                        "\(reason) implies a voice was checked")
            }
        }
    }
}
