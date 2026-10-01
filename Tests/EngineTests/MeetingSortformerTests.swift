import FluidAudio
import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M7 (live Sortformer labels) and M8 (final re-diarization), against scripted diarizers — no
/// CoreML, no model download. Synthetic audio: every sample of a chunk is the speaker's "voice id"
/// (a small integer as a Float); the fake diarizer reads it back as the slot.
@Suite("V5 M7/M8 — Sortformer live labels and final re-diarization")
struct MeetingSortformerTests {
    /// Streams per leg; reports turns only for audio older than `latency` (Sortformer's lookahead).
    final class FakeStreaming: StreamingSpeakerDiarizing, @unchecked Sendable {
        let name = "fake"
        let maxSpeakers = 4
        var latency: TimeInterval
        var failPrepare = false
        private var fed: [MeetingChannel: [Float]] = [:]
        private var done: Set<MeetingChannel> = []
        init(latency: TimeInterval = 0) { self.latency = latency }
        func prepare() async throws { if failPrepare { throw SpeakerError.backendUnavailable } }
        func push(_ samples: [Float], leg: MeetingChannel) throws -> [SpeakerTurn] {
            fed[leg, default: []].append(contentsOf: samples)
            return turns(leg)
        }
        func finish(leg: MeetingChannel) throws -> [SpeakerTurn] { done.insert(leg); return turns(leg) }
        private func turns(_ leg: MeetingChannel) -> [SpeakerTurn] {
            let s = fed[leg] ?? []
            let horizon = done.contains(leg) ? s.count : max(0, s.count - Int(latency * 16_000))
            return Self.segments(Array(s.prefix(horizon)))
        }
        /// Runs of equal sample value → turns (value = slot).
        static func segments(_ s: [Float]) -> [SpeakerTurn] {
            guard !s.isEmpty else { return [] }
            var out: [SpeakerTurn] = []
            var start = 0
            for i in 1...s.count where i == s.count || s[i] != s[start] {
                out.append(SpeakerTurn(speaker: Int(s[start]), range: Double(start) / 16_000...Double(i) / 16_000))
                start = i
            }
            return out
        }
    }

    /// Embedding = one-hot of the voice id: voice 0 is the user.
    final class VoiceEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
        func embedding(for samples: [Float]) throws -> [Float] {
            let v = Int(samples.first ?? 0)
            return (0..<4).map { $0 == v ? 1 : 0 }
        }
    }

    static func chunk(_ leg: MeetingChannel, voice: Float, at t: TimeInterval, seconds: TimeInterval = 2) -> MeetingChunk {
        MeetingChunk(channel: leg, chunk: AudioChunk(samples: [Float](repeating: voice, count: Int(seconds * 16_000)),
                                                    range: t...(t + seconds), reason: .speechEnd))
    }

    // MARK: M7 — catalog + cap

    @Test("catalog: one on-demand Sortformer variant, ~0.26 GB, matching FluidAudio's names; cap 4 per leg")
    func catalogEntry() {
        let d = ModelCatalog.descriptor(.sortformer)
        #expect(d.role == .onDemand && d.kind == .whisper)
        #expect(d.hfRepo == "FluidInference/diar-streaming-sortformer-coreml")
        #expect(d.hfSubdirectory == ModelNames.Sortformer.ModelPrecision.fp16.subdirectory)
        #expect(ModelNames.Sortformer.Variant.highContextV2_1.fileName == d.hfSubdirectory + "/" + SortformerFiles.bundle)
        #expect(d.approxBytes == 255_245_283 && d.approxBytes < 500_000_000)
        #expect(d.remoteFiles.allSatisfy { $0.size != nil && $0.path.hasPrefix(SortformerFiles.bundle + "/") })
        #expect(!ModelStack.models.contains(.sortformer))
        #expect(!ModelCatalog.userVisible(qwenRefinementEnabled: true).contains(.sortformer))
        #expect(ModelCatalog.fluidAudioFolderName(for: .sortformer) == nil)
        #expect(ModelID.allCases.last == .sortformer, "appended")
        // The documented cap: 4 speakers per stream (one stream per leg).
        #expect(SortformerBackend.config.numSpeakers == 4)
        #expect(SortformerBackend.config.modelVariant == .highContextV2_1)
        #expect(SortformerBackend(folder: URL(fileURLWithPath: "/nonexistent")).maxSpeakers == 4)
        #expect(SortformerBackend.locate(modelsRoot: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test("fed clock: turns on squeezed audio map back across the VAD gaps")
    func fedClock() {
        var c = FedClock()
        c.append(meetingStart: 10, duration: 2)
        c.append(meetingStart: 20, duration: 3)
        #expect(c.meetingRanges(0...1) == [10...11])
        #expect(c.meetingRanges(1.5...3) == [11.5...12, 20...21])
        #expect(c.fedSeconds == 5)
    }

    // MARK: M7 — live labels

    @Test("live labels: the user's mic slot is You, other voices numbered across legs, per chunk")
    func liveLabels() async throws {
        let labeler = SortformerLabeler(diarizer: StreamingDiarizer(backend: FakeStreaming(), legs: [.mic, .system]),
                                        fallback: EmbeddingLabeler(backend: VoiceEmbedding(), enrolled: [1, 0, 0, 0]))
        let out = try await labeler.label([
            Self.chunk(.mic, voice: 0, at: 0),       // the user
            Self.chunk(.system, voice: 2, at: 3),    // remote A
            Self.chunk(.mic, voice: 1, at: 6),       // someone across the room
            Self.chunk(.system, voice: 3, at: 9),    // remote B
            Self.chunk(.system, voice: 2, at: 12),   // remote A again
        ])
        #expect(out.map(\.speaker) == [.you, .others(1), .others(2), .others(3), .others(1)])
        #expect(out.allSatisfy { $0.confidence > 0.9 })
        #expect(labeler.userSlots == [.init(leg: .mic, index: 0)])
    }

    @Test("chunks the diarizer has not reached yet keep the wrapped label, provisional")
    func provisionalUnderLatency() async throws {
        let labeler = SortformerLabeler(diarizer: StreamingDiarizer(backend: FakeStreaming(latency: 30), legs: [.mic, .system]),
                                        fallback: ChannelLabeler())
        let out = try await labeler.label([Self.chunk(.mic, voice: 0, at: 0), Self.chunk(.system, voice: 2, at: 3)])
        #expect(out.map(\.speaker) == [.you, .others(1)])
        #expect(out.allSatisfy { $0.confidence == 0.5 })
    }

    @Test("a model that cannot load leaves the wrapped labeler in charge")
    func unavailableModel() async throws {
        let fake = FakeStreaming(); fake.failPrepare = true
        let labeler = SortformerLabeler(diarizer: StreamingDiarizer(backend: fake), fallback: ChannelLabeler())
        let out = try await labeler.label([Self.chunk(.mic, voice: 0, at: 0), Self.chunk(.system, voice: 2, at: 3)])
        #expect(out.map(\.speaker) == [.you, .others(1)])
        #expect(out.map(\.confidence) == [1, 1])
    }

    @Test("only the configured legs are diarized (in-person: mic only)")
    func legsRespected() async throws {
        let diarizer = StreamingDiarizer(backend: FakeStreaming(), legs: [.mic])
        let labeler = SortformerLabeler(diarizer: diarizer, fallback: ChannelLabeler())
        _ = try await labeler.label([Self.chunk(.mic, voice: 1, at: 0), Self.chunk(.system, voice: 2, at: 3)])
        #expect(diarizer.currentTurns[.system] == nil)
        #expect(diarizer.currentTurns[.mic]?.first?.speaker == 1)
    }

    @Test("factory: Sortformer wraps the labeler when installed; otherwise unchanged")
    func factory() {
        let residency = ModelResidency(budgetBytes: 1 << 30)
        let dir = FileManager.default.temporaryDirectory
        let wrapped = DiarizationFactory.make(enrolledUserEmbedding: [1, 0], locate: { dir }, sortformer: { dir }, residency: residency)
        #expect(wrapped.name == "sortformer")
        #expect((wrapped as? SortformerLabeler)?.fallback.name == "embedding")
        #expect(DiarizationFactory.make(enrolledUserEmbedding: nil, locate: { nil }, sortformer: { nil }, residency: residency).name == "channel")
    }
}
