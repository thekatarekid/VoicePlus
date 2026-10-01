import Foundation
import Testing
import Injection
import Pipeline
import Shared
@testable import VoicePlusApp

/// Q1 — the lander's `allowSubmit` goes through `SubmitPolicy`: a search field asks to submit,
/// but in an app where ↩ sends (Electron / Cursor / Chromium) nothing may press Return.
@Suite struct SubmitPolicyWiringTests {
    static func land(_ bundleID: String) async -> UtteranceResultSnapshot {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 100, bundleID: bundleID,
                                                            appName: bundleID, elementToken: "el-1"))
        mock.field = MockSystemAccess.Field(role: "AXSearchField")
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }
        let lander = UtteranceLander(pipeline: PipelineRunner(stages: FieldRolePipeline.replacingFormatters(in: builtIn)),
                                     injector: TextInjector(system: mock), system: mock, repair: nil,
                                     flags: .inMemory(), database: nil)
        let reader = FieldContextReader(system: mock)
        lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
        let result = await lander.land([TranscriptSpan(text: "weather", confidence: 0.95, audioRange: 0...1)],
                                       startedAt: Date(), focus: mock.frontmost)
        return UtteranceResultSnapshot(allowSubmit: result.allowSubmit)
    }

    struct UtteranceResultSnapshot { var allowSubmit: Bool }

    @Test func nativeSearchFieldMaySubmit() async {
        #expect(await Self.land("com.apple.finder").allowSubmit)
    }

    @Test("send-on-↩ apps never submit", arguments: ["com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
                                                    "com.todesktop.230313mzl4w4u92", "com.google.Chrome"])
    func newlineSafeAppsNeverSubmit(bundleID: String) async {
        #expect(await !Self.land(bundleID).allowSubmit)
    }
}
