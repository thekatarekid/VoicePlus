import Engine
import Foundation
import Injection
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

// INT-wiring — the turn's surface (N9) + shell (N13) + rubric candidates (N11) wired through one
// per-turn object, and the Settings rows for N10, N13, N25, N26 and the removed dwell.

@Suite struct IntWiringTests {
    static let terminalApp = FocusSnapshot(pid: 4242, bundleID: "com.apple.Terminal")
    static let shell = ShellContext(pid: 4300, shellName: "zsh", tty: "/dev/ttys004", currentDirectory: "/Users/me",
                                    entries: [.init(name: "Documents", isDirectory: true)], knownCommands: ["git", "ls"])

    // MARK: N9 + N13 resolution

    @Test func confidentNonTerminalFieldNeverProbesTheShell() {
        let field = FieldContext(appBundleID: "com.apple.mail", axRole: "AXTextArea", isMultiline: true)
        guard field.surface.kind != .terminal, !field.surface.isFallback, field.surface.confidence >= 0.5 else { return }
        var probed = false
        let r = TurnSurfaceContext.resolve(app: FocusSnapshot(pid: 1, bundleID: "com.apple.mail"), field: field,
                                           shell: { probed = true; return Self.shell })
        #expect(!probed)
        #expect(r.shell == nil)
        #expect(r.surface == field.surface)
    }

    @Test func terminalFieldCarriesTheShell() {
        let field = FieldContext(appBundleID: "com.apple.Terminal", axRole: "AXTextArea", isMultiline: true)
        #expect(field.surface.kind == .terminal)
        let r = TurnSurfaceContext.resolve(app: Self.terminalApp, field: field, shell: { Self.shell })
        #expect(r.surface.kind == .terminal)
        #expect(r.shell == Self.shell)
        #expect(!r.shellDecided)
    }

    @Test func undecidedFieldUsesPtyEvidence() {
        let app = FocusSnapshot(pid: 7, bundleID: "com.example.unknownterm")
        let field = FieldContext(appBundleID: app.bundleID, caret: .unknown)
        guard field.surface.isFallback || field.surface.confidence < 0.5 else { return }
        let r = TurnSurfaceContext.resolve(app: app, field: field, shell: { Self.shell })
        #expect(r.surface.kind == .terminal)
        #expect(r.shellDecided)
        let none = TurnSurfaceContext.resolve(app: app, field: field, shell: { nil })
        #expect(none.shell == nil && none.surface.kind != .terminal)
    }

    @Test func shellReachesTheStageContextOnlyInTheStartApp() {
        let r = TurnSurfaceContext.Resolved(bundleID: "com.apple.Terminal", pid: 4242,
                                            surface: SurfaceResolution(kind: .terminal, confidence: 0.9, isWebArea: false, signals: []),
                                            shell: Self.shell, shellDecided: true)
        let ctx = TurnSurfaceContext.write(r, into: StageContext(appBundleID: "com.apple.Terminal"), bundleID: "com.apple.Terminal")
        #expect(ShellContext(stageContext: ctx) == Self.shell)
        #expect(ctx.extra[FieldContext.Keys.surfaceKind] == SurfaceKind.terminal.id)
        let other = TurnSurfaceContext.write(r, into: StageContext(appBundleID: "com.apple.Safari"), bundleID: "com.apple.Safari")
        #expect(ShellContext(stageContext: other) == nil)
        var prose = r
        prose.surface = SurfaceResolution(kind: .prose, confidence: 0.9, isWebArea: false, signals: [])
        #expect(ShellContext(stageContext: TurnSurfaceContext.write(prose, into: StageContext(), bundleID: nil)) == nil)
    }

    @Test func beginResolvesOffThreadThenEndClears() async {
        let ctx = TurnSurfaceContext(field: { app in FieldContext(appBundleID: app.bundleID, axRole: "AXTextArea", isMultiline: true) },
                                     shell: { _ in Self.shell }, snapshot: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ctx.begin(app: Self.terminalApp) { done.resume() }
        }
        #expect(ctx.isBegun)
        #expect(ctx.surface()?.kind == .terminal)
        let cands = ctx.candidates()
        #expect(cands.contains { $0.text == "git" && $0.type == .command && $0.source == .surfaceLexicon })
        #expect(cands.contains { $0.text == "Documents" && $0.type == .path })
        let augmented = ctx.augment(StageContext(appBundleID: "com.apple.Terminal"), bundleID: "com.apple.Terminal")
        #expect(ShellContext(stageContext: augmented)?.currentDirectory == "/Users/me")
        ctx.end()
        #expect(!ctx.isBegun)
        #expect(ctx.surface() == nil)
        #expect(ctx.candidates().isEmpty)
    }

    @Test func noAppMeansNoTurn() {
        let ctx = TurnSurfaceContext(field: { _ in nil }, shell: { _ in nil }, snapshot: nil)
        var called = false
        ctx.begin(app: nil) { called = true }
        #expect(!called && !ctx.isBegun && ctx.surface() == nil)
    }

    @Test func snapshotTermsMapToTypedScreenCandidates() {
        let at = Date(timeIntervalSince1970: 100)
        let link = TurnSurfaceContext.candidate(SnapshotTermCandidate(text: "github.com", kind: .link, source: .visible,
                                                                      salience: 1.4, distance: 2, observedAt: at))
        #expect(link.type == .link && link.source == .screenWindow && link.evidence == 1 && link.onScreenNow)
        let tail = TurnSurfaceContext.candidate(SnapshotTermCandidate(text: "Priya", kind: .name, source: .documentTail,
                                                                      salience: 0.5, distance: 9, observedAt: at))
        #expect(tail.type == .person && tail.source == .screenWindow && tail.observedAt == at)
    }

    // MARK: N25 presets

    @Test func presetDefaultsFillGroupsThePerAppRuleLeftOpen() {
        let store = InMemorySettingsStore()
        SurfacePresetSettings.set("casual", forGroup: "chatComposer", store: store)
        SurfacePresetSettings.set("friendly", forGroup: "emailBody", store: store)
        SurfacePresetSettings.set("bogus", forGroup: "emailBody", store: store)   // ignored
        #expect(SurfacePresetSettings.presetID(forGroup: "emailBody", store: store) == "friendly")
        #expect(SurfacePresetSettings.presetID(forGroup: "prose", store: store) == "natural")
        var ctx = StageContext()
        ctx.extra[SurfacePresets.selectionKey] = "chatComposer=polished"
        let out = SurfacePresetSettings.apply(to: ctx, store: store)
        let sel = SurfacePresets.decode(out.extra[SurfacePresets.selectionKey])
        #expect(sel["chatComposer"] == "polished", "the app rule wins for its group")
        #expect(sel["emailBody"] == "friendly")
        // Choosing a group's default removes it; nothing stored → context untouched.
        SurfacePresetSettings.set("natural", forGroup: "chatComposer", store: store)
        SurfacePresetSettings.set("professional", forGroup: "emailBody", store: store)
        #expect(store.string(SurfacePresetSettings.key) == nil)
        #expect(SurfacePresetSettings.apply(to: StageContext(), store: store).extra[SurfacePresets.selectionKey] == nil)
    }

    @Test func presetSelectionReachesCleanupSkip() {
        let store = InMemorySettingsStore()
        SurfacePresetSettings.set("exact", forGroup: "prose", store: store)
        var ctx = SurfacePresetSettings.apply(to: StageContext(), store: store)
        ctx.extra[FieldContext.Keys.surfaceKind] = SurfaceKind.prose.id
        #expect(SurfacePresets.active(in: ctx)?.allowsCleanup == false)
    }

    // MARK: N26 mid-sentence cleanup switch

    @Test func midSentenceSwitchSkipsCleanupOnlyWhenOffAndMidSentence() {
        let store = InMemorySettingsStore()
        let mid = FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea", isMultiline: true,
                               textBeforeCursor: "I think the ", textAfterCursor: " is great.")
        let end = FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea", isMultiline: true,
                               textBeforeCursor: "Done. ", textAfterCursor: "")
        var read = false
        #expect(MidDocumentCleanupSettings.isEnabled(store))
        let on = MidDocumentCleanupSettings.apply(to: StageContext(), store: store) { read = true; return mid }
        #expect(on.extra[CleanupStage.skipKey] == nil && !read, "on (default): the field is not even read")
        MidDocumentCleanupSettings.setEnabled(false, store: store)
        #expect(MidDocumentCleanupSettings.apply(to: StageContext(), store: store) { mid }.extra[CleanupStage.skipKey] == "true")
        #expect(MidDocumentCleanupSettings.apply(to: StageContext(), store: store) { end }.extra[CleanupStage.skipKey] == nil)
        #expect(MidDocumentCleanupSettings.apply(to: StageContext(), store: store) { nil }.extra[CleanupStage.skipKey] == nil)
    }

    // MARK: N10 per-app off switch

    @Test func accessibilityOffAppsFeedTheInjectionReader() throws {
        let defaults = try #require(UserDefaults(suiteName: "IntWiringTests.\(UUID().uuidString)"))
        AccessibilityOffApps.add(" com.openai.chat ", defaults)
        AccessibilityOffApps.add("com.openai.chat", defaults)
        AccessibilityOffApps.add("company.thebrowser.dia", defaults)
        #expect(AccessibilityOffApps.list(defaults) == ["com.openai.chat", "company.thebrowser.dia"])
        #expect(InjectionSettingsKeys.accessibilityOff(bundleID: "com.openai.chat", defaults))
        AccessibilityOffApps.remove("com.openai.chat", defaults)
        #expect(!InjectionSettingsKeys.accessibilityOff(bundleID: "com.openai.chat", defaults))
        AccessibilityOffApps.remove("company.thebrowser.dia", defaults)
        #expect(defaults.object(forKey: AccessibilityOffApps.key) == nil)
    }

    // MARK: Settings view model rows

    @MainActor @Test func generalRowsWriteTheirKeys() {
        let store = InMemorySettingsStore()
        var prompts = 0
        let general = GeneralSettingsViewModel(store: store, fnConflict: { _ in nil }, openKeyboardSettings: {},
                                               applyTheme: { _ in }, shellFolderPrompt: { prompts += 1 })
        #expect(!general.shellFolderNames && general.midDocumentCleanup && !general.manualReview)
        general.shellFolderNames = true
        general.shellFolderNames = false
        general.shellFolderNames = true
        #expect(prompts == 1, "the protected-folder prompt is made once, from Settings")
        #expect(ShellFolderSettings.isEnabled(store) && ShellFolderSettings.wasPrompted(store))
        #expect(ShellContextProvider(settings: store).folderNamesAllowed)
        general.midDocumentCleanup = false
        #expect(!MidDocumentCleanupSettings.isEnabled(store))
        general.setPreset("concise", forGroup: "emailBody")
        #expect(general.preset(forGroup: "emailBody") == "concise")
        #expect(general.preset(forGroup: "terminal") == "command")
        #expect(SurfacePresetSettings.selection(store) == ["emailBody": "concise"])
    }
}
