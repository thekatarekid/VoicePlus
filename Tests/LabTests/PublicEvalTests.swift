import Foundation
import Testing
import Shared
@testable import Lab

@Suite struct OpenASRNormalizerTests {
    @Test(arguments: [
        ("Mr. Smith's going to the U.S.A. today!", "mister smith is going to the u s a today"),
        ("I won't do it, I can't.", "i will not do it i can not"),
        ("Um, hello [noise] there (laughs) uh", "hello there"),
        ("The colour of the centre", "the color of the center"),
        ("Café naïve Œuvre", "cafe naive oeuvre"),
        ("We'll see; they've gone — I'm sure", "we will see they have gone i am sure"),
        ("He'd been there", "he had been there"),
        ("HELLO,   World", "hello world"),
        ("1,000 people", "1000 people"),
    ])
    func whisperRules(input: String, expected: String) {
        #expect(OpenASRNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("twenty five dollars", "$25"),
        ("$25", "$25"),
        ("nineteen eighty four", "1984"),
        ("one hundred and five", "105"),
        ("two thousand nineteen", "2019"),
        ("three point five percent", "3.5%"),
        ("3.5 percent", "3.5%"),
        ("nine one one", "911"),
        ("the twenty first century", "the 21st century"),
        ("first of all", "1st of all"),
        ("a hundred years", "100 years"),
        ("two million people", "2000000 people"),
        ("in the sixties", "in the 60s"),
        ("forty two", "42"),
        ("chapter twelve begins", "chapter 12 begins"),
    ])
    func numbers(input: String, expected: String) {
        #expect(OpenASRNormalizer.normalize(input) == expected)
    }

    @Test func spokenAndWrittenNumbersScoreEqual() {
        let w = EvalMetrics.wer(reference: "IT COST TWENTY FIVE DOLLARS IN EIGHTEEN EIGHTY", hypothesis: "It cost $25 in 1880.", mode: .normalized)
        #expect(w.errors == 0)
    }

    @Test func rawModeKeepsCaseAndPunctuation() {
        #expect(OpenASRNormalizer.normalize("Hello, World. Yes?", mode: .raw) == "Hello , World . Yes ?")
        let w = EvalMetrics.wer(reference: "Hello, World.", hypothesis: "hello world", mode: .raw)
        #expect(w.errors == 4)  // 2 case substitutions + 2 missing punctuation tokens
        #expect(EvalMetrics.wer(reference: "Hello, World.", hypothesis: "hello world", mode: .normalized).errors == 0)
    }
}

@Suite struct EvalMetricsTests {
    @Test func cer() {
        let c = EvalMetrics.cer(reference: "kitten", hypothesis: "sitting", mode: .normalized)
        #expect(c.errors == 3 && c.chars == 6)
    }

    @Test func entityRecall() {
        #expect(EvalMetrics.entityHits(entities: ["Sundar Pichai", "Mumbai", "GRDB"], hypothesis: "sundar pichai went to bombay") == 1)
    }

    @Test func cleanupVerdicts() {
        let keep = EvalMetrics.cleanup(input: "Send it today.", target: "Send it today.", output: "Send it today.")
        #expect(!keep.needsEdit && keep.restrained && !keep.damaged)
        let fix = EvalMetrics.cleanup(input: "um send it uh today", target: "Send it today.", output: "Send it today.")
        #expect(fix.needsEdit && fix.edited && !fix.damaged)
        let harm = EvalMetrics.cleanup(input: "Send it today.", target: "Send it today.", output: "Send it tomorrow, please.")
        #expect(!harm.restrained && harm.damaged)
    }

    @Test func derPerfectSwappedAndMissed() {
        let ref = [SpeakerTurn(speaker: "A", start: 0, end: 5), SpeakerTurn(speaker: "B", start: 5, end: 10)]
        // Labels permuted: optimal mapping makes this perfect.
        let swapped = [SpeakerTurn(speaker: "x", start: 0, end: 5), SpeakerTurn(speaker: "y", start: 5, end: 10)]
        #expect(EvalMetrics.der(reference: ref, hypothesis: swapped).der < 1e-9)
        // Everything one speaker: 5 s confusion of 10 s.
        let merged = [SpeakerTurn(speaker: "x", start: 0, end: 10)]
        #expect(abs(EvalMetrics.der(reference: ref, hypothesis: merged).der - 0.5) < 1e-6)
        // Second half missed.
        let missed = [SpeakerTurn(speaker: "x", start: 0, end: 5)]
        let d = EvalMetrics.der(reference: ref, hypothesis: missed)
        #expect(abs(d.missed - 5) < 1e-6 && abs(d.der - 0.5) < 1e-6)
    }

    @Test func peakRSSIsReported() {
        #expect(EvalMetrics.peakRSSBytes() > 1_000_000)
    }
}

/// Harness on a 3-file synthetic manifest (V1 test).
@Suite struct PublicEvalHarnessTests {
    static func sandbox() throws -> (EvalPaths, EvalManifest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-eval-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache"), fixtures = root.appendingPathComponent("Fixtures")
        let audio = cache.appendingPathComponent("synthetic-3/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for f in ["a.wav", "b.wav", "c.wav"] { try Data([0]).write(to: audio.appendingPathComponent(f)) }
        let manifest = EvalManifest(set: "synthetic-3", audioRoot: "synthetic-3/audio", items: [
            EvalItem(id: "a", audio: "a.wav", reference: "Mister Kothari paid twenty dollars.", tags: ["clean"], entities: ["Kothari"]),
            EvalItem(id: "b", audio: "b.wav", reference: "the meeting starts at nine", tags: ["clean"]),
            EvalItem(id: "c", audio: "c.wav", reference: "turn the music down please", tags: ["snr-5"]),
        ])
        let dir = fixtures.appendingPathComponent("public/synthetic-3")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return (EvalPaths(cacheDirectory: cache, fixturesDirectory: fixtures, resultsDirectory: root.appendingPathComponent("results")), manifest)
    }

    static let hyps: [String: String] = [
        "a": "Mr. Kothari paid $20.",            // 0 errors after normalisation
        "b": "the meeting starts at 9",          // 0
        "c": "turn the muse it down",            // music→muse, +it, -please: 3 errors / 5 words
    ]

    static let backend = ScriptedEvalBackend(modelID: "mock-asr") { item, _ in
        EvalOutput(text: hyps[item.id], latencyMs: ["a": 100, "b": 200, "c": 300][item.id])
    }

    @Test func runsAndBreaksDownByCondition() async throws {
        let (paths, _) = try Self.sandbox()
        let eval = PublicEval(paths: paths, hardware: "test-hw", now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let manifest = try paths.loadManifest(set: "synthetic-3")
        let r = try await eval.run(manifest: manifest, backend: Self.backend)
        #expect(r.summary.items == 3)
        #expect(r.summary.referenceWords == 14)          // "mister kothari paid $20" is 4 words
        #expect(abs((r.summary.wer ?? -1) - 300.0 / 14) < 1e-9)  // 3 / 14
        #expect(r.byCondition["clean"]?.wer == 0)
        #expect(abs((r.byCondition["snr-5"]?.wer ?? -1) - 60) < 1e-9)
        #expect(r.summary.entityRecall == 100)
        #expect(r.summary.latencyP50Ms == 200 && r.summary.latencyP95Ms == 300)
        #expect(r.summary.peakRSSMB > 1)
        let url = try eval.write(r)
        #expect(url.lastPathComponent == "2026-09-21-synthetic-3-mock-asr.json")
        let back = try JSONDecoder().decode(EvalReport.self, from: Data(contentsOf: url))
        #expect(back == r)
        #expect(PublicEval.table(r).contains("| snr-5 | 1 | 60.00 |"))
    }

    @Test func missingAudioIsAnError() async throws {
        let (paths, manifest) = try Self.sandbox()
        var m = manifest
        m.items[0].audio = "nope.wav"
        await #expect(throws: EvalError.self) { try await PublicEval(paths: paths).run(manifest: m, backend: Self.backend) }
    }

    @Test func cliEvalWritesResultAndGates() async throws {
        let (paths, _) = try Self.sandbox()
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let baselines = Baselines(entries: [.init(model: "mock-asr", set: "synthetic-3", value: 21.2, source: "test")])
        try JSONEncoder().encode(baselines).write(to: paths.resultsDirectory.appendingPathComponent("baselines.json"))
        var registry = LabRegistry.mocks
        registry.evalBackends["mock-asr"] = { Self.backend }
        let eval = PublicEval(paths: paths, hardware: "hw")

        let pass = await LabCLI.main(["eval", "--set", "synthetic-3", "--stage", "asr", "--model", "mock-asr", "--gate"],
                                     registry: registry, eval: eval)
        #expect(pass.exitCode == 0, Comment(rawValue: pass.text))
        #expect(pass.text.contains("Δ +0.23"))
        #expect(pass.eval?.baseline?.gatePassed == true)
        #expect(pass.text.contains("wrote "))

        // Published 21.0 → Δ +0.43 > +0.3: the gate fails.
        let worse = Baselines(entries: [.init(model: "mock-asr", set: "synthetic-3", value: 21.0, source: "test")])
        try JSONEncoder().encode(worse).write(to: paths.resultsDirectory.appendingPathComponent("baselines.json"))
        let fail = await LabCLI.main(["eval", "--set", "synthetic-3", "--model", "mock-asr", "--gate", "--no-write"],
                                     registry: registry, eval: eval)
        #expect(fail.exitCode == 1)
        #expect(fail.text.contains("FAIL"))
        // Without --gate a regression is reported, not fatal.
        let report = await LabCLI.main(["eval", "--set", "synthetic-3", "--model", "mock-asr", "--no-write"], registry: registry, eval: eval)
        #expect(report.exitCode == 0)
    }

    @Test func cliReplaysHypothesisFile() async throws {
        let (paths, _) = try Self.sandbox()
        let file = ReplayBackend.File(model: "x", set: "synthetic-3", peakRSSBytes: 2 * 1_048_576 * 1024,
                                      items: Self.hyps.mapValues { EvalOutput(text: $0, latencyMs: 50) })
        let url = paths.cacheDirectory.appendingPathComponent("hyp.json")
        try JSONEncoder().encode(file).write(to: url)
        let out = await LabCLI.main(["eval", "--set", "synthetic-3", "--model", "real-model", "--hyp", url.path, "--no-write"],
                                    eval: PublicEval(paths: paths))
        #expect(out.exitCode == 0, Comment(rawValue: out.text))
        #expect(out.eval?.model == "real-model")
        #expect(abs((out.eval?.summary.wer ?? 0) - 300.0 / 14) < 1e-9)
        #expect((out.eval?.summary.peakRSSMB ?? 0) >= 2048)
    }

    @Test func cleanupAndDecideStages() async throws {
        let m = EvalManifest(set: "cleanup-proxy", audioRoot: "", items: [
            EvalItem(id: "1", reference: "Send it today.", input: "Send it today."),
            EvalItem(id: "2", reference: "Send it today.", input: "um send it today"),
            EvalItem(id: "3", reference: "Call Mom.", input: "Call Mom."),
        ])
        let cleaner = ScriptedEvalBackend(modelID: "c") { item, _ in
            EvalOutput(text: item.id == "3" ? "Call mom now." : item.reference)
        }
        let r = try await PublicEval().run(manifest: m, backend: cleaner, options: .init(stage: .cleanup))
        #expect(r.summary.restraint == 50 && r.summary.edit == 100)
        #expect(abs((r.summary.damage ?? 0) - 100.0 / 3) < 1e-9)

        let d = EvalManifest(set: "decide", audioRoot: "", items: [
            EvalItem(id: "1", reference: "", label: "dictate"), EvalItem(id: "2", reference: "", label: "command"),
        ])
        let decider = ScriptedEvalBackend(modelID: "d") { _, _ in EvalOutput(label: "dictate") }
        #expect(try await PublicEval().run(manifest: d, backend: decider, options: .init(stage: .decide)).summary.accuracy == 50)
    }

    @Test func unknownSetPointsAtFetch() throws {
        let (paths, _) = try Self.sandbox()
        #expect(throws: EvalError.self) { try paths.loadManifest(set: "librispeech-test-other") }
        do { _ = try paths.loadManifest(set: "librispeech-test-other") } catch {
            #expect("\(error)".contains("lab fetch --set librispeech-test-other"))
        }
    }
}

@Suite struct DatasetCatalogTests {
    struct NoNetwork: DatasetTransport {
        func download(_ url: URL, to file: URL) async throws { Issue.record("unexpected download \(url)") }
        func untar(_ archive: URL, into dir: URL) throws { Issue.record("unexpected untar") }
    }

    @Test func catalogueCoversTheV5Sets() {
        for name in ["librispeech-test-clean", "librispeech-pc-test-clean", "earnings22", "voices-subset", "notsofar1", "ami",
                     "fleurs-en_us", "common-voice-en-IN", "common-voice-hi", "mucs2021", "hiacc", "voxconverse-test", "musan", "svarah"] {
            #expect(DatasetCatalog.entry(name) != nil, "missing \(name)")
        }
        #expect(DatasetCatalog.entry("svarah")?.access == .gated)
    }

    @Test func libriSpeechManifestFromExistingLayoutWithoutDownloading() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ls-\(UUID().uuidString)")
        let chapter = cache.appendingPathComponent("librispeech/LibriSpeech/test-clean/1089/134686")
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        try "1089-134686-0000 HE HOPED THERE WOULD BE STEW\n1089-134686-0001 STUFF IT INTO YOU\n"
            .write(to: chapter.appendingPathComponent("1089-134686.trans.txt"), atomically: true, encoding: .utf8)
        let paths = EvalPaths(cacheDirectory: cache, fixturesDirectory: nil, resultsDirectory: cache.appendingPathComponent("r"))
        let m = try await DatasetFetcher(paths: paths, transport: NoNetwork()).fetch("librispeech-test-clean")
        #expect(m.items.count == 2)
        #expect(m.items[0] == EvalItem(id: "1089-134686-0000", audio: "1089/134686/1089-134686-0000.flac",
                                       reference: "HE HOPED THERE WOULD BE STEW", tags: ["clean-read"]))
        #expect(m.audioRoot == "librispeech/LibriSpeech/test-clean")
        #expect(try paths.loadManifest(set: "librispeech-test-clean") == m)
        #expect(paths.audioURL(m.items[0], manifest: m)?.path.hasSuffix("test-clean/1089/134686/1089-134686-0000.flac") == true)
    }

    @Test func fleursAndLibriSpeechPCBuilders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tsv = dir.appendingPathComponent("test.tsv")
        try "1\t10004088536354799741.wav\tThe Raw Text.\tthe raw text\tx\t1000\tMALE\n".write(to: tsv, atomically: true, encoding: .utf8)
        let f = try ManifestBuilders.fleurs(set: "fleurs-en_us", language: "en_us", tsv: tsv, audioRoot: "fleurs-en_us/test")
        #expect(f.items.first == EvalItem(id: "10004088536354799741", audio: "10004088536354799741.wav", reference: "The Raw Text.", tags: ["en_us"]))
        let nemo = dir.appendingPathComponent("test-clean.json")
        try #"{"audio_filepath": "test-clean/1089/134686/1089-134686-0000.flac", "duration": 10.4, "text": "He hoped there would be stew."}"#
            .write(to: nemo, atomically: true, encoding: .utf8)
        let pc = try ManifestBuilders.libriSpeechPC(set: "librispeech-pc-test-clean", nemoManifest: nemo,
                                                    audioRoot: dir.appendingPathComponent("LibriSpeech/test-clean"), cache: dir)
        #expect(pc.items.first?.audio == "1089/134686/1089-134686-0000.flac")
        #expect(pc.items.first?.reference == "He hoped there would be stew.")
        #expect(pc.audioRoot == "LibriSpeech/test-clean")
    }

    @Test func gatedAndLargeSetsRefuseToDownload() async {
        let paths = EvalPaths(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString)"),
                              fixturesDirectory: nil)
        await #expect(throws: EvalError.self) { try await DatasetFetcher(paths: paths, transport: NoNetwork()).fetch("svarah") }
        await #expect(throws: EvalError.self) { try await DatasetFetcher(paths: paths, transport: NoNetwork()).fetch("ami") }
    }
}

/// V1 acceptance (opt-in): fetch + score a real-model hypothesis file.
///   VOICEPLUS_EVAL_FETCH=librispeech-test-clean  → builds the manifest (downloads if absent)
///   VOICEPLUS_EVAL_HYP=<hyp file> VOICEPLUS_EVAL_SET=<set> → `lab eval --gate`, writes Lab/results
@Suite("Public-set acceptance (opt-in)", .serialized)
struct PublicEvalAcceptanceTests {
    @Test(.timeLimit(.minutes(30))) func fetchIfRequested() async throws {
        guard let set = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_FETCH"], !set.isEmpty else { return }
        let out = await LabCLI.main(["fetch", "--set", set])
        print(out.text)
        #expect(out.exitCode == 0)
    }

    @Test func scoreIfRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let hyp = env["VOICEPLUS_EVAL_HYP"], let set = env["VOICEPLUS_EVAL_SET"] else { return }
        let model = env["VOICEPLUS_EVAL_MODEL"] ?? "parakeet-tdt-v3"
        let out = await LabCLI.main(["eval", "--set", set, "--stage", "asr", "--model", model, "--hyp", hyp, "--gate"])
        print(out.text)
        #expect(out.exitCode == 0)
        let b = try #require(out.eval?.baseline)
        #expect(abs(b.delta) <= 0.3, "measured \(b.measured) vs published \(b.published)")
    }
}
