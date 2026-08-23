import Engine
import Foundation
import Testing
@testable import VoicePlusApp

final class RecordingTeacher: DirectedSpeechTeacher, @unchecked Sendable {
    var examples: [DirectedSpeechExample] = []
    func learn(_ example: DirectedSpeechExample) { examples.append(example) }
}
final class RecordingProfile: SpeakerProfileUpdating, @unchecked Sendable {
    var negatives: [SpeakerEmbedding] = [], reinforced: [SpeakerEmbedding] = []
    func addNegative(_ e: SpeakerEmbedding) { negatives.append(e) }
    func reinforce(_ e: SpeakerEmbedding) { reinforced.append(e) }
}

@Suite("'Not you' correction hook (P5.4)")
struct AmbientNotYouTests {
    let emb = SpeakerEmbedding(vector: [0.3, 0.4], embedder: "t")

    @Test func notYouTeachesClassifierAndProfile() {
        let teacher = RecordingTeacher(), profile = RecordingProfile()
        let c = NotYouCorrection(teacher: teacher, profile: profile)
        #expect(c.notYou() == nil)  // nothing to correct
        let t = PendingTrigger(text: "turn the volume up", embedding: emb)
        c.didTrigger(t)
        let corrected = c.notYou(reason: .notMe)
        #expect(corrected == t && c.pending.isEmpty)
        #expect(teacher.examples.count == 1 && teacher.examples[0].label == .notDirected && teacher.examples[0].reason == .notMe)
        #expect(profile.negatives == [emb])

        // "Not talking to you" (it was me, but not directed) must not poison the speaker profile.
        c.didTrigger(PendingTrigger(text: "hi mom", embedding: emb))
        c.notYou(reason: .notTalkingToYou)
        #expect(profile.negatives.count == 1 && teacher.examples.count == 2)
    }

    @Test func windowAndAcceptance() {
        let teacher = RecordingTeacher(), profile = RecordingProfile()
        let c = NotYouCorrection(teacher: teacher, profile: profile)
        let old = PendingTrigger(text: "old", embedding: emb, at: Date().addingTimeInterval(-NotYouCorrection.window - 1))
        c.didTrigger(old)
        #expect(c.notYou() == nil && c.pending.count == 1)   // too old to correct, but still listed
        for i in 0..<(NotYouCorrection.keep + 2) { c.didTrigger(PendingTrigger(text: "t\(i)", embedding: emb)) }
        #expect(c.pending.count == NotYouCorrection.keep && c.pending.first?.text == "t2")
        let id = c.pending.last!.utteranceID
        c.accepted(id)
        #expect(teacher.examples.last?.label == .directed && profile.reinforced == [emb])
        #expect(!c.pending.contains { $0.utteranceID == id })
        c.accepted(UUID())   // unknown id is a no-op
        #expect(teacher.examples.count == 1)
    }
}
