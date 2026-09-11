import Foundation
import Testing
import Shared
import Engine
import Lab
import Pipeline

/// R5.4 acceptance — **Parakeet vs Qwen vs the gated two-pass, by segment class, with latency and
/// memory** (V3 §5.4, §10.1, §10.2).
///
/// R5.3 (`GateRecallCorpusTests`, commits `45f4ec2` / `c903352`) already measured the corpus means
/// that switched `qwenRefinement` off: pass-1 0.0991, pass-2 0.1784, one segment of twenty improved,
/// seven made worse, 1.9–4.2 s against a 1500 ms deadline. What R5.4 owes on top of that is the
/// **breakdown**, because a mean can hide a class — a second pass could lose the corpus and still win
/// on names, on digits, on disfluent speech, or on the long end of the duration range, and the honest
/// response to that would be a *narrowed* gate rather than a dead flag. This test is the search for
/// such a class. It is written so that finding one and finding none are the same amount of work.
///
/// **The four arms.** Every arm sees the same audio and the same references, and every row is filed
/// into its classes by `SegmentClassifier` from the reference and the duration only.
///   1. `parakeet only` — Parakeet TDT 0.6B v3, the shipping recognizer. The baseline every
///      better/worse count is measured against.
///   2. `qwen only` — Qwen3-ASR 0.6B int8 (R5.1) as the *sole* recognizer, with the R4.1b ranked
///      context prompt. Not a shipping configuration; it answers "is the second model better at
///      recognition at all", independently of any gate.
///   3. `two-pass (gated)` — the shipping arrangement: Parakeet, then the real `RefineStage` on the
///      segments `RefinementGate(mode: .auto)` selects, under the real V3 §10.2 deadline of 1500 ms.
///   4. `two-pass (gated, deadline waived)` — identical, with the deadline lifted to ten minutes.
///      This arm exists because arm 3's deadline is known to be unmeetable on this hardware, and
///      without arm 4 the table would show only "the deadline expired" and say nothing about whether
///      the second pass has any accuracy to offer if it were ever fast enough.
///
/// **Measured 11 September 2026** (M2 Pro, 16 GB, debug build, `real-room/builtin`, 20 utterances —
/// the full table with its caveats is in `DECISIONS.md`, 2026-09-11):
///
///     class (n)         parakeet   qwen   two-pass(1500ms)  two-pass(waived)
///     all (20)             0.099  0.178             0.112             0.108
///     entities (7)         0.081  0.197             0.102             0.089
///     no entities (13)     0.109  0.168             0.118             0.118
///     >= 7 s (8)           0.182  0.335             0.200             0.200
///     digits (3)           0.405  0.738             0.405             0.405
///     number words (4)     0.045  0.044             0.045             0.023
///     latency p50/p95   121/130  2249/3792        128/1816          128/1420
///     peak footprint      90 MB  1866 MB           1883 MB           2003 MB
///
/// **No segment class wins.** The single cell that looks like one — number words with the deadline
/// waived — is one utterance (line 02's "standup" near-miss, the same segment R5.3 found), its
/// mechanism is context and not numbers, and it does not survive the 1500 ms deadline. Under the
/// shipping deadline the two-pass arm improved 0 segments and damaged 2. So `qwenRefinement` stays
/// off, no narrowed gate is proposed, and R5 is closed (V3 §5.4: either outcome completes the item).
///
/// **Peak memory is sampled, not estimated** (`PeakFootprint`, `phys_footprint`), and the figure is
/// per *process*: run this with `VOICEPLUS_REFINE_BENCH_ARMS` naming one arm to get that arm's
/// footprint on its own, or all four to get the cost of the whole two-pass configuration. The table
/// prints which models were resident for each arm, so no figure can be read as something it is not.
///
/// Opt-in (`VOICEPLUS_REFINE_BENCH=1`): forty-plus Qwen inferences on the ANE, minutes of wall clock,
/// heavy enough to disturb the timing assertions in the rest of the suite. Skips loudly — never
/// silently passes — when the corpus WAVs (git-ignored) or either model are absent. Nothing is ever
/// downloaded here.
@Suite("Refinement benchmark on the real corpus (R5.4, real models)", .serialized)
struct RefinementBenchmarkCorpusTests {

    // MARK: Arms

    enum Arm: String, CaseIterable, Equatable {
        case parakeet, qwen, twopass, waived

        var label: String {
            switch self {
            case .parakeet: return RefinementLabConfigs.parakeetOnly
            case .qwen: return RefinementLabConfigs.qwenOnly
            case .twopass: return RefinementLabConfigs.twoPass
            case .waived: return RefinementLabConfigs.twoPassDeadlineWaived
            }
        }

        var needsParakeet: Bool { self != .qwen }
        var needsQwen: Bool { self != .parakeet }

        var budget: String {
            switch self {
            case .parakeet: return "final p50 ≤ 700 ms · p95 ≤ 1200 ms"
            case .qwen: return "(not a shipping path)"
            case .twopass, .waived: return "refined p95 ≤ 1500 ms"
            }
        }
    }

    static let allArms = "parakeet,qwen,twopass,waived"

    /// Arms named in a comma-separated list, in `Arm.allCases` order (so the baseline arm stays first
    /// however the list is written).
    static func arms(from raw: String) -> [Arm] {
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Arm.allCases.filter { names.contains($0.rawValue) }
    }

    static func selectedArms() -> [Arm] {
        arms(from: ProcessInfo.processInfo.environment["VOICEPLUS_REFINE_BENCH_ARMS"] ?? allArms)
    }

    // MARK: Cheap invariants (always run — no models, no audio)

    /// `Lab` may not depend on `Pipeline`, so `RefinementLabConfigs.refineStageID` repeats the stage
    /// id as a literal. This is the assertion that keeps the copy honest; without it a rename in
    /// `Pipeline` would silently give the two-pass Lab arm a stage that does not exist.
    @Test func theTwoPassArmNamesTheRealRefineStage() {
        #expect(RefinementLabConfigs.refineStageID == StageID.refine.rawValue)
    }

    /// R5.4's acceptance is "the flag default is set from the table". The table (DECISIONS.md,
    /// 2026-09-11) found no segment class on which the second pass wins, so the default stays
    /// **off** — and this is the test that fails if someone flips it without a new measurement.
    @Test func theFlagDefaultMatchesTheDecisionsLog() {
        #expect(FeatureFlag.qwenRefinement.defaultOn == false,
                "R5.4 measured no winning segment class and the 1500 ms deadline unmet; flipping this on needs a new table in DECISIONS.md, not an edit here")
        #expect(ModelStack.refinementFlagID == FeatureFlag.qwenRefinement.id)
    }

    /// The arm selector is parsed from a string rather than read from the environment here: the
    /// benchmark is *meant* to be run one arm per process for an isolated peak-memory figure, so a
    /// test that asserted "the default is all four" would fail during exactly the runs the table needs.
    @Test func armsAreSelectableByNameAndTheBaselineStaysFirst() {
        #expect(Self.arms(from: Self.allArms).count == 4)
        #expect(Self.arms(from: "waived, parakeet") == [.parakeet, .waived])
        #expect(Self.arms(from: "qwen").map(\.label) == [RefinementLabConfigs.qwenOnly])
        #expect(Self.arms(from: "nonsense").isEmpty)
        #expect(Set(Arm.allCases.map(\.label)).count == 4)
        #expect(Arm.allCases.filter(\.needsQwen).count == 3)
        #expect(Arm.allCases.filter(\.needsParakeet).count == 3)
    }

    // MARK: The measurement

    /// Collects `RefineReport`s from the stage observer, which is `@Sendable` and called from the
    /// stage's own task.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var last: RefineReport?
        func record(_ report: RefineReport) { lock.lock(); last = report; lock.unlock() }
        func take() -> RefineReport? { lock.lock(); defer { last = nil; lock.unlock() }; return last }
    }

    @Test(.timeLimit(.minutes(60)))
    func werBySegmentClassLatencyAndMemory() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_REFINE_BENCH"] == "1" else {
            print("SKIPPED refinementBenchmark: set VOICEPLUS_REFINE_BENCH=1 (40+ Qwen inferences, "
                  + "minutes of ANE time). VOICEPLUS_REFINE_BENCH_ARMS=parakeet|qwen|twopass|waived "
                  + "selects arms, one per process, for an isolated peak-memory figure.")
            return
        }
        let arms = Self.selectedArms()
        guard !arms.isEmpty else {
            print("SKIPPED: VOICEPLUS_REFINE_BENCH_ARMS named no known arm.")
            return
        }
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        let (items, skip) = GateRecallCorpusTests.corpus(pass: pass)
        if let skip { print(skip); return }

        let manager = ModelManager(maintenance: .skip)
        if arms.contains(where: \.needsParakeet), await !manager.isPresent(.parakeetTDTv3) {
            print("SKIPPED: parakeet-tdt-0.6b-v3 is not on disk; nothing is downloaded here.")
            return
        }
        let weights = Qwen3WeightsStore()
        var qwenFolder: URL?
        if arms.contains(where: \.needsQwen) {
            if let reason = RefinementAvailability.unavailableReason {
                print("SKIPPED: refinement is unavailable on this Mac — \(reason).")
                return
            }
            guard let folder = weights.locate() else {
                print("SKIPPED: the Qwen3-ASR 0.6B int8 weights are not on disk (searched "
                      + weights.searchPaths.map(\.path).joined(separator: ", ") + "). Tests never download them.")
                return
            }
            qwenFolder = folder
        }
        guard #available(macOS 15, *) else {
            print("SKIPPED: macOS 15+ only — the refinement session is gated on it (V3 §5.3), so no arm "
                  + "of this benchmark can run on 14.")
            return
        }

        let (bench, out, gatedCount) = try await Self.measureCorpus(
            items: items, arms: arms, pass: pass, manager: manager, weights: weights, qwenFolder: qwenFolder)
        print(out)
        if let path = ProcessInfo.processInfo.environment["VOICEPLUS_REFINE_BENCH_OUT"] {
            try? out.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            print("(written to \(path))")
        }

        // MARK: acceptance
        //
        // What is asserted is that the measurement happened over every selected arm and that the
        // classes were assigned from the corpus. The *verdict* is not asserted: R5.4's outcome is a
        // table in DECISIONS.md, and a threshold here would be this corpus's numbers pretending to be
        // a contract (V3 §5.4: either outcome is a valid completion).
        #expect(bench.rows(arm: arms[0].label).count == items.count)
        for arm in arms { #expect(!bench.rows(arm: arm.label).isEmpty, "an arm produced no rows") }
        #expect(!bench.populatedClasses.isEmpty)
        #expect(gatedCount <= items.count)
        #expect(bench.arms.allSatisfy { $0.peakFootprintBytes != nil },
                "peak memory must be measured, not estimated — a nil here means the table must say 'not measured'")
    }

    /// The body of the benchmark, split out only because `Qwen3RefinementSession` is
    /// `@available(macOS 15, *)`: a variable of that type cannot be declared inside a function that
    /// also has to run on 14. Everything measured lives here; the test above decides whether to run it.
    @available(macOS 15, *)
    static func measureCorpus(items: [GateRecallCorpusTests.Item], arms: [Arm], pass: String,
                              manager: ModelManager, weights: Qwen3WeightsStore,
                              qwenFolder: URL?) async throws -> (RefinementBenchmark, String, Int) {
        // Footprint before a single model is resident, so every arm's figure has something to be
        // compared against.
        let baselineFootprint = PeakFootprint.currentBytes()

        var passOne: FinalRecognizer?
        var passTwo: Qwen3RefinementSession?
        var resident: [String] = []

        // The R4.1b context arrangement, exactly as R5.3 measured the gate with: one fixed screen for
        // all twenty utterances, the recent-words ring learning as it goes.
        let ring = RecentWordsRing()
        let session = ContextSession(harvester: ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText(GateRecallCorpusTests.screenBlocks)),
            CorrectionSource(store: MockCorrectionStore(
                corrections: GateRecallCorpusTests.correctedTerms.map { ($0, Date()) },
                dictionary: GateRecallCorpusTests.dictionaryTerms)),
            ring,
        ]))
        let builder = PromptBuilder()
        let contextGate = ContextGate()
        let gate = RefinementGate(mode: .auto)
        let classifier = SegmentClassifier()

        /// Pass-1 output, cached so the two-pass arms never re-run Parakeet (and so `qwen only` can be
        /// the one arm in a process without needing it at all).
        struct PassOne { var text: String; var spans: [TranscriptSpan]; var confidence: Float; var latencyMs: Double }
        var passOneByItem: [Int: PassOne] = [:]
        var promptByItem: [Int: PromptBuilder.Result] = [:]
        var nearMissesByItem: [Int: Int] = [:]
        var gatedByItem: [Int: Bool] = [:]
        var conditionsByItem: [Int: [RefinementGate.Reason]] = [:]

        var benchArms: [RefinementBenchmarkArm] = []
        var rows: [RefinementBenchmarkRow] = []
        var outcomeCounts: [String: [RefineOutcome: Int]] = [:]

        for arm in arms {
            if arm.needsParakeet, passOne == nil {
                passOne = try await RecognizerFactory.makeFinal(manager: manager)
                resident.append("parakeet-tdt-0.6b-v3")
            }
            if arm.needsQwen, passTwo == nil {
                let built = Qwen3RefinementSession(store: weights, language: .english)
                try await built.prepare()
                passTwo = built
                resident.append("qwen3-asr-0.6b-int8")
            }
            let footprint = PeakFootprint()
            footprint.sample()
            print("\n-- arm: \(arm.label) (resident: \(resident.joined(separator: " + ")))")

            for item in items {
                let samples = try SampleAudioSource.load16k(url: item.audio)
                let seconds = Double(samples.count) / 16_000
                let classes = classifier.classify(reference: item.reference, seconds: seconds)
                let id = String(format: "%02d", item.index)

                // Pass 1, once per item per process.
                if arm.needsParakeet, passOneByItem[item.index] == nil, let passOne {
                    let started = Date()
                    let spans = try await passOne.recognize(samples)
                    let latency = Date().timeIntervalSince(started) * 1000
                    let text = spans.map(\.text).joined(separator: " ")
                    let confidence = spans.isEmpty ? 0 : spans.map(\.confidence).reduce(0, +) / Float(spans.count)
                    passOneByItem[item.index] = PassOne(text: text, spans: spans, confidence: confidence,
                                                        latencyMs: latency)
                }

                // The context prompt and the gate decision, once per item, from pass-1 only.
                if promptByItem[item.index] == nil {
                    let ranked = session.rebuild()
                    let prompt = builder.build(ranked)
                    promptByItem[item.index] = prompt
                    if let one = passOneByItem[item.index] {
                        let decision = contextGate.decide(hypothesis: one.text, confidence: one.confidence,
                                                          context: ranked, prompt: prompt)
                        nearMissesByItem[item.index] = decision.nearMisses
                        let signals = RefinementGateSignals(
                            hypothesis: one.text, confidence: one.confidence,
                            nearMisses: decision.nearMisses, promptTerms: prompt.included,
                            segmentSeconds: seconds, languageHint: nil)
                        let verdict = gate.decide(signals)
                        gatedByItem[item.index] = verdict.shouldRefine
                        conditionsByItem[item.index] = verdict.conditions
                        ring.record(one.text)
                    }
                }
                let prompt = promptByItem[item.index]?.prompt ?? ""

                switch arm {
                case .parakeet:
                    guard let one = passOneByItem[item.index] else { continue }
                    rows.append(RefinementBenchmarkRow(
                        id: id, arm: arm.label, seconds: seconds, reference: item.reference,
                        hypothesis: one.text,
                        wer: WERScorer.score(reference: item.reference, hypothesis: one.text).wer,
                        latencyMs: one.latencyMs, classes: classes))

                case .qwen:
                    guard let passTwo else { continue }
                    let started = Date()
                    let refined = try await passTwo.refine(samples: samples, context: prompt,
                                                           deadline: .seconds(600))
                    let latency = Date().timeIntervalSince(started) * 1000
                    let text = refined.map(\.text).joined(separator: " ")
                    rows.append(RefinementBenchmarkRow(
                        id: id, arm: arm.label, seconds: seconds, reference: item.reference,
                        hypothesis: text,
                        wer: WERScorer.score(reference: item.reference, hypothesis: text).wer,
                        latencyMs: latency, classes: classes))

                case .twopass, .waived:
                    guard let one = passOneByItem[item.index], let passTwo else { continue }
                    let fired = gatedByItem[item.index] ?? false
                    guard fired else {
                        // The gate said no: this is pass-1 text at pass-1 latency, which is exactly
                        // what the user gets. Recorded as such, not skipped — a two-pass arm that
                        // only reports its gated segments would flatter itself.
                        rows.append(RefinementBenchmarkRow(
                            id: id, arm: arm.label, seconds: seconds, reference: item.reference,
                            hypothesis: one.text,
                            wer: WERScorer.score(reference: item.reference, hypothesis: one.text).wer,
                            latencyMs: one.latencyMs, classes: classes, gated: false))
                        outcomeCounts[arm.label, default: [:]][.disabled, default: 0] += 1
                        continue
                    }
                    let reports = Reports()
                    let deadline: Duration = arm == .twopass ? RefineStage.finalSegmentDeadline : .seconds(600)
                    let stage = RefineStage(
                        refiner: RefinerFunction(passTwo.refine(samples:context:deadline:)),
                        samples: samples, deadline: deadline, contextText: prompt,
                        observer: { reports.record($0) })
                    let started = Date()
                    let out = try await stage.process(one.spans, context: StageContext(
                        flags: [FeatureFlag.qwenRefinement.id: true]))
                    let stageLatency = Date().timeIntervalSince(started) * 1000
                    let report = reports.take()
                    let text = out.map(\.text).joined(separator: " ")
                    if let outcome = report?.outcome { outcomeCounts[arm.label, default: [:]][outcome, default: 0] += 1 }
                    rows.append(RefinementBenchmarkRow(
                        id: id, arm: arm.label, seconds: seconds, reference: item.reference,
                        hypothesis: text,
                        wer: WERScorer.score(reference: item.reference, hypothesis: text).wer,
                        latencyMs: one.latencyMs + stageLatency, classes: classes,
                        gated: true, timedOut: report?.outcome == .timedOut))
                }
                footprint.sample()
            }

            benchArms.append(RefinementBenchmarkArm(
                name: arm.label, peakFootprintBytes: footprint.peakBytes, latencyBudget: arm.budget,
                notes: "resident: \(resident.joined(separator: " + "))"))
        }
        session.discard()

        // MARK: the tables
        let label = "**Corpus** `Fixtures/real-room/\(pass)`, \(items.count) utterances, one speaker, one "
            + "room, one microphone. **Hardware** \(LabRunner.hardwareDescription()). "
            + "**Pass 1** \(passOne?.name ?? "not run") · **pass 2** qwen3-asr-0.6b-int8"
            + (qwenFolder.map { " (\($0.path))" } ?? "") + ". Debug build."
        let bench = RefinementBenchmark(arms: benchArms, rows: rows, label: label)

        var out = "\n== R5.4 benchmark ==\n\n### WER by segment class\n\n" + bench.classTable()
        out += "\n### Latency and peak memory\n\n" + bench.resourceTable()
        out += "\nFootprint baseline before any model was resident: "
        out += RefinementBenchmark.mb(baselineFootprint) + ". Peak is sampled `phys_footprint` "
        out += "(per process, so an arm's figure includes every model already loaded in this run).\n"
        out += "\n### Per utterance\n\n" + bench.itemTable()
        if !outcomeCounts.isEmpty {
            out += "\n### `RefineStage` outcomes (two-pass arms)\n\n"
            for arm in benchArms.map(\.name) {
                guard let counts = outcomeCounts[arm] else { continue }
                let rendered = counts.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: " · ")
                out += "- \(arm): \(rendered) (`disabled` = the gate did not fire, so the pass never ran)\n"
            }
        }
        let gatedCount = gatedByItem.values.filter { $0 }.count
        out += "\nGate fired on \(gatedCount)/\(items.count) segments (auto, default settings); "
        out += "deadline under test \(RefinementClock.milliseconds(RefineStage.finalSegmentDeadline)) ms.\n"
        out += "**n is small in every class** (the whole corpus is \(items.count) utterances); no row here "
        out += "carries statistical weight on its own.\n"
        return (bench, out, gatedCount)
    }

    /// The same three arms over the synthetic suites (`Fixtures/audio`, `Lab/FIXTURES.md`), which are
    /// TTS and therefore an upper bound — `Lab/FIXTURES.md` says kill-criteria decisions must not be
    /// taken on them. They are run because R5.4 asks for them and because they are the only suites
    /// with per-class *labels of their own* (clean / noisy / entity / technical / commands), which is
    /// an independent check on the real corpus's classes: if the second pass wins anywhere, the
    /// suite that names that condition should show it too.
    ///
    /// Separate opt-in (`VOICEPLUS_REFINE_BENCH_SUITES=1`): 61 files × two models.
    @Test(.timeLimit(.minutes(60)))
    func werBySuiteOnTheSyntheticFixtures() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_REFINE_BENCH_SUITES"] == "1" else {
            print("SKIPPED refinementBenchmarkSuites: set VOICEPLUS_REFINE_BENCH_SUITES=1 (61 files × 2 models).")
            return
        }
        guard let fixtures = AppPaths.fixturesDirectory() else { print("SKIPPED: no Fixtures directory."); return }
        let runner = LabRunner(fixturesDirectory: fixtures)
        let suites = try FixtureSuite.defaultNames.map { try FixtureSuite.load(named: $0, fixturesDirectory: fixtures) }
        guard suites.contains(where: { !$0.items.isEmpty }) else { print("SKIPPED: no fixture items."); return }

        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: Parakeet is not on disk."); return }
        let weights = Qwen3WeightsStore()
        guard RefinementAvailability.isAvailable, weights.locate() != nil else {
            print("SKIPPED: refinement is unavailable or the Qwen weights are not on disk.")
            return
        }
        guard #available(macOS 15, *) else { print("SKIPPED: macOS 15+ only."); return }

        let passOne = try await RecognizerFactory.makeFinal(manager: manager)
        let passTwo = Qwen3RefinementSession(store: weights, language: .english)
        try await passTwo.prepare()
        let classifier = SegmentClassifier()
        let footprintParakeet = PeakFootprint()
        let footprintQwen = PeakFootprint()

        var rows: [RefinementBenchmarkRow] = []
        var perSuite: [String: (one: Double, two: Double, n: Int)] = [:]
        for suite in suites {
            for item in suite.items {
                let samples = try SampleAudioSource.load16k(url: suite.audioURL(for: item))
                let seconds = Double(samples.count) / 16_000
                let classes = classifier.classify(reference: item.transcript, seconds: seconds)

                var started = Date()
                let spans = try await passOne.recognize(samples)
                let oneLatency = Date().timeIntervalSince(started) * 1000
                let oneText = spans.map(\.text).joined(separator: " ")
                footprintParakeet.sample()

                // The synthetic suites carry no screen context, so the prompt is the suite's own
                // entity list — the most favourable honest prompt for the second pass.
                let prompt = (item.entities ?? EntityScorer.detectEntities(in: item.transcript)).joined(separator: ", ")
                started = Date()
                let refined = try await passTwo.refine(samples: samples, context: prompt, deadline: .seconds(600))
                let twoLatency = Date().timeIntervalSince(started) * 1000
                let twoText = refined.map(\.text).joined(separator: " ")
                footprintQwen.sample()

                let one = WERScorer.score(reference: item.transcript, hypothesis: oneText).wer
                let two = WERScorer.score(reference: item.transcript, hypothesis: twoText).wer
                rows.append(RefinementBenchmarkRow(id: item.id, arm: RefinementLabConfigs.parakeetOnly,
                                                   seconds: seconds, reference: item.transcript,
                                                   hypothesis: oneText, wer: one, latencyMs: oneLatency,
                                                   classes: classes))
                rows.append(RefinementBenchmarkRow(id: item.id, arm: RefinementLabConfigs.qwenOnly,
                                                   seconds: seconds, reference: item.transcript,
                                                   hypothesis: twoText, wer: two, latencyMs: twoLatency,
                                                   classes: classes))
                var acc = perSuite[suite.name] ?? (0, 0, 0)
                acc.one += one; acc.two += two; acc.n += 1
                perSuite[suite.name] = acc
            }
        }

        let bench = RefinementBenchmark(
            arms: [RefinementBenchmarkArm(name: RefinementLabConfigs.parakeetOnly,
                                          peakFootprintBytes: footprintParakeet.peakBytes,
                                          latencyBudget: "final p50 ≤ 700 ms · p95 ≤ 1200 ms",
                                          notes: "resident: parakeet"),
                   RefinementBenchmarkArm(name: RefinementLabConfigs.qwenOnly,
                                          peakFootprintBytes: footprintQwen.peakBytes,
                                          latencyBudget: "(not a shipping path)",
                                          notes: "resident: parakeet + qwen")],
            rows: rows,
            label: "**Synthetic suites** (`Fixtures/audio`, TTS — an upper bound, see `Lab/FIXTURES.md`). "
                + "Hardware \(LabRunner.hardwareDescription()). Debug build.")

        var out = "\n== R5.4 benchmark · synthetic suites ==\n\n" + bench.classTable()
        out += "\n| Suite | n | parakeet WER | qwen WER |\n|---|---:|---:|---:|\n"
        for (name, acc) in perSuite.sorted(by: { $0.key < $1.key }) {
            out += String(format: "| %@ | %d | %.3f | %.3f |\n", name, acc.n,
                          acc.one / Double(acc.n), acc.two / Double(acc.n))
        }
        out += "\n" + bench.resourceTable()
        print(out)
        if let path = ProcessInfo.processInfo.environment["VOICEPLUS_REFINE_BENCH_SUITES_OUT"] {
            try? out.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }

        #expect(bench.rows(arm: RefinementLabConfigs.parakeetOnly).count == rows.count / 2)
        #expect(!perSuite.isEmpty)
    }
}
