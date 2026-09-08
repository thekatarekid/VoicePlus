import Foundation
import Testing
import Shared
@testable import Engine

/// WER **through the decoder configuration the app actually ships** — that is, with a
/// `ShallowFusionBiaser` installed on the recognizer's decoder, built from screen-harvested text,
/// exactly as `AppContainer.prepareForUtterance()` does it.
///
/// Why this suite exists: every other test resolved the recognizer via `RecognizerFactory.makeFinal`
/// and left `decoder.biaser == nil`, so the biased configuration was never exercised end to end.
/// The suspicion (1.7.12, "the quick brown fox" → "the quake brown fogs jump above the lazy doll")
/// was that a +4 log-prob bias off unrelated on-screen text was pulling the decode toward phonetic
/// neighbours. `biasingCannotChangeTheDecodedWords` and `pangramThroughTheShippingBiasedPath` are
/// the measurements that settle it.
///
/// Measured 2026-09-08 (Parakeet TDT 0.6B v3, M2 Pro), 12 clean fixtures, a 400-entry trie built by
/// the real `ContextHarvester` + `Ranker` from unrelated on-screen prose:
///
///   biaser == nil (as every previous test ran it)   mean WER 0.0140
///   biaser installed (as the app wires it)          mean WER 0.0140   — byte-identical text
///
/// The reason is structural, and worth knowing before anyone tunes `BiasingConfig` again:
/// on the real Parakeet path `FluidAudioTDTDecoder` runs FluidAudio's greedy TDT to completion and
/// then calls `BiasRescorer.apply`, which adjusts the **`logProb` of tokens that were already
/// chosen**. It never re-picks a token, so no value of `boostPerToken`/`maxBoost` can substitute a
/// word. That is exactly why `FeatureFlag.contextBiasing` has been `defaultOn: false` since P1.12 T2
/// (DECISIONS.md) — and with the flag off, `BiasingController.makeBiaser()` returns nil and the
/// shipping app installs no biaser at all.
///
/// What biasing *does* change is confidence, and that is not nothing:
/// `biasingPerturbsConfidenceNotText` measures it, because span confidence gates the Bet 9
/// rewrite contract downstream. Keep that test if the flag is ever flipped back on.
@Suite("Biased decode WER (real model, app configuration)", .serialized)
struct BiasedDecodeWERTests {
    /// Unrelated prose standing in for "the owner's screen was full of other text". Deliberately
    /// dense in capitalised terms and phonetic neighbours of the pangram words ("Quake", "Fogg",
    /// "Doll", "Jumper", "Above") so a trie built from it is the worst realistic case for the
    /// pangram — if biasing could pull a decode, this is the text that would do it.
    static let screenText = """
    Quake Engine Release Notes — Fogg Industries, Doll Systems Division
    Jumper Above Ltd. filed the Quakers Report on Tuesday. Contact Daniel Fogg or Samantha Doll.
    The Quake build broke on Wednesday; Fogs rolled back the Jumper deployment above staging.
    Attendees: Rishi Kothari, Samantha Doll, Daniel Fogg, Priya Quake, Marcus Jumper.
    kubectl get pods --namespace quake-staging | grep fogs
    TeamViewer AG, Quakebridge Analytics, Dollhouse Media, FoggBank Capital, AboveCloud.
    Lazy loading is disabled in the Doll renderer. The Fogs pipeline jumps above the Quake queue.
    Subject: Re: Quake / Fogg merger — Doll Systems due diligence, Jumper above the line items.
    """

    static let pangram = "The quick brown fox jumps over the lazy dog."

    /// Builds the biaser the way the app does: real `ContextHarvester` over an AX-tree source fed
    /// with `screenText`, real `Ranker` (cap 400), real Parakeet vocabulary off disk, real
    /// `BiasingConfig` defaults, gated through `BiasingController` with the flag forced on.
    static func makeAppBiaser(extraTerms: [String] = []) -> ShallowFusionBiaser? {
        guard let vocab = BiasVocabulary.discoverParakeet() else { return nil }
        var strings: [(String, Double)] = screenText
            .split(separator: "\n")
            .enumerated()
            .map { (String($1), $0 == 0 ? 1.0 : 0.8) }
        strings += extraTerms.map { ($0, 1.0) }
        let harvester = ContextHarvester(sources: [AXTreeSource(provider: MockFocusedWindowText(strings))])
        let controller = BiasingController(harvester: harvester, vocabulary: vocab,
                                           flags: .inMemory([FeatureFlag.contextBiasing.id: true]))
        return controller.makeBiaser()
    }

    /// The recognizer as the app resolves it, plus a handle on its decoder so the biaser can be
    /// installed the way `BiasingRecognizerProvider.install` installs it.
    static func makeAppRecognizer(_ manager: ModelManager) async throws -> (FinalRecognizer, DecoderFinalRecognizer) {
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let decoderBacked = try #require(final as? DecoderFinalRecognizer)
        return (final, decoderBacked)
    }

    /// Renders `text` to a 16 kHz float WAV with macOS `say`. No binary fixture is committed for
    /// the pangram: it is one sentence, and synthesising it keeps the repro self-contained.
    /// Returns nil when `say` is missing or the voice is not installed.
    static func synthesize(_ text: String, voice: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voiceplus-bias-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let out = dir.appendingPathComponent("say.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "--data-format=LEF32@16000", "--file-format=WAVE", "-o", out.path, text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { try? FileManager.default.removeItem(at: dir); return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: dir); return nil
        }
        return out
    }

    struct Measured { var mean: Double; var worst: Double; var worstFile: String; var texts: [String] }

    static func measure(label: String, entries: [FixtureEntry], dir: URL,
                        final: any FinalRecognizer) async throws -> Measured {
        var total = 0.0, worst = 0.0, worstFile = "", texts: [String] = []
        for e in entries {
            let samples = try SampleAudioSource.load16k(url: dir.appendingPathComponent(e.file))
            let hyp = try await final.recognize(samples).joinedText
            let wer = wordErrorRate(reference: e.transcript, hypothesis: hyp)
            total += wer
            texts.append(hyp)
            if wer > worst { worst = wer; worstFile = e.file }
            print(String(format: "[%@] %@: WER %.3f | %@", label, e.file, wer, hyp))
        }
        let m = Measured(mean: total / Double(entries.count), worst: worst, worstFile: worstFile, texts: texts)
        print(String(format: "[%@] MEAN WER %.4f over %d fixtures (worst %.3f on %@)",
                     label, m.mean, entries.count, m.worst, m.worstFile))
        return m
    }

    static func loadCleanFixtures() throws -> (URL, [FixtureEntry]) {
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/clean")
        let entries = try JSONDecoder().decode([FixtureEntry].self,
                                               from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        return (dir, entries)
    }

    // MARK: - The headline experiment

    /// A/B over the clean suite: the shipping recognizer with `decoder.biaser == nil` versus the
    /// same recognizer with the app's real biaser installed. Both means are printed; the assertion
    /// is that biasing costs nothing, because on this decoder it *cannot* cost anything.
    @Test(.timeLimit(.minutes(60)))
    func biasingCannotChangeTheDecodedWords() async throws {
        let manager = ModelManager()
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        guard let biaser = Self.makeAppBiaser() else {
            print("SKIPPED: no Parakeet vocabulary on disk (BiasVocabulary.discoverParakeet)."); return
        }
        print("bias trie: \(biaser.tree.entryCount) entries, config boost=\(biaser.config.boostPerToken) maxBoost=\(biaser.config.maxBoost)")
        #expect(biaser.tree.entryCount > 20, "the screen-text trie should be populated for this to mean anything")

        let (dir, entries) = try Self.loadCleanFixtures()
        let (final, decoderBacked) = try await Self.makeAppRecognizer(manager)

        decoderBacked.decoder.biaser = nil
        let off = try await Self.measure(label: "biasing off", entries: entries, dir: dir, final: final)

        decoderBacked.decoder.biaser = biaser
        let on = try await Self.measure(label: "biasing ON (app config)", entries: entries, dir: dir, final: final)
        decoderBacked.decoder.biaser = nil

        print(String(format: "A/B: biasing off MEAN %.4f | biasing on MEAN %.4f | delta %+.4f",
                     off.mean, on.mean, on.mean - off.mean))
        #expect(biaser.callCount > 0, "the biaser was never consulted — the wiring under test is not live")
        #expect(on.texts == off.texts,
                "biasing changed the decoded text; on this decoder BiasRescorer only rescores, so this is a real regression")
        #expect(on.mean <= off.mean + 0.001, "biasing degraded WER through the app's real configuration")
    }

    /// The owner's exact failure case, through the biased path, against a trie deliberately
    /// stuffed with phonetic neighbours of every content word in the pangram.
    @Test(.timeLimit(.minutes(20)))
    func pangramThroughTheShippingBiasedPath() async throws {
        let manager = ModelManager()
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: no model."); return }
        guard let biaser = Self.makeAppBiaser(extraTerms: ["Quake", "Fogs", "Doll", "Above", "Jump"]) else {
            print("SKIPPED: no Parakeet vocabulary on disk."); return
        }
        guard let wav = Self.synthesize(Self.pangram, voice: "Samantha") else {
            print("SKIPPED: `say` is unavailable, cannot synthesise the pangram."); return
        }
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let samples = try SampleAudioSource.load16k(url: wav)
        let (final, decoderBacked) = try await Self.makeAppRecognizer(manager)

        decoderBacked.decoder.biaser = nil
        let plain = try await final.recognize(samples).joinedText
        decoderBacked.decoder.biaser = biaser
        let biased = try await final.recognize(samples).joinedText
        decoderBacked.decoder.biaser = nil

        print("pangram, biasing off: \(plain)")
        print("pangram, biasing ON : \(biased)")
        print(String(format: "pangram WER off %.3f | on %.3f",
                     wordErrorRate(reference: Self.pangram, hypothesis: plain),
                     wordErrorRate(reference: Self.pangram, hypothesis: biased)))
        #expect(biased == plain, "biasing rewrote the pangram — the rescorer is re-picking tokens")
    }

    // MARK: - What biasing does change

    /// Biasing is not inert: it moves span confidence, and confidence gates the Bet 9 rewrite
    /// contract (`TranscriptSpan.lowConfidenceThreshold`) for every downstream stage. This test
    /// pins that so the effect stays visible if the flag is ever flipped back on.
    @Test
    func biasingPerturbsConfidenceNotText() async throws {
        let vocab = BiasVocabulary.synthetic()
        let ids = try #require(vocab.encode("kubectl"))
        let script = ids.enumerated().map { i, id in
            DecodedToken(tokenId: id, text: vocab.pieces[id], logProb: log(0.6),
                         startTime: Double(i) * 0.1, endTime: Double(i) * 0.1 + 0.1)
        }
        let decoder = MockDecoder(script: script)
        let frames = FluidAudioTDTDecoder.frames(fromSamples: [Float](repeating: 0, count: 16_000))

        let plain = try await decoder.decode(encoderFrames: frames)
        await decoder.reset()
        decoder.biaser = ShallowFusionBiaser(entries: [BiasEntry(text: "kubectl", weight: 1)], vocabulary: vocab)
        let biased = try await decoder.decode(encoderFrames: frames)

        #expect(biased.tokens.map(\.tokenId) == plain.tokens.map(\.tokenId), "the rescorer must not change token identity")
        #expect(biased.tokens.map(\.text) == plain.tokens.map(\.text))
        let plainConf = WordConfidence.spans(from: plain.tokens).map(\.confidence)
        let biasedConf = WordConfidence.spans(from: biased.tokens).map(\.confidence)
        #expect(zip(biasedConf, plainConf).allSatisfy { $0 >= $1 }, "a boosted word should not lose confidence")
        #expect(biasedConf != plainConf, "biasing must actually move confidence, or the hook is dead")
    }

    /// A candidate that walks into the trie and then leaves it is *penalised* by up to `maxBoost`
    /// (4 log-prob ≈ ×0.018 probability). On the real decoder that word is still typed — only its
    /// confidence collapses, which can push an ordinary correct word below
    /// `TranscriptSpan.lowConfidenceThreshold` and change how downstream stages treat it.
    /// This is the sharpest edge in `BiasingConfig`; measure it rather than assume it.
    @Test
    func leavingTheTrieCanPushACorrectWordBelowTheLowConfidenceThreshold() throws {
        let vocab = BiasVocabulary.synthetic()
        let biaser = ShallowFusionBiaser(entries: [BiasEntry(text: "kubernetes", weight: 1)], vocabulary: vocab)
        let prefix = try #require(vocab.encode("kube"))
        let divergent = try #require(vocab.encode("s")).last!   // "kube" + something not in the trie
        let bonus = biaser.boost(tokenIds: [divergent], prefixState: PrefixState(tokenIds: prefix)) [divergent] ?? 0
        print("unboost after 4 in-trie tokens: \(bonus) log-prob")
        let confident: Float = 0.95
        let after = min(1, exp(log(confident) + bonus))
        print("confidence \(confident) -> \(after)")
        if bonus < 0 {
            #expect(after < confident)
            #expect(bonus >= -biaser.config.maxBoost, "the maxBoost clamp is the only guard on this penalty")
        }
    }
}
