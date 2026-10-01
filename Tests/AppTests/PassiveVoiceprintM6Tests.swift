import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 M6 at the controller + store: every qualifying hold feeds the voiceprint (enrolled or not),
/// it is usable after five, "Voice learned" is said once ever, and M12 reads it for meetings.
/// Synthetic voices as in `PassiveEnrollmentLatchTests`: the clip's first sample is θ.
@Suite("V5 M6 — passive voiceprint")
struct PassiveVoiceprintM6Tests {
    typealias Embedder = PassiveEnrollmentLatchTests.ScriptedEmbedder

    static func controller(_ embedder: any SpeakerEmbedder = Embedder(name: "fluid-wespeaker"),
                           url: URL = PassiveEnrollmentLatchTests.storeURL()) -> LatchController {
        PassiveEnrollmentLatchTests.controller(embedder, url: url)
    }

    static func clip(_ theta: Float) -> [Float] { PassiveEnrollmentLatchTests.clip(theta) }

    @Test("five holds make the voiceprint usable; the pill hears once, even when H2 finishes at ten")
    func fiveHoldsThenOnce() {
        let c = Self.controller()
        var notices = 0, profiles = 0
        c.onVoiceLearnedNotice = { notices += 1 }
        c.onVoiceLearned = { _ in profiles += 1 }
        for i in 0..<4 { c.observeHoldUtterance(samples: Self.clip(Float(i % 2) * 0.05), speechSeconds: 2) }
        #expect(c.profiles.voiceprint.turns == 4)
        #expect(c.profiles.meetingEmbedding() == nil, "min 5 turns before use")
        #expect(notices == 0)
        c.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2)
        #expect(c.profiles.voiceprint.isUsable)
        #expect(notices == 1)
        #expect(c.profiles.meetingEmbedding()?.count == 2)
        for _ in 0..<5 { c.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2) }
        #expect(profiles == 1, "H2 still builds the latch profile")
        #expect(notices == 1, "\"Voice learned\" once ever")
        // Enrolled: holds keep refining the voiceprint (running mean), still reported as enrolled.
        #expect(c.observeHoldUtterance(samples: Self.clip(0.1), speechSeconds: 3) == .alreadyEnrolled)
        #expect(c.profiles.voiceprint.turns == 11)
        #expect(c.wantsHoldAudio)
    }

    @Test("short holds and the MFCC fallback teach nothing")
    func shortAndMFCC() {
        let c = Self.controller()
        c.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 0.8)
        #expect(c.profiles.voiceprint.turns == 0)
        let mfcc = Self.controller(Embedder(name: "mfcc", identifies: false))
        #expect(mfcc.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 3) == .unavailable)
        #expect(mfcc.profiles.voiceprint.turns == 0)
    }

    @Test("the notice survives a relaunch; deleting the voice deletes the voiceprint")
    func persistence() {
        let url = PassiveEnrollmentLatchTests.storeURL()
        let first = Self.controller(url: url)
        var notices = 0
        first.onVoiceLearnedNotice = { notices += 1 }
        for _ in 0..<5 { first.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2) }
        #expect(notices == 1)
        let relaunched = Self.controller(url: url)
        relaunched.onVoiceLearnedNotice = { notices += 1 }
        #expect(relaunched.profiles.voiceprint.turns == 5)
        for _ in 0..<6 { relaunched.observeHoldUtterance(samples: Self.clip(0), speechSeconds: 2) }
        #expect(notices == 1)
        relaunched.profiles.delete()
        #expect(relaunched.profiles.voiceprint.turns == 0)
        #expect(relaunched.profiles.meetingEmbedding() == nil)
    }

    @Test("M12 — meetings get the voiceprint, else a WeSpeaker profile, never an MFCC one")
    func meetingEmbeddingChoice() {
        let store = SpeakerProfileStore(url: PassiveEnrollmentLatchTests.storeURL())
        #expect(store.meetingEmbedding() == nil)
        store.save(SpeakerProfile(centroid: SpeakerEmbedding(vector: [1, 0, 1, 0], embedder: "mfcc-gaussian", metric: .gaussian),
                                  utteranceCount: 3, enrolledAt: Date()))
        #expect(store.meetingEmbedding() == nil)
        store.save(SpeakerProfile(centroid: SpeakerEmbedding(vector: [0, 1], embedder: "fluid-wespeaker"),
                                  utteranceCount: 3, enrolledAt: Date()))
        #expect(store.meetingEmbedding() == [0, 1])
        for _ in 0..<5 { store.updateVoiceprint(SpeakerEmbedding(vector: [1, 0], embedder: "fluid-wespeaker"), snrDB: 20) }
        #expect(store.meetingEmbedding() == [1, 0], "the voiceprint wins once usable")
    }
}
