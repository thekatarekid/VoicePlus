import Foundation
import Testing
import Pipeline
import Providers
import Shared
@testable import VoicePlusApp

// H14 — the on-device edit route enforces the 4,096-token budget (selection > ~1,000 words refused,
// never truncated; output capped at 2 × selection + 64 for the call) and rejects empty / preamble /
// over-long output. Mock provider only; no model is loaded and nothing touches the network.

private final class CapProvider: TextGenerator, @unchecked Sendable {
    let id: ProviderID = "local.llamacpp.shared"
    let displayName = "cap"
    let capabilities: ProviderCapabilities = [.pipeline]
    let costClass: CostClass = .free
    let privacyClass: PrivacyClass = .onDevice
    let reply: String
    private let lock = NSLock()
    private var _caps: [Int?] = []
    var caps: [Int?] { lock.withLock { _caps } }
    init(reply: String) { self.reply = reply }
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        let cap = LocalLLMBudget.outputCap
        lock.withLock { _caps.append(cap) }
        return (reply, 0, 0, "on-device")
    }
}

private func route(_ p: CapProvider) -> RoutingTableProviderRouting {
    RoutingTableProviderRouting(table: RoutingTable(providers: [p], logger: InMemoryNetworkLogger()),
                                settings: InMemorySettingsStore(),
                                onDevice: OnDeviceEditRoute(providerID: p.id, isReady: { true }))
}

@Suite struct LLMModeEditSafetyTests {
    @Test func outputCapIsSetPerEditCall() async throws {
        let p = CapProvider(reply: "Hello there.")
        let out = try await route(p).complete(stage: .transform, prompt: "make formal: hi there", input: "hi there",
                                              context: StageContext())
        #expect(out == "Hello there.")
        let cap = try #require(p.caps.compactMap { $0 }.first)
        #expect(cap == 2 * LocalLLMBudget.estimateTokens("hi there") + 64)
        #expect(LocalLLMBudget.outputCap == nil)   // scoped to the call
    }

    @Test func overlongSelectionIsRefusedBeforeTheModelRuns() async throws {
        let p = CapProvider(reply: "x")
        let big = Array(repeating: "word", count: 1_200).joined(separator: " ")
        await #expect(throws: LocalLLMBudget.Refusal.self) {
            _ = try await route(p).complete(stage: .transform, prompt: "shorten", input: big, context: StageContext())
        }
        #expect(p.caps.isEmpty)
        #expect(LocalLLMBudget.tooLongMessage.contains("1,000 words"))
    }

    @Test func preambleEmptyAndRunawayOutputAreRejected() async throws {
        for reply in ["Sure, here is the text: Hello there.", "<think>\n\n</think>\n\n", String(repeating: "blah ", count: 40)] {
            let p = CapProvider(reply: reply)
            await #expect(throws: ProviderRoutingError.self) {
                _ = try await route(p).complete(stage: .transform, prompt: "fix", input: "hi there", context: StageContext())
            }
        }
    }

    @Test func rejectedOutputFallsBackToTheRules() async throws {
        let p = CapProvider(reply: "Sure, here is it: HELLO")
        let spans = ["make", "it", "uppercase"].enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 0.95, audioRange: Double(i)...Double(i) + 0.5, provenance: [.asr])
        }
        let req = TransformRequest(instruction: spans,
                                   selection: SelectionSnapshot(text: "hello", range: 0..<5, before: "", after: ""),
                                   context: StageContext())
        let out = try await TransformExecutor(providers: route(p)).execute(req, context: StageContext())
        #expect(out.source != .provider)   // deterministic rules (catalog or local)
        #expect(out.output == "HELLO")
    }

    @Test func questionAnswersAreFreeLengthButNotEmpty() async throws {
        let long = String(repeating: "It means a short summary. ", count: 10)
        let ok = try await route(CapProvider(reply: long)).complete(stage: .question, prompt: "what is this?", input: "TL;DR",
                                                                    context: StageContext())
        #expect(ok == long.trimmingCharacters(in: .whitespacesAndNewlines))
        await #expect(throws: ProviderRoutingError.self) {
            _ = try await route(CapProvider(reply: "  ")).complete(stage: .question, prompt: "q", input: "x", context: StageContext())
        }
    }
}
