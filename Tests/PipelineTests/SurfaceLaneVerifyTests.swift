import Testing
import Shared
@testable import Pipeline

/// Verifier probes for N9 / N12 / N13 — adversarial cases next to the implementers' own suites.
@Suite struct SurfaceLaneVerifyTests {
    typealias E = SurfaceEvidence
    typealias G = SurfaceGrammarN12Tests

    // N9 — secure is a veto, whatever else votes.
    @Test func secureVetoesEveryOtherSignal() {
        let a = SurfaceResolver.resolve(E(bundleID: "com.apple.Terminal", secureInputActive: true, role: "AXTextArea"))
        #expect(a.kind == .secure && a.refusesTyping)
        let b = SurfaceResolver.resolve(E(bundleID: "com.google.Chrome", role: "AXTextField", label: "Password", isInWebArea: true))
        #expect(b.kind == .secure)
        let c = SurfaceResolver.resolve(E(bundleID: "com.example.x", role: "AXSecureTextField"))
        #expect(c.kind == .secure)
    }

    // N9 — word-level guesses: brand words containing "code"/"chat"/"term" are not surfaces.
    @Test func unknownBrandWordsGetSafeProse() {
        for id in ["com.example.codexify", "com.acme.encoder", "com.example.chatterbox", "com.example.determinism"] {
            let r = SurfaceResolver.resolve(E(bundleID: id, role: "AXTextArea"))
            #expect(r.kind == .prose, "\(id) -> \(r.kind)")
        }
    }

    // N12 — prose must not invent structure from ordinary speech.
    @Test func proseFalsePositives() async {
        let a = await G.field("meet me at the office at noon", G.prose).text
        #expect(!a.contains("@"))
        let b = await G.field("equals sum of the parts", G.prose).text
        #expect(!b.contains("=SUM"))
        let c = await G.field("he said plus one to that", G.prose).text
        #expect(!c.contains("+"))
    }

    // N12 — address bar search phrase: no capital, no period, no Return.
    @Test func addressBarSearchPhrase() async {
        let out = await G.field("How to cook pasta.", G.addressBar)
        #expect(out.text == "how to cook pasta")
        #expect(!out.text.contains("\n") && out.allowSubmit == false)
        #expect(await G.field("google dot com", G.addressBar).text == "google.com")
    }

    // N13 — close match silently, otherwise words kept; never a Return.
    @Test func pathMatchSilentOnlyWhenClose() async {
        let shell = ShellContext(shellName: "zsh", currentDirectory: "/Users/me",
                                 entries: [.init(name: "Documents", isDirectory: true),
                                           .init(name: "Downloads", isDirectory: true)],
                                 knownCommands: ["git"])
        let a = await G.terminal("cd documents", shell: shell)
        #expect(a == "cd Documents/")
        let b = await G.terminal("cd pictures", shell: shell)
        #expect(b == "cd pictures")
        #expect(!a.contains("\n") && !b.contains("\n"))
    }
}
