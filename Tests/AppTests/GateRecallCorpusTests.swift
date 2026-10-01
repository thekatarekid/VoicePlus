import Foundation
import Testing
import Shared
import Engine
import Lab
import Pipeline

/// R5.3 acceptance — **gate recall and precision on the real-room corpus.**
///
/// The question this answers: of the segments a second pass would actually improve, what fraction
/// does `RefinementGate` select — and of the segments it selects, what fraction does the second pass
/// actually improve? A gate that fires on everything has perfect recall and is worthless, so both
/// numbers are printed together or neither is.
///
/// **How "would actually improve" is decided.** Not by a proxy and not by a rewriter: both passes
/// are run for real on the same audio and scored against `Fixtures/real-room/script.md`.
///   - **Pass 1** — Parakeet TDT 0.6B v3, the shipping recognizer, on the processed WAV.
///   - **Pass 2** — Qwen3-ASR 0.6B int8 (R5.1) on the *same* samples, with the R4.1b ranked-context
///     prompt as its context string.
///   - A segment **is improvable** when pass-2 WER < pass-1 WER. Ties (including 0.000 = 0.000,
///     which is most of this corpus) are not improvable: there is nothing for the gate to win.
/// The gate never sees a reference, a WER or pass-2 text; it sees exactly what it sees in
/// production — pass-1 text, pass-1 confidence, the near-miss count from `ContextGate`, the prompt
/// size, and the segment duration.
///
/// **What this measurement is and is not.** It is a real two-pass measurement on twenty real
/// dictations. It is *not* a statement about long-form speech (the corpus has none: 3.6–9.3 s, one
/// sentence each), about non-English speech (the corpus is English), or about any second pass other
/// than this one — Qwen 0.6B, which on this corpus is the weaker model overall (mean WER 0.1724 vs
/// Parakeet's 0.0990, `c6c8887`). Two of the four gate conditions therefore cannot fire on this
/// corpus at all, and the report says so instead of implying coverage it does not have.
///
/// **Measured 11 September 2026** (M2 Pro, `real-room/builtin`, 20 utterances, R4.1b's workspace):
///
///     pass1 mean WER 0.0991 · pass2 mean WER 0.1784 · improvable 1/20 · pass 2 made 7 worse
///     gate (auto, default)   fired  6/20  recall 1.000 (1/1)  precision 0.167 (1/6)  harmed 2
///     always (reference)     fired 20/20  recall 1.000 (1/1)  precision 0.050 (1/20) harmed 7
///     never  (reference)     fired  0/20  recall 0.000 (0/1)  precision n/a          harmed 0
///     conditions that fired: contextNearMiss 6 · lowConfidence 0 · nonEnglish 0 · longSegment 0
///
/// Three things in that table matter more than the recall number:
///   - **The one improvable segment is the near-miss case**, line 02: pass 1 heard "stand-up" where
///     the screen said "standup", pass 2 with the prompt got it (WER 0.182 → 0.091). The condition
///     that exists for this fired on it.
///   - **Pass-1 confidence never fired.** Parakeet scored 0.81–1.00 on every utterance, including
///     the ones it got wrong (line 05, WER 0.800, confidence 0.93). V3 §5.3's warning — "do not
///     assume the recognizer knows when it is wrong" — is the measurement, not a caveat: on this
///     corpus condition 1 contributes nothing and the near-miss condition carries the gate.
///   - **Precision is low because pass 2 is the weaker model**, not because the gate is loose:
///     Always is 0.050 and harms 7 segments, the gate is 0.167 and harms 2. The gate cuts the damage
///     of a bad second pass by ~3×, which is the most a gate can do about a model that loses.
///
/// Opt-in (`VOICEPLUS_GATE_RECALL=1`): twenty Qwen inferences on the ANE, minutes of wall clock.
/// Skips loudly — never silently passes — when the corpus WAVs (git-ignored) or either model are
/// absent. Nothing is ever downloaded here.
@Suite("Gate recall on the real corpus (R5.3, real models)", .serialized)
struct GateRecallCorpusTests {

    // MARK: The simulated workspace
    //
    // The same fixed screen R4.1b measured its ranked list against (its own copy lives in
    // `Tests/EngineTests/ContextRecallCorpusTests.swift`, which this target cannot import): the
    // corpus's own names alongside sixty unrelated ones, several of them sound-alikes of words the
    // corpus gets *right*. One workspace for all twenty utterances, never per-utterance tailoring —
    // a screen cooked per line would manufacture near misses and with them a flattering gate.

    static let screenBlocks: [(String, Double)] = [
        ("Kothari's — table for six — Thursday", 1.0),
        ("Priya Sharma · standup · deck review", 0.9),
        ("14 Carter Road, Bandra, Mumbai 400050", 0.8),
        ("Dr Menon · Monday morning · clinic", 0.8),
        ("Friday quarterly report · effect size", 0.7),
        ("swift build --scratch-path .build-r53", 0.7),
        ("Devanagari transliteration notes", 0.6),
        ("Priyanka Bandana Menendez Mumbles Cartier Fridge Swifty Kothary", 0.5),
        ("TeamViewer AG Sundar Pichai Anthropic GRDB FluidAudio kubectl", 0.5),
        ("Zsh SQLite Devanagari Bengaluru Chennai Kolkata Hyderabad Pune", 0.5),
        ("Aarav Ananya Vihaan Diya Reyansh Ishaan Saanvi Aditi Kabir Myra", 0.5),
        ("Rohan Neha Arjun Kavya Nikhil Shreya Varun Pooja Manav Riya", 0.5),
        ("Quartermaster Lazarus Foxglove Museo Sundaes Recorded Gateway", 0.4),
        ("Invoice Rupees Deckhand Standoff Sessions Tokenizer Branches", 0.4),
    ]
    static let dictionaryTerms: [(term: String, weight: Double)] = [("Kothari", 1.0), ("Devanagari", 1.0)]
    static let correctedTerms: [String] = ["Priya", "Menon"]

    // MARK: Corpus
    //
    // `RealRoomCorpus` lives in `EngineTests` and no test target can import another, so this is the
    // same pairing rule stated again: recordings sort chronologically by filename, the script is
    // read once top to bottom, so the n-th recording is line n — and if the counts disagree, no
    // pairing is trustworthy and the suite skips rather than scoring a guess.

    struct Item { let index: Int; let audio: URL; let reference: String }

    static func corpus(pass: String = "builtin") -> (items: [Item], skip: String?) {
        guard let fixtures = AppPaths.fixturesDirectory() else {
            return ([], "SKIPPED: no Fixtures directory next to the package.")
        }
        let root = fixtures.appendingPathComponent("real-room", isDirectory: true)
        let dir = root.appendingPathComponent(pass, isDirectory: true)
        let script = scriptLines(at: root.appendingPathComponent("script.md"))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix("-processed.wav") }
            .sorted()
        guard !files.isEmpty else {
            return ([], "SKIPPED: Fixtures/real-room/\(pass) has no WAVs (they are git-ignored).")
        }
        guard files.count == script.count else {
            return ([], "SKIPPED: \(files.count) WAVs but \(script.count) script lines — the pairing would be a guess.")
        }
        let items = files.enumerated().map {
            Item(index: $0.offset + 1, audio: dir.appendingPathComponent($0.element), reference: script[$0.offset])
        }
        return (items, nil)
    }

    static func scriptLines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 4, line.prefix(2).allSatisfy(\.isNumber) else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { lines.append(body) }
        }
        return lines
    }

    // MARK: One row of the table

    struct Row {
        var index: Int
        var seconds: Double
        var words: Int
        var confidence: Float
        var nearMisses: Int
        var promptTerms: Int
        var werPassOne: Double
        var werPassTwo: Double
        var conditions: [RefinementGate.Reason]
        var gated: Bool
        var improvable: Bool { werPassTwo < werPassOne - 1e-9 }
        var damaged: Bool { werPassTwo > werPassOne + 1e-9 }
    }

    /// recall, precision and the confusion matrix for one set of rows.
    struct Verdict {
        var truePositive = 0, falsePositive = 0, falseNegative = 0, trueNegative = 0
        var recall: Double? {
            let improvable = truePositive + falseNegative
            return improvable == 0 ? nil : Double(truePositive) / Double(improvable)
        }
        var precision: Double? {
            let fired = truePositive + falsePositive
            return fired == 0 ? nil : Double(truePositive) / Double(fired)
        }
        /// Fired-on segments the second pass made *worse* — the cost of a false positive, when
        /// pass 2 is the weaker model.
        var damagedAndFired = 0

        static func over(_ rows: [Row]) -> Verdict {
            var v = Verdict()
            for row in rows {
                switch (row.improvable, row.gated) {
                case (true, true): v.truePositive += 1
                case (true, false): v.falseNegative += 1
                case (false, true): v.falsePositive += 1
                case (false, false): v.trueNegative += 1
                }
                if row.gated, row.damaged { v.damagedAndFired += 1 }
            }
            return v
        }

        func line(_ label: String) -> String {
            let recall = recall.map { String(format: "%.3f", $0) } ?? "n/a"
            let precision = precision.map { String(format: "%.3f", $0) } ?? "n/a"
            return String(format: "%-22@ fired %2d/%2d  recall %@ (%d/%d)  precision %@ (%d/%d)  harmedByFiring %d",
                          label as NSString, truePositive + falsePositive,
                          truePositive + falsePositive + falseNegative + trueNegative,
                          recall as NSString, truePositive, truePositive + falseNegative,
                          precision as NSString, truePositive, truePositive + falsePositive,
                          damagedAndFired)
        }
    }

    // MARK: The measurement

    @Test(.timeLimit(.minutes(60)))
    func gateRecallAndPrecisionOnTheRealRoomCorpus() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_GATE_RECALL"] == "1" else {
            print("SKIPPED gateRecall: set VOICEPLUS_GATE_RECALL=1 (20 Qwen inferences, minutes of ANE time).")
            return
        }
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        let (items, skip) = Self.corpus(pass: pass)
        if let skip { print(skip); return }

        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 is not on disk; nothing is downloaded here.")
            return
        }
        let weights = Qwen3WeightsStore()
        if let reason = RefinementAvailability.unavailableReason {
            print("SKIPPED: refinement is unavailable on this Mac — \(reason).")
            return
        }
        guard let folder = weights.locate() else {
            print("""
                SKIPPED: the Qwen3-ASR 0.6B int8 weights are not on disk (searched \
                \(weights.searchPaths.map(\.path).joined(separator: ", "))). Tests never download them.
                """)
            return
        }

        let passOne = try await RecognizerFactory.makeFinal(manager: manager)
        let passTwo = Qwen3RefinementSession(store: weights, language: .english)
        try await passTwo.prepare()

        // R4.1b's list, rebuilt before every utterance, with the recent-words ring learning as it
        // goes — the production arrangement (V3 §7.3).
        let ring = RecentWordsRing()
        let harvester = ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText(Self.screenBlocks)),
            CorrectionSource(store: MockCorrectionStore(
                corrections: Self.correctedTerms.map { ($0, Date()) },
                dictionary: Self.dictionaryTerms)),
            ring,
        ])
        let session = ContextSession(harvester: harvester)
        let builder = PromptBuilder()
        let contextGate = ContextGate()
        let gate = RefinementGate(mode: .auto)

        var rows: [Row] = []
        var promptCharacters = 0
        var rankedTerms = 0
        var passTwoLatencies: [Double] = []

        for item in items {
            let samples = try SampleAudioSource.load16k(url: item.audio)
            let seconds = Double(samples.count) / 16_000

            let spans = try await passOne.recognize(samples)
            let hypothesis = spans.map(\.text).joined(separator: " ")
            let confidence = spans.isEmpty ? 0 : spans.map(\.confidence).reduce(0, +) / Float(spans.count)

            let ranked = session.rebuild()
            let prompt = builder.build(ranked)
            promptCharacters = max(promptCharacters, prompt.prompt.count)
            rankedTerms = max(rankedTerms, ranked.count)

            // Conditions 1 and 2 come from the list's own gate (Engine/Biasing); 3 and 4 from the
            // policy. The gate is handed no reference and no pass-2 text.
            let contextDecision = contextGate.decide(hypothesis: hypothesis, confidence: confidence,
                                                     context: ranked, prompt: prompt)
            let signals = RefinementGateSignals(
                hypothesis: hypothesis, confidence: confidence,
                nearMisses: contextDecision.nearMisses, promptTerms: prompt.included,
                segmentSeconds: seconds,
                // Nothing in the shipping path reports a per-utterance language, so the gate gets
                // no hint — exactly as in production. Script evidence is all it has.
                languageHint: nil)
            let decision = gate.decide(signals)

            let started = Date()
            let refined = try await passTwo.refine(samples: samples, context: prompt.prompt,
                                                   deadline: .seconds(600))
            passTwoLatencies.append(Date().timeIntervalSince(started))
            let refinedText = refined.map(\.text).joined(separator: " ")

            let one = WERScorer.score(reference: item.reference, hypothesis: hypothesis)
            let two = WERScorer.score(reference: item.reference, hypothesis: refinedText)
            rows.append(Row(index: item.index, seconds: seconds,
                            words: signals.wordCount, confidence: confidence,
                            nearMisses: contextDecision.nearMisses, promptTerms: prompt.included,
                            werPassOne: one.wer, werPassTwo: two.wer,
                            conditions: decision.conditions, gated: decision.shouldRefine))
            print(String(format: "%02d  %4.1fs  conf %.2f  near %d  wer1 %.3f  wer2 %.3f  %@  %@",
                         item.index, seconds, confidence, contextDecision.nearMisses,
                         one.wer, two.wer,
                         decision.shouldRefine ? "GATE-ON " : "gate-off",
                         decision.conditions.map(\.rawValue).joined(separator: "+")))
            if two.wer != one.wer {
                print("      pass1: \(hypothesis)")
                print("      pass2: \(refinedText)")
            }
            ring.record(hypothesis)
        }
        session.discard()

        // MARK: the table
        let verdict = Verdict.over(rows)
        let improvable = rows.filter(\.improvable).count
        let damaged = rows.filter(\.damaged).count
        print("\n== R5.3 gate recall · real-room/\(pass) · pass1 \(passOne.name) · pass2 qwen3-asr-0.6b-int8 ==")
        print("weights: \(folder.path)")
        print(String(format: "pass1 mean WER %.4f · pass2 mean WER %.4f · improvable %d/%d · pass2 worse on %d",
                     rows.map(\.werPassOne).reduce(0, +) / Double(rows.count),
                     rows.map(\.werPassTwo).reduce(0, +) / Double(rows.count),
                     improvable, rows.count, damaged))
        print(verdict.line("gate (auto, default)"))
        print(Verdict.over(rows.map { var r = $0; r.gated = true; return r }).line("always (reference)"))
        print(Verdict.over(rows.map { var r = $0; r.gated = false; return r }).line("never (reference)"))

        // Which condition did the work, and which could not fire on this corpus at all.
        var perCondition: [RefinementGate.Reason: Int] = [:]
        for row in rows where row.gated {
            for condition in row.conditions { perCondition[condition, default: 0] += 1 }
        }
        for condition in [RefinementGate.Reason.lowConfidence, .contextNearMiss, .nonEnglish, .longSegment] {
            print(String(format: "  %-16@ fired on %2d utterances", condition.rawValue as NSString,
                         perCondition[condition] ?? 0))
        }
        print(String(format: "corpus range: %.1f–%.1fs, %d–%d words, confidence %.2f–%.2f — all English, "
                     + "all one sentence, so nonEnglish and longSegment cannot fire here",
                     rows.map(\.seconds).min() ?? 0, rows.map(\.seconds).max() ?? 0,
                     rows.map(\.words).min() ?? 0, rows.map(\.words).max() ?? 0,
                     rows.map(\.confidence).min() ?? 0, rows.map(\.confidence).max() ?? 0))
        print(String(format: "list %d/400 terms · prompt %d/%d characters · pass2 latency mean %.1fs "
                     + "(deadline is %.0f ms — R5.4's problem, not the gate's)",
                     rankedTerms, promptCharacters, builder.limits.maxCharacters,
                     passTwoLatencies.reduce(0, +) / Double(max(passTwoLatencies.count, 1)),
                     RefinementClock.milliseconds(RefineStage.finalSegmentDeadline)))

        // MARK: a duration sweep, so `longSegmentSeconds` is set by measurement and not by taste
        print("longSegmentSeconds sweep (every other threshold at its default):")
        for candidate in [4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 12.0] {
            var settings = RefinementGateSettings.default
            settings.longSegmentSeconds = candidate
            let swept = RefinementGate(mode: .auto, settings: settings)
            let sweptRows = rows.map { row -> Row in
                var r = row
                let signals = RefinementGateSignals(
                    hypothesis: String(repeating: "w ", count: row.words), confidence: row.confidence,
                    nearMisses: row.nearMisses, promptTerms: row.promptTerms, segmentSeconds: row.seconds)
                r.gated = swept.decide(signals).shouldRefine
                return r
            }
            print("  " + Verdict.over(sweptRows).line(String(format: "≥ %.0fs", candidate)))
        }

        // MARK: the acceptance assertions
        //
        // Recall is *reported*, which is the acceptance criterion (R5.3). It is not asserted at a
        // level, because on twenty utterances of clean English with a weaker second model the
        // improvable set is a handful of segments: a threshold here would be a number tuned to this
        // corpus pretending to be a contract. What is asserted is that the measurement happened and
        // that the gate is not degenerate.
        #expect(rows.count == items.count)
        let fired = rows.filter(\.gated).count
        #expect(fired < rows.count, "a gate that fires on every segment is the Always mode, not a gate")
        if improvable > 0 {
            #expect(verdict.recall != nil)
        } else {
            print("NOTE: no segment on this corpus is improved by pass 2 — recall is undefined here, "
                  + "and that fact is the R5.4 finding, not a gate failure.")
        }
    }

    /// R4.1b left one question open for this task: its 1000-character prompt cap **saturates** — the
    /// ranked list offers 400 terms and only 189 fit — so should `PromptBuilder.Limits.maxCharacters`
    /// go up? This is the measurement that answers it, rather than a guess either way.
    ///
    /// Two arms over the same twenty utterances and the same Qwen weights: the shipping cap, and a
    /// cap of 2400 characters (enough for the whole 400-term list). What changes is the *prompt*, so
    /// what is measured is pass-2 WER and pass-2 latency — the two things a longer context can cost.
    ///
    /// **Measured 11 September 2026, and the answer is no:**
    ///
    ///     cap 1000 (shipping)  terms 116  chars 1000  pass2 mean WER 0.1784  latency 1.92s  near-misses 6
    ///     cap 2400             terms 174  chars 1440  pass2 mean WER 0.1784  latency 1.68s  near-misses 6
    ///
    /// 58 more terms in the prompt changed pass-2 WER by nothing at four decimal places and changed
    /// the gate's near-miss count by nothing at all; the latency difference is noise on a ~1.8 s
    /// pass. (The 2400 arm never even reaches its cap — the whole 189-term ranked list fits in 1440
    /// characters, so the cap stops binding before the list runs out.) The extra terms are the
    /// lowest-ranked ones, which R4.1b measured as the source of false insertions. So
    /// `PromptBuilder.Limits.maxCharacters` **stays at 1000**: raising it buys nothing measurable and
    /// spends prefill tokens against a deadline that is already the binding constraint.
    ///
    /// Opt-in separately (`VOICEPLUS_PROMPT_CAP=1`): it is another forty inferences.
    @Test(.timeLimit(.minutes(60)))
    func doesALongerContextPromptEarnItsCharacters() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_PROMPT_CAP"] == "1" else {
            print("SKIPPED promptCap: set VOICEPLUS_PROMPT_CAP=1 (40 Qwen inferences).")
            return
        }
        let (items, skip) = Self.corpus()
        if let skip { print(skip); return }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: Parakeet is not on disk."); return }
        let weights = Qwen3WeightsStore()
        guard RefinementAvailability.isAvailable, weights.locate() != nil else {
            print("SKIPPED: refinement is unavailable or the Qwen weights are not on disk.")
            return
        }

        let passOne = try await RecognizerFactory.makeFinal(manager: manager)
        let passTwo = Qwen3RefinementSession(store: weights, language: .english)
        try await passTwo.prepare()

        struct Arm { var label: String; var builder: PromptBuilder; var wer = 0.0; var seconds = 0.0
                     var terms = 0; var characters = 0; var nearMisses = 0 }
        var arms = [
            Arm(label: "cap 1000 (shipping)", builder: PromptBuilder()),
            Arm(label: "cap 2400", builder: PromptBuilder(limits: PromptBuilder.Limits(maxCharacters: 2_400))),
        ]
        let contextGate = ContextGate()
        let ring = RecentWordsRing()
        let session = ContextSession(harvester: ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText(Self.screenBlocks)),
            CorrectionSource(store: MockCorrectionStore(
                corrections: Self.correctedTerms.map { ($0, Date()) },
                dictionary: Self.dictionaryTerms)),
            ring,
        ]))

        for item in items {
            let samples = try SampleAudioSource.load16k(url: item.audio)
            let hypothesis = try await passOne.recognize(samples).map(\.text).joined(separator: " ")
            let ranked = session.rebuild()
            for index in arms.indices {
                let prompt = arms[index].builder.build(ranked)
                let started = Date()
                let refined = try await passTwo.refine(samples: samples, context: prompt.prompt,
                                                       deadline: .seconds(600))
                arms[index].seconds += Date().timeIntervalSince(started)
                arms[index].wer += WERScorer.score(reference: item.reference,
                                                   hypothesis: refined.map(\.text).joined(separator: " ")).wer
                arms[index].terms = max(arms[index].terms, prompt.included)
                arms[index].characters = max(arms[index].characters, prompt.prompt.count)
                arms[index].nearMisses += contextGate.decide(hypothesis: hypothesis, confidence: 0.9,
                                                            context: ranked, prompt: prompt).nearMisses
            }
            ring.record(hypothesis)
        }
        session.discard()

        print("\n== R5.3 · does a longer context prompt earn its characters? (real-room/builtin) ==")
        for arm in arms {
            print(String(format: "%-20@ terms %3d  chars %4d  pass2 mean WER %.4f  mean latency %.2fs  gate near-misses %d",
                         arm.label as NSString, arm.terms, arm.characters,
                         arm.wer / Double(items.count), arm.seconds / Double(items.count), arm.nearMisses))
        }
        #expect(arms[1].terms > arms[0].terms, "the longer cap must actually carry more terms")
    }
}
