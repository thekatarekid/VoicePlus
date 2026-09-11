import Foundation
import Testing
import Shared
@testable import Lab

/// R5.4 — the cheap half of the benchmark: the segment classifier, the aggregation, and the three
/// Lab configurations. No models, no audio, no ANE; the real two-pass run lives in
/// `Tests/AppTests/RefinementBenchmarkCorpusTests.swift` behind `VOICEPLUS_REFINE_BENCH=1`.
@Suite("Refinement benchmark scaffolding (R5.4)")
struct RefinementBenchmarkTests {

    /// The twenty Appendix A lines, so the classifier is tested on the corpus it will classify and a
    /// future edit to the rules shows up here as a changed class membership rather than in a report.
    static let script: [String] = [
        "The quick brown fox jumps over the lazy dog.",
        "Send the deck to Priya before the standup tomorrow at four.",
        "Can you book a table for six at Kothari's on Thursday evening?",
        "My flight lands at 11:45, so let's meet at the gate around noon.",
        "The invoice total is 2,340 rupees, not 2,430.",
        "Rename the variable to user session token and push it to the main branch.",
        "I think we should, um, wait for the numbers before we decide.",
        "Order two of the large ones and one of the small ones.",
        "Hey, are you free for a quick call?",
        "The results were significant, although the effect size was small.",
        "Their new address is 14 Carter Road, Bandra, Mumbai 400050.",
        "Remind me to call Dr. Menon on Monday morning.",
        "Turn off the recording when you are done.",
        "What time does the museum open on Sundays?",
        "She said the quarterly report would be ready by Friday, but I doubt it.",
        "Please transcribe this exactly as I say it, including the pause... here.",
        "Run swift build with the isolated scratch path and send me the output.",
        "We have three options: ship now, ship next week, or do not ship at all.",
        "The microphone is about an arm's length away and the window is open.",
        "Thanks, that is everything for today, talk soon.",
    ]

    // MARK: Classifier

    @Test func durationClassesPartitionTheCorpusRange() {
        let classifier = SegmentClassifier()
        #expect(classifier.durationClass(seconds: 3.7) == .durationShort)
        #expect(classifier.durationClass(seconds: 4.999) == .durationShort)
        #expect(classifier.durationClass(seconds: 5) == .durationMedium)
        #expect(classifier.durationClass(seconds: 6.9) == .durationMedium)
        #expect(classifier.durationClass(seconds: 7) == .durationLong)
        #expect(classifier.durationClass(seconds: 9.4) == .durationLong)
        #expect(classifier.durationClass(seconds: nil) == nil)
        // Exactly one duration class ever applies.
        for seconds in stride(from: 1.0, through: 20.0, by: 0.5) {
            let classes = classifier.classify(reference: "hello there", seconds: seconds)
            #expect(classes.intersection(Set(SegmentClass.durationAxis)).count == 1)
        }
    }

    @Test func digitsAndNumberWordsAreDifferentClasses() {
        let classifier = SegmentClassifier()
        // Line 05 — written digits, no spelled quantity.
        let digits = classifier.classify(reference: Self.script[4])
        #expect(digits.contains(.writtenDigits))
        #expect(!digits.contains(.spokenNumbers))
        // Line 08 — spelled quantities, no digit anywhere.
        let words = classifier.classify(reference: Self.script[7])
        #expect(words.contains(.spokenNumbers))
        #expect(!words.contains(.writtenDigits))
    }

    @Test func disfluencyAndPauseAreTheTwoUtterancesThatCarryThem() {
        let classifier = SegmentClassifier()
        let disfluent = Self.script.indices.filter { classifier.classify(reference: Self.script[$0]).contains(.disfluency) }
        let paused = Self.script.indices.filter { classifier.classify(reference: Self.script[$0]).contains(.explicitPause) }
        // Line 07 is the only "um" in the corpus; line 16 the only explicit pause.
        #expect(disfluent == [6])
        #expect(paused == [15])
    }

    @Test func entitiesSplitTheCorpusAndEveryUtteranceLandsOnOneSide() {
        let classifier = SegmentClassifier()
        var withEntities = 0
        for line in Self.script {
            let classes = classifier.classify(reference: line)
            #expect(classes.contains(.entities) != classes.contains(.noEntities))
            if classes.contains(.entities) { withEntities += 1 }
        }
        // Seven of twenty carry a detected entity, and this is the exact membership the R5.4 table
        // reports as "speech with names" versus "clean speech", so a change here changes what that
        // decision means:
        //   02 Priya · 03 Kothari's, Thursday · 11 Carter, Road, Bandra, Mumbai · 12 Monday ·
        //   14 Sundays · 15 Friday · 17 swift
        // Note what the heuristic *misses*: "Menon" in line 12, because `Dr.` ends in a full stop and
        // the next token is therefore read as sentence-initial. Day names, meanwhile, are counted.
        // The class is "capitalised-token-bearing speech", not a curated name list — the R5.4 table
        // says so rather than claiming more.
        #expect(withEntities == 7, "entity membership moved: re-read the R5.4 table before trusting it")
    }

    @Test func technicalIsTheTwoCodeDictationLines() {
        let classifier = SegmentClassifier()
        let technical = Self.script.indices.filter { classifier.classify(reference: Self.script[$0]).contains(.technical) }
        #expect(technical == [5, 16])
    }

    @Test func theClassifierNeverSeesAHypothesis() {
        // Same reference, two very different hypotheses: classification must be identical, because it
        // is a property of the corpus and not of an arm's performance.
        let classifier = SegmentClassifier()
        let a = classifier.classify(reference: Self.script[1], seconds: 6)
        let b = classifier.classify(reference: Self.script[1], seconds: 6)
        #expect(a == b)
        #expect(a.contains(.entities))
    }

    // MARK: Aggregation

    /// Two arms over four utterances, arranged so that the second arm loses on the corpus mean while
    /// winning inside one class — exactly the shape R5.4 exists to detect. If the aggregation cannot
    /// surface that, the real run's table cannot either.
    static func fixture() -> RefinementBenchmark {
        let classifier = SegmentClassifier()
        func row(_ id: String, _ arm: String, _ reference: String, _ wer: Double, _ latency: Double,
                 _ seconds: TimeInterval) -> RefinementBenchmarkRow {
            RefinementBenchmarkRow(id: id, arm: arm, seconds: seconds, reference: reference,
                                   hypothesis: wer == 0 ? reference : "wrong words here",
                                   wer: wer, latencyMs: latency,
                                   classes: classifier.classify(reference: reference, seconds: seconds))
        }
        let clean = "Turn off the recording when you are done."
        let named = "Send the deck to Priya before the standup tomorrow at four."
        let rows = [
            row("01", "a", clean, 0.0, 400, 4.0),
            row("02", "a", clean, 0.0, 500, 4.2),
            row("03", "a", named, 0.20, 600, 6.0),
            row("04", "a", named, 0.20, 700, 8.0),
            row("01", "b", clean, 0.40, 2_000, 4.0),
            row("02", "b", clean, 0.40, 2_400, 4.2),
            row("03", "b", named, 0.10, 3_000, 6.0),
            row("04", "b", named, 0.10, 4_000, 8.0),
        ]
        return RefinementBenchmark(
            arms: [RefinementBenchmarkArm(name: "a", peakFootprintBytes: 800 * 1024 * 1024,
                                          latencyBudget: "p95 ≤ 1200 ms"),
                   RefinementBenchmarkArm(name: "b", latencyBudget: "p95 ≤ 1500 ms")],
            rows: rows, label: "fixture")
    }

    @Test func aClassCanWinWhileTheMeanLoses() {
        let bench = Self.fixture()
        #expect(bench.meanWER(arm: "a") == 0.10)
        #expect(bench.meanWER(arm: "b") == 0.25)
        // …and yet, on the entity class, arm b is ahead.
        #expect(bench.meanWER(arm: "a", in: .entities) == 0.20)
        #expect(bench.meanWER(arm: "b", in: .entities) == 0.10)
        let entity = bench.versusBaseline(arm: "b", in: .entities)
        #expect((entity.better, entity.worse, entity.same) == (2, 0, 0))
        let clean = bench.versusBaseline(arm: "b", in: .noEntities)
        #expect((clean.better, clean.worse, clean.same) == (0, 2, 0))
    }

    @Test func pooledAndMeanWERAreBothReported() {
        let bench = Self.fixture()
        // Reference lengths differ (8 words vs 11), so pooled ≠ mean — the reason both are printed.
        let pooled = try? #require(bench.pooledWER(arm: "a"))
        #expect(pooled != nil)
        let errors: Double = 2 * 0.20 * 11
        let words: Double = 2 * 8 + 2 * 11
        let expected: Double = errors / words
        #expect(abs((pooled ?? 0) - expected) < 1e-9)
    }

    @Test func classCountsComeFromTheBaselineArmOnly() {
        let bench = Self.fixture()
        #expect(bench.count(in: .entities) == 2)
        #expect(bench.count(in: .noEntities) == 2)
        #expect(bench.baselineArm == "a")
    }

    @Test func emptyClassesAreLeftOutRatherThanPrintedBlank() {
        let bench = Self.fixture()
        #expect(!bench.populatedClasses.contains(.disfluency))
        #expect(bench.populatedClasses.contains(.durationShort))
        #expect(bench.populatedClasses == SegmentClass.reportingOrder.filter { bench.count(in: $0) > 0 })
    }

    @Test func latencyPercentilesAndTablesRender() {
        let bench = Self.fixture()
        #expect(bench.latencyPercentile(arm: "a", p: 50) == 500)
        #expect(bench.latencyPercentile(arm: "a", p: 95) == 700)
        #expect(bench.latencyPercentile(arm: "b", p: 95) == 4_000)

        let classes = bench.classTable()
        #expect(classes.contains("| Segment class | n | a WER | b WER | b better/worse |"))
        #expect(classes.contains("entities"))
        #expect(classes.contains("Classes overlap"))

        let resources = bench.resourceTable()
        #expect(resources.contains("800 MB"))
        // Arm b measured no footprint, and the table must say so rather than print a guess.
        #expect(resources.contains("not measured"))
        #expect(resources.contains("p95 ≤ 1500 ms"))

        let items = bench.itemTable()
        #expect(items.contains("| 01 |"))
        #expect(items.contains("no entities"))
    }

    @Test func missingRowsInAnArmAreSkippedNotCountedAsWins() {
        var bench = Self.fixture()
        bench.rows.removeAll { $0.arm == "b" && $0.id == "03" }
        let entity = bench.versusBaseline(arm: "b", in: .entities)
        #expect((entity.better, entity.worse, entity.same) == (1, 0, 0))
        #expect(bench.rows(arm: "b").count == 3)
    }

    @Test func peakFootprintSamplesRealMemoryOrReportsNothing() {
        let peak = PeakFootprint()
        #expect(peak.peakBytes == nil)
        guard PeakFootprint.currentBytes() != nil else {
            // A kernel that refuses the query must leave the field nil, never zero-as-a-number.
            #expect(peak.sample() == nil)
            #expect(peak.peakBytes == nil)
            return
        }
        let first = peak.sample()
        #expect(first != nil)
        // Hold ~40 MB so the second sample cannot be lower than the first.
        var ballast = [UInt8](repeating: 7, count: 40 * 1024 * 1024)
        ballast[ballast.count - 1] = 9
        let second = peak.sample()
        #expect(second != nil)
        #expect((peak.peakBytes ?? 0) >= max(first ?? 0, second ?? 0))
        #expect(ballast.last == 9)
        peak.reset()
        #expect(peak.peakBytes == nil)
    }

    // MARK: The three Lab configurations

    @Test func threeArmsAreOfferedUnselectedWithTheFlagSetPerArm() {
        let choices = LabConfigChoice.refinementChoices()
        #expect(choices.count == 3)
        #expect(choices.allSatisfy { !$0.selected })
        #expect(choices.map(\.config.name) == [RefinementLabConfigs.parakeetOnly,
                                               RefinementLabConfigs.qwenOnly,
                                               RefinementLabConfigs.twoPass])
        let flag = FeatureFlag.qwenRefinement.id
        #expect(choices[0].config.flags[flag] == false)
        #expect(choices[1].config.flags[flag] == true)
        #expect(choices[2].config.flags[flag] == true)
    }

    @Test func onlyTheTwoPassArmRunsTheRefineStage() {
        let choices = LabConfigChoice.refinementChoices(transcriber: "engine", qwenTranscriber: "qwen",
                                                        stages: ["pipeline"])
        #expect(choices[0].config.stages == ["pipeline"])
        #expect(choices[1].config.stages == ["pipeline"])
        #expect(choices[2].config.stages == ["pipeline", RefinementLabConfigs.refineStageID])
        #expect(choices[0].config.transcriber == "engine")
        #expect(choices[1].config.transcriber == "qwen")
        #expect(choices[2].config.transcriber == "engine")
    }

    @Test func aMockRunNeverNamesATranscriberItCannotResolve() {
        // Default `qwenTranscriber` follows `transcriber`, so the choices are runnable against
        // `LabRegistry.mocks` (which has no Qwen) without a "unknown transcriber" failure.
        let choices = LabConfigChoice.refinementChoices(transcriber: "perfect")
        #expect(Set(choices.map(\.config.transcriber)) == ["perfect"])
    }

    @Test func armsCanBePointedAtASubsetOfSuites() {
        let choices = LabConfigChoice.refinementChoices(suites: ["clean", "entity"])
        #expect(choices.allSatisfy { $0.config.suites == ["clean", "entity"] })
    }

    /// The mock arms must actually run end to end, so a panel selection cannot fail on wiring.
    @Test func theArmsRunAgainstTheMockRegistry() async throws {
        guard let fixtures = AppPaths.fixturesDirectory(),
              FileManager.default.fileExists(atPath: FixtureSuite.audioRoot(fixturesDirectory: fixtures)!.path) else {
            print("SKIPPED: no Fixtures/audio next to the package.")
            return
        }
        let runner = LabRunner(fixturesDirectory: fixtures)
        for choice in LabConfigChoice.refinementChoices(suites: ["clean"]) {
            var config = choice.config
            config.stages = []       // the mock registry has no real refine stage; arms differ by flag here
            let suites = try runner.loadSuites(config)
            let transcriber = try LabRegistry.mocks.transcriber(config.transcriber, suites: suites)
            let report = try await runner.run(config: config, transcriber: transcriber, stages: [])
            #expect(report.overall.items > 0)
            #expect(report.overall.wer == 0, "the perfect transcriber must score 0 in every arm")
        }
    }
}
