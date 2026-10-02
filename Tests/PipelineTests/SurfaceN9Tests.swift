import Foundation
import Testing
import Shared
@testable import Pipeline

/// N9 — the resolver inside the pipeline: one table, word-level guesses, chat versus code by
/// surface, and the codex persona reset.
@Suite("Surface resolver in the pipeline (N9)")
struct SurfaceN9Tests {
    @Test("the category table is derived from the merged seed table")
    func tableAgrees() {
        for (id, hint) in SeedHints.table {
            #expect(AppCategoryTable.category(for: id) == AppCategoryTable.category(for: hint.family), "\(id)")
        }
        #expect(AppCategoryTable.spreadsheetBundleIDs == SeedHints.bundleIDs(.spreadsheet))
    }

    @Test("unknown bundle ids are guessed by whole words only")
    func wordGuesses() {
        #expect(AppCategoryTable.category(for: "com.openai.codex") == .prose)
        #expect(AppCategoryTable.category(for: "com.example.codeshare") == .prose)
        #expect(AppCategoryTable.category(for: "com.example.console") == .prose)
        #expect(AppCategoryTable.category(for: "io.foo.terminal-pro") == .terminal)
        #expect(AppCategoryTable.category(for: "org.example.FancyMail") == .mail)
        #expect(AppCategoryTable.category(for: "com.googlecode.iterm2") == .terminal)
    }

    @Test("'Search console' is a search box, not a shell")
    func searchConsole() {
        let f = FieldContext(appBundleID: "com.example.cloud", axRole: "AXTextField", hints: ["Search console"])
        #expect(FieldRole.classify(f) == .singleLineText)
        #expect(FieldRules.rules(for: f).allowSubmit == false)
    }

    @Test("codex: prose by default, chat in a composer, never code by substring")
    func codex() {
        let plain = FieldContext(appBundleID: "com.openai.codex", axRole: "AXTextArea")
        #expect(FieldRole.classify(plain) == .multilineText)
        #expect(FieldRules.rules(for: plain).category == .prose)
        let composer = FieldContext(appBundleID: "com.openai.codex", axRole: "AXTextArea", hints: ["Ask Codex anything"])
        #expect(FieldRules.rules(for: composer).category == .chat)
        #expect(FieldRules.rules(for: composer).allowSubmit == false, "a multi-line composer never submits")
    }

    @Test("unknown apps get safe prose rules")
    func unknownProse() {
        let f = FieldContext(appBundleID: "org.nobody.app", axRole: "AXTextArea")
        let r = FieldRules.rules(for: f)
        #expect(r.role == .multilineText && r.category == .prose && !r.allowSubmit)
        #expect(f.surface.isFallback)
    }

    @Test("an upstream resolution travels through StageContext and wins")
    func upstream() {
        var ctx = StageContext()
        let field = FieldContext(appBundleID: "com.example.newterm", axRole: "AXTextArea")
        let r = SurfaceResolver.resolve(SurfaceEvidence(bundleID: "com.example.newterm", role: "AXTextArea",
                                                        shell: ShellContext(shellName: "zsh")))
        field.write(into: &ctx)
        FieldContext.write(r, into: &ctx)
        #expect(ctx.extra[FieldContext.Keys.surfaceKind] == "terminal")
        #expect(ctx.extra[FieldContext.Keys.surfaceSignals]?.contains("pty:zsh") == true)
        let back = FieldContext(stageContext: ctx)
        #expect(FieldRole.classify(back) == .terminal)
    }

    @Test("codex auto persona and cold-start style are reset once; edits are kept")
    func personaReset() throws {
        let personas = InMemoryPersonaStore(), styles = InMemoryStyleProfileStore()
        try personas.save(Persona(appBundleID: "com.openai.codex", text: "Terse code.", isAutoDrafted: true))
        try styles.save(StyleProfile.coldStart(appBundleID: "com.openai.codex", category: .code))
        let m = PersonaManager(store: personas, styles: styles)
        #expect(try m.resetMiscategorized() == ["com.openai.codex"])
        #expect(try personas.persona(for: "com.openai.codex") == nil)
        #expect(try styles.profile(for: "com.openai.codex")?.category == .prose)
        #expect(try m.resetMiscategorized().isEmpty, "idempotent")

        try personas.save(Persona(appBundleID: "com.openai.codex", text: "Mine.", isAutoDrafted: false))
        _ = try m.resetMiscategorized()
        #expect(try personas.persona(for: "com.openai.codex")?.text == "Mine.")
    }
}
