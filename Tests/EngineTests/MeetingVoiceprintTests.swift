import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M6 (passive voiceprint math) and M12 (the embedding labeler is reachable).
@Suite("V5 M6/M12 — voiceprint and meeting labeler wiring")
struct MeetingVoiceprintTests {
    static func e(_ theta: Float, embedder: String = "fluid-wespeaker") -> SpeakerEmbedding {
        SpeakerEmbedding(vector: [cos(theta), sin(theta)], embedder: embedder, metric: .cosine)
    }

    // MARK: M6 — PassiveVoiceprint

    @Test("usable after five turns, exactly one .ready")
    func usableAfterFiveTurns() {
        var v = PassiveVoiceprint()
        var outcomes: [PassiveVoiceprint.Outcome] = []
        for i in 0..<7 { outcomes.append(v.update(Self.e(Float(i) * 0.01), snrDB: 25)) }
        #expect(outcomes == [.learning(1), .learning(2), .learning(3), .learning(4), .ready, .updated(6), .updated(7)])
        #expect(v.isUsable)
        #expect(v.embedding?.embedder == "fluid-wespeaker")
        var fresh = PassiveVoiceprint()
        for _ in 0..<4 { fresh.update(Self.e(0), snrDB: 25) }
        #expect(fresh.embedding == nil, "min 5 turns before use")
    }

    @Test("SNR weights the mean: a clean turn moves it further than a noisy one")
    func snrWeighting() {
        #expect(PassiveVoiceprint.weight(snrDB: 30) == 1)
        #expect(PassiveVoiceprint.weight(snrDB: 0) == 0.05)
        #expect(abs(PassiveVoiceprint.weight(snrDB: 15) - 0.5) < 1e-6)

        var clean = PassiveVoiceprint(), noisy = PassiveVoiceprint()
        clean.update(Self.e(0), snrDB: 25); noisy.update(Self.e(0), snrDB: 25)
        clean.update(Self.e(0.25), snrDB: 25)   // weight 1
        noisy.update(Self.e(0.25), snrDB: 6)    // weight 0.05
        let angle: (PassiveVoiceprint) -> Float = { atan2($0.mean[1], $0.mean[0]) }
        #expect(angle(clean) > 0.1, "clean turn pulls the mean halfway")
        #expect(angle(noisy) < 0.03, "noisy turn barely moves it")
    }

    @Test("another voice is an outlier once three turns are in; a new embedder starts over")
    func outliersAndEmbedderChange() {
        var v = PassiveVoiceprint()
        for _ in 0..<3 { v.update(Self.e(0), snrDB: 20) }
        guard case .outlier = v.update(Self.e(2.0), snrDB: 30) else { Issue.record("expected outlier"); return }
        #expect(v.turns == 3)
        #expect(v.update(Self.e(0, embedder: "other"), snrDB: 20) == .learning(1))
        #expect(v.embedder == "other")
        #expect(v.update(SpeakerEmbedding(vector: [1, 0, 1, 0], embedder: "mfcc", metric: .gaussian), snrDB: 20) == .unusable)
    }

    @Test("past the weight cap the mean keeps adapting")
    func keepsAdapting() {
        var v = PassiveVoiceprint()
        for _ in 0..<40 { v.update(Self.e(0), snrDB: 30) }
        #expect(v.totalWeight == PassiveVoiceprint.maxTotalWeight)
        for _ in 0..<40 { v.update(Self.e(0.6), snrDB: 30) }
        #expect(atan2(v.mean[1], v.mean[0]) > 0.4, "drifted toward the newer voice")
    }

    @Test("SignalQuality: speech bursts over a quiet floor score higher than steady noise")
    func snrEstimate() {
        var bursts = [Float](repeating: 0.001, count: 32_000)
        for i in stride(from: 0, to: 32_000, by: 4_000) { for k in i..<(i + 2_000) { bursts[k] = 0.3 * sin(Float(k) * 0.2) } }
        let flat = (0..<32_000).map { Float(($0 * 7919) % 200) / 1000 - 0.1 }
        #expect(SignalQuality.snrDB(bursts) > 30)
        #expect(SignalQuality.snrDB(flat) < 6)
        #expect(SignalQuality.snrDB([0.1, 0.2]) == 0)
    }

    // MARK: M12 — DiarizationFactory

    @Test("the embedding labeler is reachable when the voice is known and WeSpeaker is on disk")
    func factoryPicksEmbeddingLabeler() {
        let dir = FileManager.default.temporaryDirectory
        let residency = ModelResidency(budgetBytes: 1 << 30)
        #expect(DiarizationFactory.make(enrolledUserEmbedding: [1, 0], locate: { dir }, residency: residency).name == "embedding")
        #expect(DiarizationFactory.make(enrolledUserEmbedding: nil, locate: { dir }, residency: residency).name == "channel")
        #expect(DiarizationFactory.make(enrolledUserEmbedding: [], locate: { dir }, residency: residency).name == "channel")
        #expect(DiarizationFactory.make(enrolledUserEmbedding: [1, 0], locate: { nil }, residency: residency).name == "channel")
        let labeler = DiarizationFactory.make(enrolledUserEmbedding: [1, 0], locate: { dir }, residency: residency) as? EmbeddingLabeler
        #expect(labeler?.threshold == DiarizationFactory.micThreshold)
    }

    @Test("the WeSpeaker backend loads through ModelResidency; a failed load degrades to channel labels")
    func residentBackendDegrades() async throws {
        let residency = ModelResidency(budgetBytes: 1 << 30)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-wespeaker-\(UUID().uuidString)")
        let labeler = EmbeddingLabeler(backend: ResidentSpeakerEmbedding(directory: missing, residency: residency), enrolled: [1, 0])
        let chunk = MeetingChunk(channel: .system, chunk: AudioChunk(samples: [Float](repeating: 0.1, count: 160), range: 0...0.01, reason: .speechEnd))
        let mic = MeetingChunk(channel: .mic, chunk: AudioChunk(samples: [Float](repeating: 0.1, count: 160), range: 1...1.01, reason: .speechEnd))
        let out = try await labeler.label([mic, chunk])
        #expect(out.map(\.speaker) == [.you, .others(1)])
        #expect(out.allSatisfy { $0.confidence == 0.5 })
        #expect(await residency.isRegistered(ResidentSpeakerEmbedding.residencyKey))
        #expect(await !residency.isResident(ResidentSpeakerEmbedding.residencyKey))
    }

    // MARK: Slot map (shared by M7/M8)

    @Test("slots number by first appearance across legs; the user's slot is You")
    func slotMap() {
        var m = SpeakerSlotMap()
        m.markYou(.init(leg: .mic, index: 0))
        #expect(m.speaker(for: .init(leg: .system, index: 2)) == .others(1))
        #expect(m.speaker(for: .init(leg: .mic, index: 0)) == .you)
        #expect(m.speaker(for: .init(leg: .mic, index: 1)) == .others(2))
        #expect(m.speaker(for: .init(leg: .system, index: 2)) == .others(1))
    }
}
