import Foundation
import Testing
import Shared
@testable import Engine

/// R4.1b — the ranked context list: tier order, dedupe, the cap, and per-session lifetime.
@Suite("Ranked context list (R4.1b)")
struct ContextRankerTests {

    // MARK: helpers

    static func entries(_ pairs: [(String, ContextSourceKind)], at now: Date = Date(),
                        salience: Double = 1.0) -> [ContextEntry] {
        pairs.map { ContextEntry(text: $0.0, source: $0.1, observedAt: now, salience: salience) }
    }

    /// 500 distinct capitalised words, as a text editor full of prose would harvest.
    static func screenFlood(_ count: Int, prefix: String = "Screenword") -> [ContextEntry] {
        (0..<count).map {
            ContextEntry(text: "\(prefix)\($0)", source: .axTree, observedAt: Date(), salience: 1.0)
        }
    }

    // MARK: tier order

    @Test
    func tierMapsTheFourSourcesInV3Order() {
        #expect(ContextRanker.tier(for: .corrections) == .authored)
        #expect(ContextRanker.tier(for: .dictionary) == .authored)
        #expect(ContextRanker.tier(for: .axTree) == .screen)
        #expect(ContextRanker.tier(for: .codeSymbols) == .screen)
        #expect(ContextRanker.tier(for: .recentWords) == .recent)
        // Permissioned name sources sit in the lowest band, never above the user's own words.
        #expect(ContextRanker.tier(for: .contacts) == .recent)
        #expect(ContextRanker.tier(for: .participants) == .recent)
        #expect(ContextTier.authored < ContextTier.screen)
        #expect(ContextTier.screen < ContextTier.recent)
    }

    @Test
    func correctionsAndDictionaryOutrankEverythingElse() {
        let ranked = ContextRanker().rank(
            Self.entries([("Kothari", .corrections), ("Devanagari", .dictionary)])
                + Self.entries([("Mumbai", .axTree)], salience: 1.0)
                + Self.entries([("kubectl", .recentWords)])
        )
        let order = ranked.texts
        #expect(Set(order.prefix(2)) == ["Kothari", "Devanagari"])
        #expect(order.last == "kubectl")
        #expect(ranked.terms(in: .authored).count == 2)
        #expect(ranked.count(in: .screen) == 1)
    }

    /// The reason the list is tiered rather than scored: a screen full of prose must not be able to
    /// push a Dictionary entry out of a 400-term list.
    @Test
    func aFloodedScreenCannotDisplaceTheUsersOwnWords() {
        let ranked = ContextRanker().rank(
            Self.screenFlood(600) + Self.entries([("Devanagari", .dictionary), ("Kothari", .corrections)])
        )
        #expect(ranked.count == 400)
        #expect(ranked.cap == 400)
        #expect(ranked.contains("Devanagari"))
        #expect(ranked.contains("Kothari"))
        #expect(ranked.terms.first?.tier == .authored)
        #expect(ranked.dropped == 202)          // 602 considered, 400 kept
        #expect(ranked.considered == 602)
    }

    @Test
    func capIsFourHundredByDefaultAndHard() {
        #expect(RankedContext.defaultCap == 400)
        #expect(ContextRanker.defaultCap == 400)
        for count in [1, 399, 400, 401, 4_000] {
            let ranked = ContextRanker().rank(Self.screenFlood(count))
            #expect(ranked.count == min(count, 400))
            #expect(ranked.count <= ranked.cap)
        }
    }

    // MARK: dedupe

    @Test
    func duplicatesMergeIntoOneTermInTheHighestTier() {
        let ranked = ContextRanker().rank(Self.entries([
            ("kothari", .axTree), ("Kothari", .dictionary), ("KOTHARI", .recentWords),
        ]))
        #expect(ranked.count == 1)
        let term = ranked.terms.first
        #expect(term?.tier == .authored)
        #expect(term?.sources == [.axTree, .dictionary, .recentWords])
        // The capitalised spelling wins: it is the one worth putting in a prompt.
        #expect(term?.text == "Kothari" || term?.text == "KOTHARI")
    }

    @Test
    func orderIsDeterministicForEqualScores() {
        let now = Date()
        let input = Self.entries([("Bravo", .axTree), ("Alpha", .axTree), ("Charlie", .axTree)], at: now)
        let a = ContextRanker().rank(input, now: now).texts
        let b = ContextRanker().rank(input.reversed(), now: now).texts
        #expect(a == b)
        #expect(a == ["Alpha", "Bravo", "Charlie"])
    }

    @Test
    func sentenceLengthTermsAreNotTerms() {
        let long = String(repeating: "a", count: 65)
        let ranked = ContextRanker().rank(Self.entries([(long, .axTree), ("Priya", .axTree)]))
        #expect(ranked.texts == ["Priya"])
    }

    @Test
    func shapeIsCountsOnly() {
        let ranked = ContextRanker().rank(Self.entries([("Zephyr", .axTree)]))
        #expect(ranked.shape.contains("Zephyr") == false)
        #expect(ranked.shape.contains("1/400"))
    }

    // MARK: harvest integration

    @Test
    func harvestingThroughTheRealSourcesProducesOneTieredList() {
        let ring = RecentWordsRing()
        ring.record("kubectl rollout status")
        let harvester = ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText([("Kothari Priya Mumbai", 1.0)])),
            CorrectionSource(store: MockCorrectionStore(corrections: [("Menon", Date())],
                                                        dictionary: [("Devanagari", 1.0)])),
            ring,
        ])
        let ranked = ContextRanker().rank(harvesting: harvester)
        #expect(ranked.contains("Menon"))
        #expect(ranked.contains("Devanagari"))
        #expect(ranked.contains("Kothari"))
        #expect(ranked.contains("kubectl"))
        #expect(ranked.terms(in: .authored).map(\.text).sorted() == ["Devanagari", "Menon"])
        #expect(ranked.terms(in: .screen).isEmpty == false)
        #expect(ranked.terms(in: .recent).isEmpty == false)
    }

    // MARK: session lifetime

    @Test
    func theListIsRebuiltPerUtteranceAndDiscardedWithTheSession() {
        final class MutableScreen: FocusedWindowTextProvider, @unchecked Sendable {
            var text: String = "Kothari"
            func visibleStrings() -> [(String, Double)] { [(text, 1.0)] }
        }
        let screen = MutableScreen()
        let harvester = ContextHarvester(sources: [AXTreeSource(provider: screen)])
        let session = ContextSession(harvester: harvester)

        #expect(session.current.isEmpty)                        // nothing before the first utterance
        _ = session.rebuild()
        #expect(session.current.contains("Kothari"))

        screen.text = "Bandra"                                  // focus moved
        _ = session.rebuild()
        #expect(session.current.contains("Bandra"))
        #expect(session.current.contains("Kothari") == false, "the previous screen must not linger")
        #expect(session.rebuilds == 2)

        session.discard()
        #expect(session.current.isEmpty)
        #expect(harvester.lastEntries.isEmpty, "discard must drop the harvest, not just the list")
    }

    /// Privacy by construction: the list carries screen text, so it must not be serialisable at
    /// all. Nothing can put it in history, diagnostics or sync if it cannot be encoded (V3 §7.3).
    @Test
    func theRankedListCannotBeSerialised() {
        #expect(!(RankedContext.self is any Encodable.Type))
        #expect(!(RankedContext.self is any Decodable.Type))
        #expect(!(RankedContextTerm.self is any Encodable.Type))
        #expect(!(RankedContextTerm.self is any Decodable.Type))
        #expect(!(ContextEntry.self is any Encodable.Type))
    }
}
