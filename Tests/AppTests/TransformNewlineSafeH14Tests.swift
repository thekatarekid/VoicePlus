import Foundation
import Injection
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// H14 (app side) — model edits with new line breaks get the longest preview; a multi-line edit in web
/// content never goes through an AX write (lands via the injector's ⇧↩ write plan); refusals say why.
@Suite("H14 — newline-safe LLM edit landing")
struct TransformNewlineSafeH14Tests {
    typealias Box<T> = TransformPreviewGateTests.Box<T>
    static let app = FocusSnapshot(pid: 100, bundleID: "com.google.Chrome", appName: "Chrome", elementToken: "el-1")

    final class Route: PipelineProviderRouting, @unchecked Sendable {
        var reply: String = ""
        var error: Error?
        func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { stage == .transform }
        func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
            if let error { throw error }
            return reply
        }
    }

    static func make(_ value: String, route: Route, web: Bool) -> (TransformLanding, MockSystemAccess, Box<[TransformPillReducer.Event]>, Box<[TimeInterval]>) {
        let system = MockSystemAccess(frontmost: app)
        system.field = .init(value: value, selection: 0..<value.utf16.count)
        system.inWebArea = web
        let session = TransformSession(executor: TransformExecutor(providers: route), sink: InjectionTransformReplaceSink(system: system))
        let landing = TransformLanding(session: session, detector: SystemAccessSelectionDetector(system: system),
                                       qa: QuestionAnswerStage(answerer: HeuristicAnswerer()), system: system,
                                       injector: TextInjector(system: system))
        let events = Box<[TransformPillReducer.Event]>([]), waited = Box<[TimeInterval]>([])
        landing.onEvent = { events.value.append($0) }
        landing.sleep = { dt in waited.value.append(dt) }
        return (landing, system, events, waited)
    }

    static func instruct(_ landing: TransformLanding, _ text: String) async -> TransformLanding.Outcome {
        await landing.handle(TransformLandingTests.spans(text), decision: .fallback(), context: StageContext())
    }

    @Test func multiLineEditInWebContentLandsThroughTheWritePlanAndWaitsForReview() async {
        let route = Route(); route.reply = "- ship Friday\n- tell Sam"
        let (landing, system, _, waited) = Self.make("ship Friday and tell Sam", route: route, web: true)
        let out = await Self.instruct(landing, "make this two points please")
        guard case .transformed(.applied) = out else { Issue.record("got \(out)"); return }
        #expect(abs(waited.value.reduce(0, +) - TransformPreviewDwell.longestTimed.seconds) < 0.01)   // previewed for the longest dwell
        #expect(system.field.value == "- ship Friday\n- tell Sam")
        #expect(!system.journal.contains("ax.setSelectedText") && !system.journal.contains("ax.setValue"))   // never an AX multi-line write
        #expect(system.journal.contains { $0.contains("key.combo") && $0.contains("+shift") })   // ⇧↩, never a bare ↩
        #expect(system.field.selection == 0..<"- ship Friday\n- tell Sam".utf16.count)   // H9: result selected
    }

    @Test func singleLineEditKeepsTheTimedDwell() async {
        let route = Route(); route.reply = "Ship on Friday and tell Sam."
        let (landing, system, _, waited) = Self.make("ship Friday and tell Sam", route: route, web: true)
        _ = await Self.instruct(landing, "make this formal")
        #expect(abs(waited.value.reduce(0, +) - TransformPreviewDwell.standard.seconds) < 0.01)
        #expect(system.field.value == "Ship on Friday and tell Sam.")
    }

    @Test func oversizeSelectionIsRefusedWithItsMessage() async {
        let route = Route(); route.error = LocalLLMBudget.Refusal.selectionTooLong(words: 1_200)
        let (landing, system, events, _) = Self.make("hey there friend", route: route, web: false)
        _ = await Self.instruct(landing, "make this formal")
        #expect(system.field.value == "hey there friend")
        #expect(events.value.last == .failed(LocalLLMBudget.tooLongMessage))
    }

    @Test func replaceRangeRefusesAMultiLineAXWriteInWebContent() {
        let system = MockSystemAccess(frontmost: Self.app)
        system.field = .init(value: "a and b", selection: 0..<7)
        system.inWebArea = true
        let out = ReplaceRangeEditor(system: system).replace(ReplaceRangeRequest(range: 0..<7, expected: "a and b", replacement: "a\nb"))
        #expect(out == .unavailable(reason: ReplaceRangeEditor.newlineUnsafeReason))
        #expect(system.field.value == "a and b")
        system.inWebArea = false
        #expect(ReplaceRangeEditor(system: system).replace(ReplaceRangeRequest(range: 0..<7, expected: "a and b", replacement: "a\nb")) == .replaced(verified: true))
    }
}
