import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V4 Wave 1 gate "digits class WER < 0.20" (build doc §4, "replay of the script's number lines").
///
/// The script lines that contain digits (`digitLines`: 04 "11:45", 05 "2,340 … 2,430", 11
/// "14 … 400050"; the same set as EngineTests' `RealRoomCorpus.digitLines`) are decoded from the
/// raw and the processed `Fixtures/real-room/builtin` captures by the real final model, then landed
/// by the production `UtteranceLander` (`inject: false`: the final payload, nothing written) over the
/// stage list `AppContainer` assembles today (`appPipeline`: wake verb, snippets, the regression guard,
/// then the built-ins with `FieldRolePipeline` in place of the register formatters) into an empty
/// Notes body — the text that would land, numbers formatted — and scored against the script
/// verbatim. The class WER is the summed errors over the summed reference words, per capture copy.
///
/// It lives in AppTests because EngineTests cannot import `Pipeline`. Skips when the git-ignored WAVs
/// or the model weights are not on this machine.
@Suite("V4 gate — digits class WER (real model + app pipeline)", .serialized)
struct RealRoomDigitsClassTests {
    static let digitLines: Set<Int> = [4, 5, 11]
    static let gate = 0.20

    /// `AppContainer.init`'s stage list (R4.2: `FieldRoleFormatterStage` in place of the five
    /// register formatters), with in-memory stores.
    static func appPipeline() -> PipelineRunner {
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
            stage.id == .style ? StyleStage(store: InMemoryStyleProfileStore()) : stage
        }
        let stages: [any PipelineStage] = [WakeVerbStage(preRoute: WakeVerbPreRoute()),
                                           SnippetStage(store: InMemorySnippetStore()),
                                           RegressionGuardStage(lexicon: { PersonalLexicon() })]
            + FieldRolePipeline.replacingFormatters(in: builtIn)
        return PipelineRunner(stages: stages)
    }

    static let notes = FocusSnapshot(pid: 300, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "body")

    /// The production lander over `appPipeline`, aimed at an empty Notes body (AX text area).
    static func lander() -> UtteranceLander {
        let system = MockSystemAccess(frontmost: notes)
        system.field = MockSystemAccess.Field(role: "AXTextArea", value: "")
        let lander = UtteranceLander(pipeline: appPipeline(), injector: TextInjector(system: system), system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
        let reader = FieldContextReader(system: system)
        lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
        lander.launchTiming = nil
        return lander
    }

    struct Counts {
        var errors = 0
        var words = 0
        var wer: Double { words == 0 ? 0 : Double(errors) / Double(words) }
        static func + (a: Counts, b: Counts) -> Counts { Counts(errors: a.errors + b.errors, words: a.words + b.words) }
    }

    /// Same rules as EngineTests' `RealRoomCorpus.normalizedWords`: lowercase; letters, digits and
    /// inner apostrophes; digit grouping dropped ("2,340" is one word "2340"); everything else splits.
    static func normalizedWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text.lowercased())
        for (idx, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if ch == ",", idx > 0, chars[idx - 1].isNumber, idx + 1 < chars.count, chars[idx + 1].isNumber {
                continue
            } else if !current.isEmpty {
                out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
        return out.filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein: substitutions + deletions + insertions over the reference words.
    static func counts(reference: String, hypothesis: String) -> Counts {
        let r = normalizedWords(reference), h = normalizedWords(hypothesis)
        guard !r.isEmpty else { return Counts(errors: h.count, words: 0) }
        var d = Array(0...h.count)             // one row of the edit-distance table
        for i in 1...r.count {
            var diagonal = d[0]
            d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let above = d[j]
                d[j] = min(above + 1, d[j - 1] + 1, diagonal + (r[i - 1] == h[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return Counts(errors: d[h.count], words: r.count)
    }

    @Test func normalizerAndScorer() {
        #expect(Self.normalizedWords("The invoice total is 2,340 rupees, not 2,430.")
                == ["the", "invoice", "total", "is", "2340", "rupees", "not", "2430"])
        #expect(Self.counts(reference: "lands at 11:45, so", hypothesis: "lands at 11:45 so").errors == 0)
        #expect(Self.counts(reference: "is 2,340 rupees", hypothesis: "is two three four zero rupees").errors == 4)
    }

    /// The route model reads statements such as line 05 as questions; with no selection the lander
    /// formats them as dictation anyway (Bet 5), so the number formatter reaches them.
    @Test func aQuestionRouteWithNoSelectionIsFormattedAsDictation() async throws {
        let words = ["The", "invoice", "total", "is", "two", "three", "four", "zero", "rupees", "not",
                     "two", "four", "three", "zero."]
        let starts: [Double] = [0.24, 0.56, 1.36, 1.68, 2.0, 2.4, 2.72, 2.96, 3.28, 4.4, 4.88, 5.28, 5.6, 5.92]
        let ends: [Double] = [0.56, 1.36, 1.68, 2.0, 2.16, 2.64, 2.96, 3.28, 3.92, 4.64, 5.04, 5.6, 5.84, 7.68]
        let spans = words.indices.map { TranscriptSpan(text: words[$0], confidence: 0.95, audioRange: starts[$0]...ends[$0], provenance: [.asr]) }
        // H2 raised the shipped route threshold to 0.9, which now reads line 05 as dictation; the
        // pre-H2 threshold (0.6) still reproduces the misreading this test guards against.
        let legacy = LocalGatekeeper(routeThreshold: 0.6).classify(spans.joinedText, context: StageContext())
        #expect(legacy.route == .question, "the route model's reading this test guards against")
        #expect(LocalGatekeeper.shared.classify(spans.joinedText, context: StageContext()).route == .dictate)
        let payload = await Self.lander().land(spans, startedAt: Date(), focus: Self.notes, inject: false)
        #expect(payload.text == "The invoice total is 2340 rupees not 2430.")
        #expect(payload.route == .dictate)
    }

    @Test(.timeLimit(.minutes(20)))
    func digitsClassWERIsUnderTheGate() async throws {
        let lines = ProvenanceReplayTests.scriptLines()
        let wavs = ProvenanceReplayTests.rawRecordings()
        guard lines.count == 20, wavs.count == lines.count else {
            print("SKIPPED: Fixtures/real-room/builtin WAVs not in the checkout (\(wavs.count) of \(lines.count))."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let recognizer = try await RecognizerFactory.makeFinal(manager: manager)
        let lander = Self.lander()

        var totals: [String: Counts] = [:]
        var rows: [String] = []
        for (i, raw) in wavs.enumerated() where Self.digitLines.contains(i + 1) {
            let reference = lines[i]
            let stamp = raw.lastPathComponent.replacingOccurrences(of: "-raw.wav", with: "")
            let processed = raw.deletingLastPathComponent().appendingPathComponent("\(stamp)-processed.wav")
            for (copy, url) in [("raw", raw), ("processed", processed)] where FileManager.default.fileExists(atPath: url.path) {
                let heard = try await recognizer.recognize(try SampleAudioSource.load16k(url: url))
                let payload = await lander.land(heard, startedAt: Date(), focus: Self.notes, inject: false)
                let landed = payload.text
                let c = Self.counts(reference: reference, hypothesis: landed)
                totals[copy, default: Counts()] = totals[copy, default: Counts()] + c
                rows.append(String(format: "%02d %-9@ WER %.3f  said: %@\n             landed: %@", i + 1, copy, c.wer, reference, landed))
            }
        }
        print("\n── real-room/builtin · digits class (lines \(Self.digitLines.sorted())) · \(recognizer.name) + app pipeline ──")
        rows.forEach { print($0) }
        for copy in ["raw", "processed"] {
            guard let t = totals[copy] else { continue }
            print(String(format: "DIGITS %@  %d words  %d errors  WER %.3f  (gate < %.2f)", copy, t.words, t.errors, t.wer, Self.gate))
        }
        let raw = try #require(totals["raw"])
        #expect(raw.words > 0)
        #expect(raw.wer < Self.gate, "digits class WER \(raw.wer) on the raw captures")
        if let processed = totals["processed"] {
            #expect(processed.wer < Self.gate, "digits class WER \(processed.wer) on the processed captures")
        }
    }
}
