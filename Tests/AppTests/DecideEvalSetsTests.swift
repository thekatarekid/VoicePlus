import Engine
import Foundation
import Lab
import Shared
import Testing
@testable import VoicePlusApp

/// V5 L6 — eval sets for the decision layer: the 150-line scripted command set, meeting utterances
/// (AMI / NOTSOFAR) as `ignore`, and the arbiter as a V1 `--stage decide` backend.
@Suite("V5 L6 DecideEvalSets")
struct DecideEvalSetsTests {
    static func tempPaths() -> EvalPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l6-\(UUID().uuidString)")
        return EvalPaths(cacheDirectory: dir.appendingPathComponent("cache"), fixturesDirectory: AppPaths.fixturesDirectory(),
                         resultsDirectory: dir.appendingPathComponent("results"))
    }

    @Test("the scripted command set: 150 lines, 25 per capability, every label an owner, ids unique")
    func commandSet() throws {
        let m = try Self.tempPaths().loadManifest(set: DecideSetBuilder.commandSet)
        #expect(m.items.count == 150)
        #expect(DecideSetBuilder.invalidLabels(m).isEmpty)
        #expect(Set(m.items.map(\.id)).count == 150)
        for owner in UtteranceOwner.allCases {
            #expect(m.items.filter { $0.label == owner.rawValue }.count == 25, "\(owner)")
        }
        #expect(DecideSetBuilder.owners == Set(UtteranceOwner.allCases.map(\.rawValue)), "Lab's list matches O2's vocabulary")
        #expect(m.items.allSatisfy { $0.audio == nil && !$0.reference.isEmpty })
    }

    @Test("meeting utterances become ignore items, tagged by set; decide-set writes <set>-decide")
    func meetingIgnore() async throws {
        let ami = EvalManifest(set: "ami", audioRoot: "ami", licence: "CC-BY-4.0", items: [
            EvalItem(id: "ES2004a-1", audio: "a.wav", reference: "okay so shall we start", tags: ["ihm"]),
            EvalItem(id: "ES2004a-2", audio: "a.wav", reference: "mm", tags: ["ihm"]),
            EvalItem(id: "ES2004a-3", audio: "a.wav", reference: "  ", tags: ["ihm"]),
        ])
        let set = DecideSetBuilder.ignoreSet(from: ami)
        #expect(set.set == "ami-decide")
        #expect(set.items.map(\.id) == ["ES2004a-1", "ES2004a-2"])
        #expect(set.items.allSatisfy { $0.label == "ignore" && $0.tags.contains("meeting") && $0.tags.contains("ami") && $0.audio == nil })
        #expect(DecideSetBuilder.ignoreSet(from: ami, minWords: 2).items.count == 1)
        #expect(DecideSetBuilder.ignoreSet(from: ami, limit: 1).items.count == 1)

        let paths = Self.tempPaths()
        let amiDir = paths.cacheDirectory.appendingPathComponent("ami")
        try FileManager.default.createDirectory(at: amiDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ami).write(to: amiDir.appendingPathComponent("manifest.json"))
        let out = await LabCLI.main(["decide-set", "--from", "ami"], eval: PublicEval(paths: paths))
        #expect(out.exitCode == 0, "\(out.text)")
        #expect(try paths.loadManifest(set: "ami-decide").items.count == 2)
    }

    /// Answers by keyword, standing in for Kev on the owner's Mac.
    final class KeywordModel: DecisionModel, @unchecked Sendable {
        let id = "keyword"
        func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
            let utterance = state.lowercased()
            let owner: UtteranceOwner = utterance.contains("remember") || utterance.contains("note") ? .note
                : utterance.contains("open") ? .act : .ignore
            var cap: [String: Double] = [:]
            for o in UtteranceOwner.allCases { cap[o.rawValue] = o == owner ? 0.9 : 0.02 }
            let addressed = owner == .ignore ? 0.05 : 0.95
            return DecisionAnswers([.addressed: ["no": 1 - addressed, "yes": addressed], .complete: ["no": 0.05, "yes": 0.95],
                                    .capability: cap, .continuation: ["no": 0.5, "yes": 0.5],
                                    .needsAgent: ["no": 0.9, "yes": 0.1], .worthNoting: ["no": 0.9, "yes": 0.1]])
        }
    }

    @Test("the arbiter as a --stage decide backend: labels are owners, accuracy per capability tag")
    func arbiterBackend() async throws {
        let paths = Self.tempPaths()
        let manifest = try paths.loadManifest(set: DecideSetBuilder.commandSet)
        let backend = ArbiterEvalBackend(modelID: "decide-keyword") {
            IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), model: { KeywordModel() })
        }
        let eval = PublicEval(paths: paths, hardware: "test")
        let report = try await eval.run(manifest: manifest, backend: backend, options: .init(stage: .decide))
        #expect(report.items.count == 150)
        #expect(report.items.allSatisfy { DecideSetBuilder.owners.contains($0.label ?? "") })
        #expect(report.summary.accuracy != nil)
        #expect(Set(report.byCondition.keys).isSuperset(of: UtteranceOwner.allCases.map(\.rawValue)))
        print(PublicEval.table(report))
    }

    @Test("registered ids: decide-layer0 and one per decision model; layer0 alone never acts on meeting chatter by a model")
    func registry() async throws {
        var registry = LabRegistry.mocks
        ArbiterEvalBackend.register(&registry)
        #expect(registry.evalBackends.keys.contains("decide-layer0"))
        for c in DecisionModelChoice.allCases { #expect(registry.evalBackends.keys.contains("decide-\(c.rawValue)")) }
        let layer0 = try #require(registry.evalBackends["decide-layer0"])()
        let chatter = EvalItem(id: "m1", reference: "did you watch the match last night", label: "ignore")
        #expect(try await layer0.evaluate(chatter, audioURL: nil, stage: .decide).label == "ignore")
        await #expect(throws: EvalError.self) { try await layer0.evaluate(chatter, audioURL: nil, stage: .asr) }
    }
}
