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
        #expect(ModelID.allCases.firstIndex(of: .sortformer)! > ModelID.allCases.firstIndex(of: .parakeetRedux)!, "appended (V5 M9 appended .campPlus after it)")
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

    // MARK: M8 — final re-diarization

    static func transcript() -> MeetingTranscript {
        MeetingTranscript(utterances: [
            MeetingUtterance(speaker: .you, text: "hello all", range: 0...2, confidence: 1),
            MeetingUtterance(speaker: .others(1), text: "hi", range: 3...5, confidence: 1, tag: nil),
            MeetingUtterance(speaker: .you, text: "note this", range: 6...8, confidence: 1, tag: .dictate),
            MeetingUtterance(speaker: .others(1), text: "and me", range: 9...11, confidence: 1),
        ])
    }

    final class FakeOffline: OfflineSpeakerDiarizing, @unchecked Sendable {
        func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] { FakeStreaming.segments(samples) }
    }

    /// A "file" is its name: `voices` per second, 12 s.
    struct ScriptedReader: MeetingAudioReading {
        let voices: [String: [Float]]
        func samples(of url: URL) throws -> [Float] {
            (voices[url.lastPathComponent] ?? []).flatMap { [Float](repeating: $0, count: 16_000) }
        }
    }

    @Test("recording locator: per-leg files or one mix")
    func locator() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(MeetingRecordingAudio.locate(in: dir) == nil)
        try Data().write(to: dir.appendingPathComponent("meeting.json"))
        try Data().write(to: dir.appendingPathComponent("recording.m4a"))
        #expect(MeetingRecordingAudio.locate(in: dir)?.mixed?.lastPathComponent == "recording.m4a")
        try Data().write(to: dir.appendingPathComponent("mic.wav"))
        try Data().write(to: dir.appendingPathComponent("system.wav"))
        let r = try #require(MeetingRecordingAudio.locate(in: dir))
        #expect(r.mixed == nil)
        #expect(r.legs[.mic]?.lastPathComponent == "mic.wav" && r.legs[.system]?.lastPathComponent == "system.wav")
    }

    @Test("offline pass relabels every utterance; the user's slot by voice; tags survive")
    func offlineRelabel() async throws {
        // Mixed recording: 0–3 s the user (voice 0), 3–6 s voice 2, 6–9 s the user, 9–12 s voice 3.
        let voices: [Float] = [0, 0, 0, 2, 2, 2, 0, 0, 0, 3, 3, 3]
        let r = FinalRediarizer(diarizer: FakeOffline(), reader: ScriptedReader(voices: ["mix.wav": voices]),
                                voice: (backend: VoiceEmbedding(), enrolled: [1, 0, 0, 0]))
        let out = try await r.relabel(Self.transcript(), recording: MeetingRecordingAudio(mixed: URL(fileURLWithPath: "/x/mix.wav")))
        #expect(out.utterances.map(\.speaker) == [.you, .others(1), .you, .others(2)], "live merged two people as Others; final splits them")
        #expect(out.utterances.map(\.text) == Self.transcript().utterances.map(\.text))
        #expect(out.utterances[2].tag == .dictate)
    }

    @Test("without a voice the user's slot comes from the live labels' vote")
    func offlineRelabelByVote() async throws {
        let r = FinalRediarizer(diarizer: FakeOffline(),
                                reader: ScriptedReader(voices: ["mic.wav": [1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0],
                                                                "system.wav": [0, 0, 0, 2, 2, 2, 0, 0, 0, 3, 3, 3]]))
        // Per-leg: silence on a leg is "voice 0" in this script; the mic's slot 1 is the user.
        let rec = MeetingRecordingAudio(legs: [.mic: URL(fileURLWithPath: "/x/mic.wav"), .system: URL(fileURLWithPath: "/x/system.wav")])
        let out = try await r.relabel(Self.transcript(), recording: rec)
        #expect(out.utterances[0].speaker == .you)
        #expect(out.utterances[2].speaker == .you)
        #expect(out.utterances[1].speaker != .you && out.utterances[3].speaker != .you)
    }

    @Test("finish without a recording keeps (settles) the live labels; with one, the offline pass wins")
    func finalTranscriptPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let labeler = SortformerLabeler(diarizer: StreamingDiarizer(backend: FakeStreaming(latency: 30), legs: [.mic, .system]),
                                        fallback: ChannelLabeler())
        let live = try await labeler.label([Self.chunk(.mic, voice: 0, at: 0), Self.chunk(.system, voice: 2, at: 3, seconds: 2),
                                            Self.chunk(.mic, voice: 0, at: 6), Self.chunk(.system, voice: 3, at: 9)])
        #expect(live.allSatisfy { $0.confidence == 0.5 }, "all provisional under the 30 s lookahead")
        var record = MeetingRecord(title: "t", transcript: Self.transcript())

        // No recording → live diarizer flushed → Others split into two people.
        let settled = await labeler.finalTranscript(for: record, recordingIn: dir)
        #expect(settled?.utterances.map(\.speaker) == [.you, .others(1), .you, .others(2)])

        // With a recording → the offline pass.
        try Data().write(to: dir.appendingPathComponent("recording.wav"))
        labeler.offlineOverride = FinalRediarizer(diarizer: FakeOffline(),
                                                  reader: ScriptedReader(voices: ["recording.wav": [0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2]]))
        record.transcript = Self.transcript()
        let offline = await labeler.finalTranscript(for: record, recordingIn: dir)
        #expect(offline?.utterances.map(\.speaker) == [.you, .others(1), .others(1), .others(1)])
    }

    @Test("relabel keeps uncovered utterances apart from re-numbered speakers")
    func uncoveredKept() {
        let turns: [MeetingChannel: [SpeakerTurn]] = [.system: [SpeakerTurn(speaker: 0, range: 3...5)]]
        let out = TranscriptRelabeler.relabel(Self.transcript(), turns: turns, youSlots: [])
        #expect(out.utterances.map(\.speaker) == [.you, .others(1), .you, .others(2)])
    }
}
