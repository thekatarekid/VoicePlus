import Testing
import Foundation
@testable import Actions

@Suite struct DeterministicFuzzyTests {
    @Test func scoring() {
        #expect(FuzzyMatch.score(query: "Sign in", candidate: "sign-in") == 1)
        #expect(FuzzyMatch.score(query: "merge", candidate: "Merge pull request") > 0.7)
        #expect(FuzzyMatch.score(query: "files changed", candidate: "Files changed (3)") > 0.8)
        #expect(FuzzyMatch.score(query: "cancle", candidate: "Cancel") > 0.75)
        #expect(FuzzyMatch.score(query: "delete", candidate: "Compose") < 0.5)
        #expect(FuzzyMatch.levenshtein("kitten", "sitting") == 3)
    }
    @Test func bestPrefersSpecific() {
        let m = FuzzyMatch.best("send", in: ["Send Later", "Send", "Sender"], label: { $0 })
        #expect(m?.item == "Send")
        #expect(FuzzyMatch.best("zzzz", in: ["Send"], label: { $0 }) == nil)
    }
    @Test func keyChords() {
        #expect(KeyChord("cmd+shift+t") == KeyChord(key: "t", modifiers: ["cmd", "shift"]))
        #expect(KeyChord("Command+,")?.key == ",")
        #expect(KeyChord("meta+x") == nil)
        #expect(KeyChord("") == nil)
    }
    @Test func spokenURL() {
        #expect(ActionExecutor.url(fromSpoken: "github dot com slash pulls")?.absoluteString == "https://github.com/pulls")
        #expect(ActionExecutor.url(fromSpoken: "https://x.y")?.absoluteString == "https://x.y")
        #expect(ActionExecutor.url(fromSpoken: "swift testing")?.absoluteString == "https://www.google.com/search?q=swifttesting")
    }
}

@Suite struct DeterministicCatalogTests {
    let catalog = try! ActionCatalog.load()

    @Test func has200UniqueWellFormedEntries() {
        #expect(catalog.entries.count == 200)
        #expect(Set(catalog.entries.map(\.id)).count == 200)
        for c in ActionCategory.allCases { #expect(catalog.entries.contains { $0.category == c }) }
        for e in catalog.entries {
            #expect(!e.phrasings.isEmpty, "\(e.id) has phrasings")
            switch e.kind {
            case .shortcut: #expect(KeyChord(e.params["keys"] ?? "") != nil, "\(e.id) chord")
            case .scroll: #expect(ScrollDirection(rawValue: e.params["direction"] ?? "") != nil, "\(e.id) dir")
            case .windowOp: #expect(WindowOp(rawValue: e.params["op"] ?? "") != nil, "\(e.id) op")
            default: break
            }
        }
        #expect(catalog.entries.contains { $0.reversibility == .irreversible })
    }

    @Test func everyPhrasingRoundTripsToItsEntry() {
        var misses: [String] = []
        for e in catalog.entries {
            for p in e.phrasings {
                let phrase = p.replacingOccurrences(of: "{arg}", with: DeterministicMockApps.argument(for: e))
                let m = catalog.match(phrase)
                if m?.entry.id != e.id { misses.append("\(e.id) '\(phrase)' -> \(m?.entry.id ?? "nil")") }
                if p.hasSuffix("{arg}"), m?.entry.id == e.id { #expect(m?.argument == DeterministicMockApps.argument(for: e)) }
            }
        }
        #expect(misses.isEmpty, "ambiguous phrasings: \(misses)")
    }

    @Test func fuzzyPhraseAndAppScoping() {
        #expect(catalog.match("scrol to the top")?.entry.id == "mac.scroll_top")
        #expect(catalog.match("open the PR tab", appKind: .browser)?.entry.id == "browser.pr_tab")
        #expect(catalog.match("open the pr tab", appKind: .editor)?.entry.id != "browser.pr_tab")
        #expect(catalog.match("open url github dot com")?.argument == "github dot com")
        #expect(catalog.match("Open file ~/Docs/a.txt")?.argument == "~/Docs/a.txt")
        #expect(catalog.match("type The Report, please")?.argument == "The Report, please")
        #expect(catalog.match("xyzzy plugh") == nil)
    }
}
