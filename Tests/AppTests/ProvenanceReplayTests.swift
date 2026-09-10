import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// R4.1a — provenance contract for the `adapt.lexicon` stage, and the corpus replay that proves
/// `AppContainer`'s pipeline logs no `contract violation` line.
///
/// This lives in `AppTests` rather than `PipelineTests` because the stage registered as
/// `adapt.lexicon` is `RegressionGuardStage` in `App/Services/AdaptationService.swift` (over
/// `Engine`'s `RegressionGuard`), and `PipelineTests` depends on `Pipeline` alone. The `wakeVerb`
/// half of R4.1a is in `Tests/PipelineTests/StageProvenanceContractTests.swift`.
@Suite("R4.1a — provenance contract + corpus replay", .serialized)
struct ProvenanceReplayTests {

    // MARK: helpers

    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func assertContract(_ input: [TranscriptSpan], _ output: [TranscriptSpan], _ id: StageID) {
        #expect(ConfidenceContract.verify(input: input, output: output).isEmpty)
        #expect(output.allSatisfy { $0.provenance.last == id }, "every output span records \(id)")
        #expect(output.count == input.count)
        for (i, o) in zip(input, output) {
            #expect(o.confidence == i.confidence, "confidence survives")
            #expect(o.audioRange == i.audioRange, "audioRange survives")
            #expect(o.provenance.dropLast() == i.provenance, "earlier provenance survives, in order")
        }
    }

    /// A lexicon trained the way the app trains it: four repairs of the same mis-hearing.
    static func trainedLexicon() throws -> PersonalLexicon {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r41a-adapt-\(UUID())")
        let service = try AdaptationService(root: root,
                                            werFile: root.appendingPathComponent("wer.json"),
                                            toastFile: root.appendingPathComponent("toasts.json"))
        for i in 0..<4 {
            service.ingest(CorrectionRecord(utteranceID: "u\(i)", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            original: "email kotari about the deck",
                                            corrected: "email Kothari about the deck",
                                            audioRange: 0...1.2, source: "voiceRepair"))
        }
        return service.retrain()
    }

    static func stage(_ lexicon: PersonalLexicon) -> RegressionGuardStage {
        RegressionGuardStage(lexicon: { lexicon })
    }

    // MARK: adapt.lexicon contract

    @Test func adaptLexiconAppendsProvenanceOnPassThrough() async throws {
        // Nothing learned yet, so nothing is rewritten — the stage must still record that it ran.
        let input = Self.spans("the quick brown fox jumps over the lazy dog")
        let out = try await Self.stage(PersonalLexicon()).process(input, context: StageContext())
        #expect(out.map(\.text) == input.map(\.text))
        Self.assertContract(input, out, RegressionGuard.stageID)
    }

    @Test func adaptLexiconAppendsProvenanceOnModification() async throws {
        let input = Self.spans("email kotari about the deck")
        let out = try await Self.stage(try Self.trainedLexicon()).process(input, context: StageContext())
        #expect(out.map(\.text).contains("Kothari"), "the learned correction is applied")
        Self.assertContract(input, out, RegressionGuard.stageID)
        let fixed = try #require(out.first { $0.text == "Kothari" })
        #expect(fixed.alternates.contains { $0.text == "kotari" && $0.source == .repair },
                "the decoded word is kept as a repair alternate")
    }

    @Test func adaptLexiconFlagsALowConfidenceRewriteInsteadOfSmoothingIt() async throws {
        // Bet 9: rewriting text we were not confident about is only legal with needsRepair set.
        let input = [TranscriptSpan(text: "kotari", confidence: 0.3, audioRange: 0...0.4, provenance: [.asr])]
        let out = try await Self.stage(try Self.trainedLexicon()).process(input, context: StageContext())
        #expect(out.first?.text == "Kothari")
        #expect(out.first?.needsRepair == true)
        Self.assertContract(input, out, RegressionGuard.stageID)
    }

    @Test func adaptLexiconSurvivesTheEnforcingWrapper() async throws {
        // Before the fix the wrapper logged "contract violation in adapt.lexicon" and fell back to
        // the input, so a learned correction could never reach the user.
        let input = Self.spans("email kotari about the deck")
        let sink = CollectingLabSink()
        let out = try await ContractEnforcingStage(Self.stage(try Self.trainedLexicon()),
                                                  policy: .fallbackToInput, sink: sink)
            .process(input, context: StageContext())
        #expect(out.map(\.text).contains("Kothari"), "the wrapper keeps the stage's output")
        #expect(sink.all.allSatisfy { $0.contractViolations.isEmpty })
    }

    // MARK: the corpus replay

    /// Exactly the stage list `AppContainer.init` assembles: wake verb, snippets, the regression
    /// guard, then the registry (gatekeeper filtered out, `style` bound to a store).
    static func appContainerStages(lexicon: PersonalLexicon) -> [any PipelineStage] {
        [WakeVerbStage(preRoute: WakeVerbPreRoute()),
         SnippetStage(store: InMemorySnippetStore()),
         RegressionGuardStage(lexicon: { lexicon })]
            + StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
                stage.id == .style ? StyleStage(store: InMemoryStyleProfileStore()) : stage
            }
    }

    static func corpusRoot() -> URL? {
        AppPaths.fixturesDirectory()?.appendingPathComponent("real-room", isDirectory: true)
    }

    /// The twenty reference sentences of `Fixtures/real-room/script.md`, in script order.
    static func scriptLines() -> [String] {
        guard let root = corpusRoot(),
              let text = try? String(contentsOf: root.appendingPathComponent("script.md"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 4, line.prefix(2).allSatisfy(\.isNumber) else { return nil }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
    }

    static func rawRecordings() -> [URL] {
        guard let root = corpusRoot() else { return [] }
        let dir = root.appendingPathComponent("builtin", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("-raw.wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Replays `Fixtures/real-room/builtin` through the pipeline `AppContainer` builds and asserts
    /// that not one stage run reported a contract violation (the line
    /// `ContractEnforcingStage` would log as "contract violation in <stage>").
    ///
    /// Source of the spans, printed with the result so the evidence is never ambiguous:
    ///   * **real audio** — the twenty `*-raw.wav` decoded by the real recognizer, when the
    ///     parakeet weights are on this machine and the git-ignored WAVs are in the checkout;
    ///   * **script text** — one span per word of the reference sentences, otherwise.
    @Test(.timeLimit(.minutes(30)))
    func realRoomCorpusReplayThroughAppContainerPipelineHasNoContractViolations() async throws {
        let lines = Self.scriptLines()
        try #require(lines.count == 20, "Fixtures/real-room/script.md holds the twenty reference sentences")

        // A trained lexicon, so `adapt.lexicon` is a live stage during the replay rather than a
        // stage that never fires.
        let lexicon = try Self.trainedLexicon()
        let runner = PipelineRunner(stages: Self.appContainerStages(lexicon: lexicon))

        // Real audio when the weights and the WAVs are both here; the script text otherwise.
        var utterances: [(label: String, spans: [TranscriptSpan])] = []
        var evidence = "script text (one span per reference word)"
        let wavs = Self.rawRecordings()
        let manager = ModelManager(maintenance: .skip)
        if wavs.count == lines.count, await manager.isPresent(.parakeetTDTv3) {
            let recognizer = try await RecognizerFactory.makeFinal(manager: manager)
            for (i, wav) in wavs.enumerated() {
                let heard = try await recognizer.recognize(try SampleAudioSource.load16k(url: wav))
                guard !heard.isEmpty else { continue }
                utterances.append((String(format: "%02d %@", i + 1, wav.lastPathComponent), heard))
            }
            evidence = "real audio, \(utterances.count) x *-raw.wav decoded by \(recognizer.name)"
        }
        if utterances.isEmpty {
            utterances = lines.enumerated().map { (String(format: "%02d script", $0 + 1), Self.spans($1)) }
        }

        let handsFree = StageContext(extra: [WakeVerbPreRoute.modeKey: WakeVerbPreRoute.handsFreeValue])
        var violations: [String] = []
        var stageRuns = 0
        for (label, spans) in utterances {
            for context in [StageContext(), handsFree] {
                let result = try await runner.run(spans, context: context)
                stageRuns += result.metrics.count
                for m in result.metrics where !m.contractViolations.isEmpty {
                    violations.append("\(label) [\(m.stage)]: \(m.contractViolations.joined(separator: "; "))")
                }
            }
        }
        print("""
            R4.1a corpus replay through AppContainer's pipeline
              evidence:   \(evidence)
              utterances: \(utterances.count) x 2 contexts (as-detected + hands-free)
              stage runs: \(stageRuns)
              contract violations: \(violations.count)
            """)
        #expect(stageRuns > 0)
        #expect(violations.isEmpty, "contract violations:\n\(violations.joined(separator: "\n"))")
    }
}
