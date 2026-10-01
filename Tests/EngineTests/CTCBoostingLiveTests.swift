import Foundation
import Shared
import Testing
@testable import Engine

/// V5 B1 gate, run on the bundled entity fixtures with the real models: Parakeet TDT v3 (final pass)
/// unboosted vs boosted by `parakeet-ctc-110m` CTC keyword spotting.
///
/// The vocabulary is the fixtures' entities **plus distractors that are not spoken** (so a booster
/// that rewrites eagerly shows up as false insertions). Gate (V5 B1): entity recall up, false
/// insertion rate ≤ +0.5 pp, WER not worse by more than 0.2 pp — on this set, which is TTS, so the
/// numbers here are a smoke test; the public-set gate (Earnings-22 entities + MUSAN 10 dB) is T1.
///
/// Skipped unless TDT v3 and the CTC model are on disk; `VOICEPLUS_LIVE_MODELS=1` fetches the CTC
/// model (~103 MB) into the VoicePlus model folder.
@Suite("CTC boosting on entity fixtures (V5 B1, real model)", .serialized)
struct CTCBoostingLiveTests {
    static let entities: [String: [String]] = [
        "entity_01_samantha.wav": ["TeamViewer"],
        "entity_02_daniel.wav": ["Kothari", "Mumbai"],
        "entity_03_rishi.wav": ["kubectl"],
        "entity_04_samantha.wav": ["gpt-4o"],
        "entity_05_daniel.wav": ["Anthropic"],
        "entity_06_rishi.wav": ["SQLite", "GRDB"],
        "entity_07_samantha.wav": ["FluidAudio", "Parakeet"],
        "entity_08_daniel.wav": ["Devanagari"],
        "entity_09_rishi.wav": ["Sundar Pichai"],
        "entity_10_samantha.wav": ["Zsh"],
    ]
    static let distractors = ["Priya", "Bandra", "Zephyr", "Grafana", "Postgres", "Kubernetes", "Shopify", "Nvidia"]

    @Test(.timeLimit(.minutes(30)))
    func boostedBeatsUnboostedOnEntityFixtures() async throws {
        let manager = ModelManager(maintenance: .skip)
        let live = ProcessInfo.processInfo.environment["VOICEPLUS_LIVE_MODELS"] == "1"
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        if await !manager.isPresent(.parakeetCTC110m) {
            guard live else { print("SKIPPED: parakeet-ctc-110m not on disk. VOICEPLUS_LIVE_MODELS=1 fetches it (~103 MB)."); return }
            _ = try await manager.ensureAvailable(.parakeetCTC110m)
        }
        let fixtures = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/entity")
        let entries = try JSONDecoder().decode([FixtureEntry].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let models = try #require(try await manager.load(.parakeetTDTv3).asrModels)
        let decoder = try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.v3")
        let recognizer = DecoderFinalRecognizer(decoder: decoder)
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false)
        let vocabulary = BoostVocabulary.build(dictionary: Self.entities.values.flatMap { $0 } + Self.distractors, corrections: [])

        // Warm the CTC model (load + ANE compile) so the per-utterance cost below is the steady state.
        let warm = try SampleAudioSource.load16k(url: fixtures.appendingPathComponent(entries[0].file))
        recognizer.installBooster(CTCVocabularyBooster(terms: vocabulary, source: source))
        _ = try await recognizer.recognize(warm)

        var plain = BiasingMetrics(), boosted = BiasingMetrics()
        var werPlain = 0.0, werBoosted = 0.0, extraMs = 0.0
        for e in entries {
            let samples = try SampleAudioSource.load16k(url: fixtures.appendingPathComponent(e.file))
            let ents = Self.entities[e.file] ?? []
            recognizer.installBooster(nil)
            let t0 = Date()
            let h0 = try await recognizer.recognize(samples).joinedText
            let ms0 = Date().timeIntervalSince(t0) * 1000
            recognizer.installBooster(CTCVocabularyBooster(terms: vocabulary, source: source))
            let t1 = Date()
            let h1 = try await recognizer.recognize(samples).joinedText
            let ms1 = Date().timeIntervalSince(t1) * 1000
            extraMs += ms1 - ms0
            plain.record(reference: e.transcript, hypothesis: h0, entities: ents, biasList: vocabulary)
            boosted.record(reference: e.transcript, hypothesis: h1, entities: ents, biasList: vocabulary, addedLatencyMs: ms1 - ms0)
            werPlain += wordErrorRate(reference: e.transcript, hypothesis: h0)
            werBoosted += wordErrorRate(reference: e.transcript, hypothesis: h1)
            print("\(e.file)\n  plain:   \(h0)\n  boosted: \(h1)  (\(decoder.lastBoost?.replacements.map { "\($0.original)→\($0.replacement)" } ?? []))")
        }
        let n = Double(entries.count)
        let dWER = (werBoosted - werPlain) / n * 100
        let dFI = (boosted.falseInsertionRate - plain.falseInsertionRate) * 100
        print(String(format: "B1 entity fixtures: recall %.2f → %.2f; false-insertion %.2f%% → %.2f%% (Δ %.2f pp); WER %.2f%% → %.2f%% (Δ %.2f pp); +%.0f ms/utt",
                     plain.entityRecall, boosted.entityRecall, plain.falseInsertionRate * 100, boosted.falseInsertionRate * 100, dFI,
                     werPlain / n * 100, werBoosted / n * 100, dWER, extraMs / n))
        #expect(boosted.entityRecall >= plain.entityRecall)
        #expect(dFI <= 0.5)
        #expect(dWER <= 0.2)
    }
}
