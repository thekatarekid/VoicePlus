import Foundation
import Testing
@testable import Actions

/// V5 CU6 — the 200 catalogue actions × (exact + 3 paraphrases) on the mock desktop. The > 90 %
/// paraphrase bar is gated with the real encoder in `AppTests/ComputerUseLayer2Tests`; here the
/// harness itself and the encoder-independent bars are checked.
@Suite struct ActCatalogEvalTests {
    static let catalog = try! ActionCatalog.load()

    @Test("the fixture covers every catalogue phrasing with 3 paraphrases, none of them an existing phrasing")
    func fixtureCoversTheCatalogue() throws {
        let set = try ActCatalogEvalSet.load()
        let phrasings = Self.catalog.entries.reduce(0) { $0 + $1.phrasings.count }
        #expect(Self.catalog.entries.count == 200)
        #expect(set.cases.count == phrasings, "re-run Fixtures/public/act-catalog/make_paraphrases.py after editing catalog.json")
        #expect(Set(set.cases.map(\.entry)) == Set(Self.catalog.entries.map(\.id)))
        let heads = Set(Self.catalog.entries.flatMap(\.phrasings).map { $0.replacingOccurrences(of: "{arg}", with: "").trimmingCharacters(in: .whitespaces) })
        for c in set.cases {
            #expect(c.paraphrases.count == 3, "\(c.text)")
            #expect(!c.paraphrases.contains { heads.contains($0) }, "\(c.paraphrases)")
        }
    }

    @Test("exact phrasings > 99 % (fuzzy catalogue alone and with retrieval); retrieval never adds misfires")
    func exactPhrasingsAndMisfires() async throws {
        let set = try ActCatalogEvalSet.load()
        let fuzzyOnly = await ActCatalogEval.run(set, catalog: Self.catalog, retrieval: nil)
        let retrieval = CatalogRetrievalIndex(catalog: Self.catalog, embedder: HashingPhraseEmbedder())
        let withRetrieval = await ActCatalogEval.run(set, catalog: Self.catalog, retrieval: retrieval)
        print(fuzzyOnly.summaryLine); print(withRetrieval.summaryLine)
        #expect(fuzzyOnly.exactHitRate > ActCatalogEvalReport.exactTarget)
        #expect(withRetrieval.exactHitRate > ActCatalogEvalReport.exactTarget)
        // The only exact miss is "cancel": the spoken-cancel control word, never a key press.
        #expect(withRetrieval.rows.filter { !$0.paraphrase && $0.outcome != .hit }.map(\.text) == ["cancel"])
        #expect(withRetrieval.misfires.count <= fuzzyOnly.misfires.count)
        // Misfires stay rare: ≤ 2 % of paraphrases (it was ~10 % before the CU6 matcher fixes).
        #expect(Double(withRetrieval.misfires.count) <= 0.02 * Double(withRetrieval.rows.filter(\.paraphrase).count))
    }

    @Test("a case is a hit only when the expected action runs with a successful readback")
    func outcomes() async {
        let set = ActCatalogEvalSet(name: "t", note: "", cases: [
            .init(entry: "browser.close_tab", app: "com.apple.Safari", phrasing: "close tab", text: "close tab", paraphrases: ["undo that", "zzz qqq"]),
            .init(entry: "mac.click_ok", app: "com.apple.Notes", phrasing: "click ok", text: "click ok", paraphrases: ["press ok"]),
        ])
        let r = await ActCatalogEval.run(set, catalog: Self.catalog, retrieval: nil)
        #expect(r.rows.map(\.outcome) == [.hit, .misfire, .fellThrough, .hit, .hit])   // "press ok" = mac.click {ok}: same action
        #expect(r.exactHitRate == 1)
        #expect(abs(r.paraphraseHitRate - 1.0 / 3) < 1e-9)
    }

    @Test("the report is written as a V1-style result file")
    func writesResult() async throws {
        let set = ActCatalogEvalSet(name: "act-mini", note: "", cases: [
            .init(entry: "mac.scroll_down", app: "com.apple.Notes", phrasing: "scroll down", text: "scroll down", paraphrases: ["scroll down please"]),
        ])
        let r = await ActCatalogEval.run(set, catalog: Self.catalog, retrieval: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cu6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try r.write(to: dir, date: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(url.lastPathComponent == "2026-09-21-act-mini-none.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["stage"] as? String == "act")
        #expect(json["model"] as? String == "catalog+none")
        #expect((json["peakRSSBytes"] as? Int ?? 0) > 0)
        #expect((json["summary"] as? [String: Any])?["exact"] as? Double == 1)
    }
}
