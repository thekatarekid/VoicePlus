import Darwin
import FluidAudio
import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M9 — CAM++ as the alternative meeting embedding; the V1 DER result picks the default.
/// No CoreML here: backends are scripted. The real comparison is the opt-in replay at the bottom.
@Suite("V5 M9 — meeting embedding choice (WeSpeaker vs CAM++)")
struct MeetingEmbeddingChoiceTests {
    /// Embedding = one-hot of the voice id (every sample of a chunk is the id).
    final class VoiceEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
        let dims: Int
        private(set) var calls = 0
        private(set) var prepared = 0
        init(dims: Int = 4) { self.dims = dims }
        func prepare() async throws { prepared += 1 }
        func embedding(for samples: [Float]) throws -> [Float] {
            calls += 1
            let v = Int((samples.first ?? 0).rounded())
            return (0..<dims).map { $0 == v % dims ? 1 : 0.05 }
        }
    }

    static func chunk(_ leg: MeetingChannel, voice: Float, at t: TimeInterval, seconds: TimeInterval = 2) -> MeetingChunk {
        MeetingChunk(channel: leg, chunk: AudioChunk(samples: [Float](repeating: voice, count: Int(seconds * 16_000)),
                                                    range: t...(t + seconds), reason: .speechEnd))
    }

    @Test("catalog: CAM++ on demand, FluidAudio's names, < 500 MB, appended")
    func catalogEntry() {
        let d = ModelCatalog.descriptor(.campPlus)
        #expect(d.role == .onDemand && d.hfRepo == Repo.campPlus.rawValue)
        #expect(d.folderName == ModelCatalog.fluidAudioFolderName(for: .campPlus))
        #expect(Set(d.requiredPaths) == ModelNames.CampPlus.requiredModels)
        #expect(d.approxBytes == 16_618_757 && d.approxBytes < 500_000_000)
        #expect(!ModelStack.models.contains(.campPlus))
        #expect(ModelID.allCases.firstIndex(of: .campPlus)! > ModelID.allCases.firstIndex(of: .sortformer)!, "appended")
        #expect(ResidentCampPlusEmbedding.locate(in: [URL(fileURLWithPath: "/nonexistent")]) == nil)
        #expect(MeetingEmbeddingChoice.campPlus.modelID == .campPlus && MeetingEmbeddingChoice.wespeaker.modelID == .speakerEmbedding)
        #expect(MeetingEmbeddingChoice.wespeaker.embedderID == "fluid-wespeaker")
    }

    @Test("pick: the lower mean DER over sets both models were measured on; else WeSpeaker")
    func pickByDER() {
        typealias M = MeetingEmbeddingChoice.Measurement
        #expect(MeetingEmbeddingChoice.pick([]) == .wespeaker)
        // Only CAM++ measured: no comparison → shipped default.
        #expect(MeetingEmbeddingChoice.pick([M(set: "voxconverse-test", choice: .campPlus, der: 5, date: "2026-10-02")]) == .wespeaker)
        let both = [M(set: "voxconverse-test", choice: .wespeaker, der: 12, date: "2026-10-02"),
                    M(set: "voxconverse-test", choice: .campPlus, der: 10, date: "2026-10-02"),
                    M(set: "ami", choice: .wespeaker, der: 30, date: "2026-10-02"),
                    M(set: "ami", choice: .campPlus, der: 31, date: "2026-10-02")]
        #expect(MeetingEmbeddingChoice.pick(both) == .campPlus)   // mean 20.5 vs 21
        // A later WeSpeaker run on VoxConverse replaces the older one.
        #expect(MeetingEmbeddingChoice.pick(both + [M(set: "voxconverse-test", choice: .wespeaker, der: 8, date: "2026-10-05")]) == .wespeaker)
        // Sets outside VoxConverse / AMI never decide.
        #expect(MeetingEmbeddingChoice.pick([M(set: "librispeech", choice: .wespeaker, der: 50, date: "d"),
                                             M(set: "librispeech", choice: .campPlus, der: 1, date: "d")]) == .wespeaker)
    }

    @Test("measurements read `--stage diar` reports from Lab/results; override wins")
    func readsResultsAndOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func report(_ model: String, _ set: String, _ der: Double, stage: String = "diar") -> Data {
            #"{"set":"\#(set)","stage":"\#(stage)","model":"\#(model)","date":"2026-10-02","summary":{"der":\#(der)}}"#.data(using: .utf8)!
        }
        try report("diar-wespeaker", "ami", 25).write(to: dir.appendingPathComponent("a.json"))
        try report("diar-campplus", "ami", 20).write(to: dir.appendingPathComponent("b.json"))
        try report("parakeet-tdt-v3", "ami", 1, stage: "asr").write(to: dir.appendingPathComponent("c.json"))
        let ms = MeetingEmbeddingChoice.measurements(in: dir)
        #expect(ms.count == 2)
        #expect(MeetingEmbeddingChoice.pick(ms) == .campPlus)

        let defaults = try #require(UserDefaults(suiteName: "m9-\(UUID().uuidString)"))
        #expect(MeetingEmbeddingChoice.current(defaults: defaults, measured: { ms }) == .campPlus)
        defaults.set("wespeaker", forKey: MeetingEmbeddingChoice.overrideKey)
        #expect(MeetingEmbeddingChoice.current(defaults: defaults, measured: { ms }) == .wespeaker)
    }

    @Test("embedding labeler: CAM++ clusters the call, the voiceprint's model judges the mic")
    func clusterBackendForSystemLeg() async throws {
        let voice = VoiceEmbedding(), cam = VoiceEmbedding(dims: 3)
        let labeler = EmbeddingLabeler(backend: voice, enrolled: [1, 0.05, 0.05, 0.05], threshold: 0.5, clusterBackend: cam)
        let out = try await labeler.label([Self.chunk(.mic, voice: 0, at: 0), Self.chunk(.system, voice: 1, at: 2),
                                           Self.chunk(.system, voice: 2, at: 4), Self.chunk(.system, voice: 1, at: 6)])
        #expect(out.map(\.speaker) == [.you, .others(1), .others(2), .others(1)])
        #expect(cam.calls == 3 && voice.calls == 1 && cam.prepared == 1)
        // Mic-only batch never loads the cluster model.
        _ = try await labeler.label([Self.chunk(.mic, voice: 0, at: 8)])
        #expect(cam.prepared == 1)
    }

    @Test("offline cluster diarizer: two voices alternating → two speakers, turns on the boundaries")
    func clusterDiarizer() throws {
        var s: [Float] = []
        for (voice, seconds) in [(1, 6.0), (2, 6.0), (1, 6.0)] { s += [Float](repeating: Float(voice), count: Int(seconds * 16_000)) }
        s += [Float](repeating: 0, count: 3 * 16_000)   // trailing silence: no turn
        let turns = try EmbeddingClusterDiarizer().diarize(s, backend: VoiceEmbedding())
        #expect(turns.map(\.speaker) == [0, 1, 0])
        #expect(abs(turns[0].start) < 0.01 && abs(turns[1].start - 6) <= 0.8 && abs(turns[2].start - 12) <= 0.8)
        #expect(turns.last!.end <= 18.8)
        #expect(EmbeddingClusterDiarizer.cluster([], threshold: 0.5).isEmpty)
        #expect(EmbeddingClusterDiarizer.cluster([[1, 0], [0.99, 0.1], [0, 1]], threshold: 0.5) == [0, 0, 1])
    }

    // MARK: opt-in V1 replay (real models)

    /// `VOICEPLUS_EVAL_SET=voxconverse-test` (or `ami`) after `lab fetch`: diarizes every item with
    /// both embedding models through `EmbeddingClusterDiarizer` and writes
    /// `<cache>/<set>/hyp-diar-<model>.json`, scored by `lab eval --stage diar --model diar-<model> --hyp …`.
    @Test(.timeLimit(.minutes(120)))
    func replayDiarizationSet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["VOICEPLUS_EVAL_SET"], set.hasPrefix("voxconverse") || set.hasPrefix("ami") else {
            print("SKIPPED: set VOICEPLUS_EVAL_SET=voxconverse-test|ami to compare WeSpeaker and CAM++ on DER.")
            return
        }
        struct Manifest: Decodable { struct Item: Decodable { let id: String; let audio: String? }; let audioRoot: String; let items: [Item] }
        struct Turn: Encodable { let speaker: String; let start: Double; let end: Double }
        struct Item: Encodable { let turns: [Turn]; let latencyMs: Double; let audioSeconds: Double }
        struct Hyp: Encodable { let model: String; let set: String; let peakRSSBytes: UInt64; let items: [String: Item] }
        let cache = env["VOICEPLUS_EVAL_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportDirectory().appendingPathComponent("Eval", isDirectory: true)
        let setDir = cache.appendingPathComponent(set, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: setDir.appendingPathComponent("manifest.json")))
        let root = manifest.audioRoot.hasPrefix("/") ? URL(fileURLWithPath: manifest.audioRoot) : cache.appendingPathComponent(manifest.audioRoot)
        for choice in MeetingEmbeddingChoice.allCases {
            guard let backend = choice.backend() else { print("NOTE: \(choice.rawValue) weights not on disk — skipped."); continue }
            try await backend.prepare()
            var items: [String: Item] = [:]
            for item in manifest.items {
                guard let audio = item.audio else { continue }
                let samples = try SampleAudioSource.load16k(url: audio.hasPrefix("/") ? URL(fileURLWithPath: audio) : root.appendingPathComponent(audio))
                let t0 = DispatchTime.now().uptimeNanoseconds
                let turns = try EmbeddingClusterDiarizer().diarize(samples, backend: backend)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                items[item.id] = Item(turns: turns.map { Turn(speaker: "s\($0.speaker)", start: $0.start, end: $0.end) },
                                      latencyMs: ms, audioSeconds: Double(samples.count) / 16_000)
            }
            var u = rusage(); _ = getrusage(RUSAGE_SELF, &u)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(Hyp(model: choice.evalModelID, set: set, peakRSSBytes: UInt64(max(0, u.ru_maxrss)), items: items))
                .write(to: setDir.appendingPathComponent("hyp-\(choice.evalModelID).json"))
        }
    }
}
