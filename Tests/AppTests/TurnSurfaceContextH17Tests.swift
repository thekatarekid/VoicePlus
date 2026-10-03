import Engine
import Foundation
import Injection
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

/// H17 — the focused field's text around the caret becomes `.screenNear` candidates that reach the
/// per-turn boost layer; a secure field gives nothing; nothing is persisted.
@Suite struct TurnSurfaceContextH17Tests {
    static let claude = FocusSnapshot(pid: 77, bundleID: "com.anthropic.claudefordesktop", appName: "Claude")

    static func composer(before: String, after: String = "") -> FieldContext {
        var f = FieldContext(appBundleID: claude.bundleID, axRole: "AXTextArea", hints: ["Write your prompt to Claude"],
                             isMultiline: true, caret: after.isEmpty ? .endOfField(before: before) : .known(before: before, after: after))
        f.documentTitle = "Claude"
        f.upstreamSurface = .chatComposer
        return f
    }

    static func wait(_ ctx: TurnSurfaceContext) async {
        for _ in 0..<200 where ctx.current() == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func resolvedCarriesTheNearCaretContext() {
        let f = Self.composer(before: "why does hold-to-talk drop it? In case of ", after: " thanks")
        let r = TurnSurfaceContext.resolve(app: Self.claude, field: f, shell: { nil })
        let near = r.nearCaret
        #expect(near?.before == "why does hold-to-talk drop it? In case of ")
        #expect(near?.after == " thanks")
        #expect(near?.fieldLabel == "Write your prompt to Claude")
        #expect(near?.windowTitle == "Claude")
        #expect(near?.appName == "Claude")
        #expect(near?.surfaceKind == .chatComposer)
        #expect(near?.isSecure == false)
        #expect(TurnSurfaceContext.resolve(app: Self.claude, field: nil, shell: { nil }).nearCaret == nil)
    }

    @Test func nearCaretWindowIsBoundedInUTF16() {
        let long = String(repeating: "a", count: 2_000) + " hold-to-talk "
        let r = TurnSurfaceContext.resolve(app: Self.claude, field: Self.composer(before: long), shell: { nil })
        #expect(r.nearCaret?.before.utf16.count == CaretWindow.defaultWindow)
    }

    @Test func onScreenTermNearTheCaretReachesThePerTurnLayer() async throws {
        let f = Self.composer(before: "Can you check why hold-to-talk drops the full stop? In case of ")
        let ctx = TurnSurfaceContext(field: { _ in f }, shell: { _ in nil }, snapshot: nil)
        ctx.begin(app: Self.claude)
        await Self.wait(ctx)
        let cands = ctx.candidates()
        #expect(cands.contains { $0.text == "hold-to-talk" && $0.source == .screenNear && $0.caretDistance != nil })
        #expect(ctx.nearCaretCandidates().contains { $0.text == "hold-to-talk" })
        let surface = try #require(ctx.surface())
        let ranked = ContextRubric.rank(candidates: cands, surface: surface)
        #expect(ranked.perTurnLayer.contains { $0.text == "hold-to-talk" })
        ctx.end()
        #expect(ctx.candidates().isEmpty, "memory only: the turn's context is gone at turn end")
    }

    @Test func secureFieldGivesNothing() async {
        var f = FieldContext(appBundleID: "com.apple.Safari", axRole: "AXTextField", axSubrole: "AXSecureTextField",
                             caret: .endOfField(before: "hunter2-Password"))
        f.upstreamSurface = nil
        let ctx = TurnSurfaceContext(field: { _ in f }, shell: { _ in nil }, snapshot: nil)
        ctx.begin(app: FocusSnapshot(pid: 9, bundleID: "com.apple.Safari", appName: "Safari"))
        await Self.wait(ctx)
        let near = ctx.nearCaret()
        #expect(near?.isSecure == true)
        #expect(near?.before == "" && near?.after == "")
        #expect(ctx.candidates().isEmpty)
        #expect(ctx.nearCaretCandidates().isEmpty)
    }
}
