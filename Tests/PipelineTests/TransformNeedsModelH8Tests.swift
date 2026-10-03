import Foundation
@testable import Pipeline
import Shared
import Testing

/// H8 — the executor says when an LLM command has no model, and T05 only fires for a deciding word.
@Suite("H8 — executor: needs model, deciding uncertain words")
struct TransformNeedsModelH8ExecutorTests {
    let ctx = StageContext()
    func req(_ instr: String, _ text: String, low: Set<String> = []) -> TransformRequest {
        TransformRequest(instruction: spans(instr, lowWords: low), selection: SelectionSnapshot(text: text, range: 0..<text.utf16.count), context: ctx)
    }

    @Test("no provider, rules leave the text as is → needsModel")
    func needsModel() async {
        let exec = TransformExecutor(providers: LocalOnlyProviderRouting())
        await #expect(throws: TransformError.needsModel) { try await exec.execute(req("make this sound friendlier", "hey there"), context: ctx) }
    }

    @Test("no provider, rules can do it → rules apply (H13: with no model → rules)")
    func rulesStillApply() async throws {
        let exec = TransformExecutor(providers: LocalOnlyProviderRouting())
        let r = try await exec.execute(req("make this shorter", "So basically I just wanted to say hi."), context: ctx)
        #expect(r.source == .local && r.output == "So I wanted to say hi.")
    }

    @Test("a model that failed is not 'needs model': no change stands")
    func failedModelIsNoChange() async throws {
        struct Failing: PipelineProviderRouting {
            func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { true }
            func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String { throw ProviderRoutingError.unavailable }
        }
        let r = try await TransformExecutor(providers: Failing()).execute(req("make this sound friendlier", "hey there"), context: ctx)
        #expect(r.diff.isIdentity)
    }

    @Test("decisive uncertain words: fillers and deictics do not decide")
    func decisive() {
        #expect(req("um make this formal", "x", low: ["um", "this"]).decisiveUncertainWords.isEmpty)
        #expect(req("make this formal", "x", low: ["formal"]).decisiveUncertainWords.map(\.text) == ["formal"])
        #expect(req("please make it shorter", "x", low: ["please", "it"]).decisiveUncertainWords.isEmpty)
    }

    @Test("uncertain filler → the catalogue edit still runs; deciding word → T05")
    func execUncertain() async throws {
        let exec = TransformExecutor(providers: LocalOnlyProviderRouting())
        let r = try await exec.execute(req("um make this all caps", "ship it", low: ["um"]), context: ctx)
        #expect(r.output == "SHIP IT")
        await #expect(throws: TransformError.uncertainInstruction(["caps"])) {
            try await exec.execute(req("make this all caps", "ship it", low: ["caps"]), context: ctx)
        }
    }
}
