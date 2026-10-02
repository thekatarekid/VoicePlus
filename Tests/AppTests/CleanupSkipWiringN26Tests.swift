import Foundation
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

// N26 — a mid-document insertion switches style off but keeps cleanup (with edges kept);
// a Verbatim app rule skips both.

@Suite struct CleanupSkipWiringN26Tests {
    @Test func midSentenceInsertTurnsStyleOffButNotCleanup() {
        var ctx = StageContext(appBundleID: "com.apple.TextEdit")
        let field = FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea", isMultiline: true,
                                 textBeforeCursor: "I think the ", textAfterCursor: " is great.")
        FieldRolePipeline.write(field, into: &ctx)
        #expect(ctx.extra[StyleStage.enabledKey] == "false")
        #expect(ctx.extra[CleanupStage.keepEdgesKey] == "true")
        #expect(ctx.extra[CleanupStage.skipKey] == nil)
        #expect(CleanupStage.skipReason([TranscriptSpan(text: "x", confidence: 0.9, audioRange: 0...1, provenance: [.asr])],
                                        context: ctx, mode: .always, hasGenerator: true) == nil)
    }

    @Test func endOfFieldInsertLeavesBothOn() {
        var ctx = StageContext(appBundleID: "com.apple.TextEdit")
        let field = FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea", isMultiline: true,
                                 textBeforeCursor: "Done. ", textAfterCursor: "")
        FieldRolePipeline.write(field, into: &ctx)
        #expect(ctx.extra[StyleStage.enabledKey] == nil)
        #expect(ctx.extra[CleanupStage.keepEdgesKey] == nil)
        #expect(ctx.extra[CleanupStage.skipKey] == nil)
    }

    @Test func verbatimAppRuleSkipsCleanupExplicitly() {
        var book = AppRuleBook()
        book.rules["com.apple.TextEdit"] = AppRule(bundleID: "com.apple.TextEdit", style: .verbatim)
        let ctx = book.resolved(for: "com.apple.TextEdit").apply(to: StageContext(appBundleID: "com.apple.TextEdit"))
        #expect(ctx.extra[StyleStage.enabledKey] == "false")
        #expect(ctx.extra[CleanupStage.skipKey] == "true")
        let natural = AppRuleBook().resolved(for: "com.apple.TextEdit").apply(to: StageContext(appBundleID: "com.apple.TextEdit"))
        #expect(natural.extra[CleanupStage.skipKey] == nil)
    }
}
