import Actions
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Regression cover for the 1.7.9 report: Right ⌘ dictation produced no text and the pill read
/// `Agent: failed(reason: "planner: disabled(stage: act.planner)")`.
///
/// The act (second) key defaults to Right ⌘. Nothing stopped the dictation key from being bound
/// to the same physical modifier, so one press drove both `HotkeyService` instances: the act
/// session opened the act domain, raced `engine.stop()` for the transcript, and the sentence was
/// parsed as an act goal → `.agentic` → the planner → an error where the user's words belonged.
@Suite("plain dictation never depends on the act planner")
struct ActPlannerRegressionTests {

    // MARK: The two keys must be two keys

    @Test("the act key is inert while it shares a key with dictation")
    func collidingKeysDisableTheActKey() {
        // The exact shipped defaults, and the reported configuration.
        #expect(!ActKeyBinding.isDistinct(act: HotkeyBinding(kind: .rightCommand),
                                          dictation: HotkeyBinding(kind: .rightCommand)),
                "Right ⌘ for both is the bug: one press drove dictation and the act domain")
        #expect(ActKeyBinding.isDistinct(act: HotkeyBinding(kind: .rightCommand),
                                         dictation: HotkeyBinding(kind: .rightOption)),
                "the shipped defaults are two different keys and must stay usable")
        for kind in [HotkeyBinding.Kind.rightOption, .leftOption, .rightCommand, .rightControl, .fn] {
            #expect(!ActKeyBinding.isDistinct(act: HotkeyBinding(kind: kind), dictation: HotkeyBinding(kind: kind)))
        }
    }

    // MARK: A disabled stage still lands the words

    /// The act planner's stage id, as a pipeline stage that is switched off.
    struct DisabledPlannerStage: PipelineStage {
        struct Disabled: Error {}
        let id = ProviderPlanner.stage
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            throw Disabled()
        }
    }

    static let spans = [TranscriptSpan(text: "the quarterly numbers are in", confidence: 0.94,
                                       audioRange: 0...1.8, provenance: [.asr])]

    @Test("a disabled act.planner stage still lands the recognised text")
    func disabledPlannerStageStillLands() async {
        let system = MockSystemAccess()
        let runner = PipelineRunner(stages: [DisabledPlannerStage()], providers: LocalOnlyProviderRouting())
        let lander = UtteranceLander(pipeline: runner, injector: TextInjector(system: system), system: system,
                                     repair: nil, flags: .inMemory(), database: nil)

        let result = await lander.land(Self.spans, startedAt: Date(), focus: system.frontmost)

        #expect(result.text == "the quarterly numbers are in")
        #expect(result.landed, "a switched-off downstream stage must never cost the user their dictation")
        #expect(system.field.value.contains("the quarterly numbers are in"))
        #expect(!result.text.contains("act.planner"))
    }

    @Test("nothing the lander produces can carry a raw failed(reason:) string")
    func landedTextIsNeverADebugString() async {
        let system = MockSystemAccess()
        let runner = PipelineRunner(stages: [DisabledPlannerStage()], providers: LocalOnlyProviderRouting())
        let lander = UtteranceLander(pipeline: runner, injector: TextInjector(system: system), system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
        let result = await lander.land(Self.spans, startedAt: Date(), focus: system.frontmost)
        for forbidden in ["failed(reason:", "disabled(stage:", "Error", "act.planner"] {
            #expect(!result.text.contains(forbidden))
            #expect(!system.field.value.contains(forbidden))
        }
    }

    // MARK: The planner adapter treats "off" as off, not as an error

    /// `LocalOnlyProviderRouting` is exactly production's state with no provider pinned.
    @Test("ProviderPlanner reports an unconfigured stage as unavailable, not as a failure")
    func providerPlannerIsUnavailableWhenNothingIsPinned() async {
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting())
        do {
            _ = try await planner.plan(goal: "open the PR tab",
                                       observation: AXSummary(app: "Safari", window: "PRs"),
                                       history: [], tools: AgentTool.vocabulary)
            Issue.record("an unconfigured planner must not silently succeed")
        } catch let error as PlannerError {
            #expect(error == .unavailable(reason: "no provider chosen for act.planner"))
        } catch {
            Issue.record("expected PlannerError.unavailable, got \(error)")
        }
    }

    @Test("the pill message for an unconfigured planner is plain language")
    func pillMessageIsPlainLanguage() async {
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting())
        let agent = NativeAgentBackend(planner: planner, executor: ActionExecutor(system: LiveActionSystem()),
                                       consent: ConsentEngine())
        let report = await agent.run(goal: "send the note to Priya")
        #expect(report.status == .unavailable(reason: "no provider chosen for act.planner"))
        // This is the string that reaches `pill.model.present(.preview(text:))` in AppDelegate.
        let shown = report.userMessage
        #expect(shown == "Actions need a model set up in Settings")
        #expect(shown != "Agent: \(String(describing: report.status))")
    }
}
