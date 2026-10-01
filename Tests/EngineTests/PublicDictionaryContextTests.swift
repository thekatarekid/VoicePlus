import Foundation
import Testing
import Shared
@testable import Engine

/// V5 P2 (local names), P4 (CMUdict phoneme path), P7 (typed entities into the `.screen` tier).
@Suite("Public dictionaries — context (V5 P2/P4/P7)")
struct PublicDictionaryContextTests {

    static func sampleLexicon() throws -> PhonemeLexicon {
        let url = try #require(AppPaths.fixturesDirectory()?.appendingPathComponent("dictionaries/cmudict-sample.dict"))
        return PhonemeLexicon(cmudictText: try String(contentsOf: url, encoding: .utf8))
    }

    static func context(_ words: [String], tier: ContextTier = .recent) -> RankedContext {
        RankedContext(terms: words.map { RankedContextTerm(text: $0, tier: tier, score: 1, sources: [.contacts]) },
                      cap: RankedContext.defaultCap, considered: words.count)
    }

    // MARK: P4 — CMUdict

    @Test func cmudictParsesVariantsStressAndComments() throws {
        let lexicon = try Self.sampleLexicon()
        #expect(lexicon.pronunciations(of: "Sean") == [["SH", "AO", "N"]])
        #expect(lexicon.pronunciations(of: "niamh").count == 2)                      // niamh, niamh(2)
        #expect(lexicon.pronunciations(of: "aalborg").first == ["AO", "L", "B", "AO", "R", "G"]) // "# place, danish" stripped
        #expect(lexicon.pronunciations(of: "Sean's") == [["SH", "AO", "N", "Z"]])
        #expect(lexicon.pronunciations(of: "zzyzx").isEmpty)
        #expect(lexicon.similarity("steven", "stephen") == 1)
    }

    @Test func phonemePathFindsWhatMetaphoneMisses() throws {
        let lexicon = try Self.sampleLexicon()
        let ctx = Self.context(["Sean", "Niamh", "Kothari"])
        // Double Metaphone alone: "Shawn" (XN) and "Sean" (SN) share no code; "neve" ≠ "Niamh".
        let spelledOnly = ContextGate.nearMisses(hypothesis: "ask Shawn and neve today", context: ctx)
        #expect(!spelledOnly.contains { $0.candidate == "Sean" })
        #expect(!spelledOnly.contains { $0.candidate == "Niamh" })
        let both = ContextGate.nearMisses(hypothesis: "ask Shawn and neve today", context: ctx, lexicon: lexicon)
        #expect(both.contains { $0.heard == "Shawn" && $0.candidate == "Sean" && $0.similarity == 1 })
        #expect(both.contains { $0.heard == "neve" && $0.candidate == "Niamh" })
        // Without a lexicon the overload is exactly the metaphone answer.
        #expect(ContextGate.nearMisses(hypothesis: "ask Shawn", context: ctx, lexicon: nil) == spelledOnly.filter { $0.heard == "Shawn" })
        // A list word heard verbatim is not a near miss on either path.
        #expect(ContextGate.nearMisses(hypothesis: "ask Sean", context: ctx, lexicon: lexicon).isEmpty)
    }

    @Test func combinedIndexKeepsMetaphoneHitsWhenNoPronunciation() throws {
        let lexicon = try Self.sampleLexicon()
        let index = CombinedPhoneticIndex(context: Self.context(["Kothari"]), lexicon: lexicon)
        // "Kotari" is not in CMUdict: the metaphone path still answers.
        #expect(index.neighbour(of: "Kotari", minSimilarity: 0.55)?.candidate == "Kothari")
    }

    @Test func installedLexiconIsAbsentUntilDownloaded() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).dict")
        #expect(PhonemeLexicon.installed(at: missing) == nil)
        let url = try #require(AppPaths.fixturesDirectory()?.appendingPathComponent("dictionaries/cmudict-sample.dict"))
        #expect(PhonemeLexicon.installed(at: url)?.pronunciations(of: "shawn").isEmpty == false)
    }

    // MARK: P2 — local names

    @Test func localNamesLandInTheRecentTier() {
        let source = LocalNamesSource(
            apps: StaticAppNames(["Linear.app", "Visual Studio Code", "Linear", "Foo Uninstaller", "Zoom Helper", "X"]),
            attendees: StaticAttendees(["Priya Kothari", "Ankit"]),
            documents: StaticDocumentPaths(["/Users/me/Developer/VoiceInput/Pipeline/CasingStage.swift", "/tmp/index.html"]))
        let now = Date()
        let entries = source.harvest(now: now)
        let texts = Set(entries.map(\.text))
        #expect(texts.isSuperset(of: ["Linear", "Visual Studio Code", "Priya Kothari", "Ankit", "CasingStage", "VoiceInput"]))
        #expect(!texts.contains("Foo Uninstaller") && !texts.contains("Zoom Helper") && !texts.contains("index") && !texts.contains("X"))
        #expect(entries.filter { $0.text == "Linear" }.count == 1)
        for entry in entries { #expect(ContextRanker.tier(for: entry.source) == .recent) }
        let ranked = ContextRanker().rank(entries, now: now)
        #expect(ranked.terms.allSatisfy { $0.tier == .recent })
    }

    @Test func recentFileNamesOutliveTheOpenDocumentForAWindow() {
        final class Docs: RecentDocumentPathsProvider, @unchecked Sendable {
            var paths: [String] = []
            func openDocumentPaths() -> [String] { paths }
        }
        let docs = Docs()
        let source = LocalNamesSource(apps: StaticAppNames([]), documents: docs, recentWindow: 3600)
        let t0 = Date()
        docs.paths = ["/Users/me/code/Paperclip/README.md", "/Users/me/Desktop/Quarterly Plan.key"]
        #expect(Set(source.harvest(now: t0).map(\.text)) == ["Paperclip", "Quarterly Plan"])
        docs.paths = []
        #expect(Set(source.harvest(now: t0.addingTimeInterval(600)).map(\.text)) == ["Paperclip", "Quarterly Plan"])
        #expect(source.harvest(now: t0.addingTimeInterval(4000)).isEmpty)
    }

    @Test func appNamesAreCachedForTheTTL() {
        final class Counting: InstalledAppNamesProvider, @unchecked Sendable {
            var calls = 0
            func installedAppNames() -> [String] { calls += 1; return ["Figma"] }
        }
        let apps = Counting()
        let source = LocalNamesSource(apps: apps, appsTTL: 60)
        let t0 = Date()
        _ = source.harvest(now: t0)
        _ = source.harvest(now: t0.addingTimeInterval(30))
        #expect(apps.calls == 1)
        _ = source.harvest(now: t0.addingTimeInterval(90))
        #expect(apps.calls == 2)
    }

    // MARK: P7 — typed entities

    @Test func typedEntitiesEnterTheScreenTierWithTheirType() {
        let registry = EntityTypeRegistry()
        let typer = HeuristicEntityTyper(people: ["Priya"], products: ["Linear"])
        let source = TypedEntitySource(
            text: MockFocusedWindowText(["Priya Kothari said Linear ships the useEffect fix with Acme Inc on Friday"]),
            classifier: typer, registry: registry)
        let entries = source.harvest(now: Date())
        #expect(entries.allSatisfy { ContextRanker.tier(for: $0.source) == .screen })
        #expect(registry.type(of: "Priya Kothari") == .person)
        #expect(registry.type(of: "Linear") == .product)
        #expect(registry.type(of: "useEffect") == .technology)
        #expect(registry.type(of: "Acme Inc") == .organization)
        #expect(entries.contains { $0.text == "Priya Kothari" })
    }

    @Test func modelTyperAnswersAfterPrepareAndHeuristicFallsBack() async {
        let model = GLiNER2EntityTyper(classify: { text, labels in
            #expect(labels.count <= 8)
            return text.hasPrefix("Pune") ? (EntityType.place.label, 0.9) : (EntityType.other.label, 0.2)
        })
        #expect(model.isAvailable)
        await model.prepare(["Pune", "Zorblax"], context: "flying to Pune with Zorblax")
        #expect(model.cachedType(for: "Pune") == .place)
        #expect(model.cachedType(for: "Zorblax") == nil)       // below minProbability
        let layered = LayeredEntityTyper(model: model, heuristic: HeuristicEntityTyper(people: ["Zorblax"]))
        #expect(layered.cachedType(for: "Pune") == .place)
        #expect(layered.cachedType(for: "Zorblax") == .person)
        #expect(!GLiNER2EntityTyper(classify: nil).isAvailable)
        #expect(GLiNER2EntityTyper.snippet(around: "Pune", in: String(repeating: "x", count: 500) + " Pune " + String(repeating: "y", count: 500)).count <= 150)
    }

    @Test func rankedTermExposesItsType() {
        EntityTypeRegistry.shared.set(.product, for: "Zzlinear-test")
        let term = RankedContextTerm(text: "Zzlinear-test", tier: .screen, score: 1, sources: [.axTree])
        #expect(term.entityType == .product)
    }

    // MARK: Verify fixes

    final class CountingAttendees: CalendarAttendeesProvider, @unchecked Sendable {
        var calls = 0
        func attendeeNames(around date: Date) -> [String] { calls += 1; return ["Meera Iyer"] }
    }

    @Test func calendarAttendeesAreCachedBetweenHarvests() {
        let attendees = CountingAttendees()
        let source = LocalNamesSource(apps: StaticAppNames([]), attendees: attendees)
        let now = Date()
        _ = source.harvest(now: now)
        _ = source.harvest(now: now.addingTimeInterval(30))
        #expect(attendees.calls == 1)
        let later = source.harvest(now: now.addingTimeInterval(LocalNamesSource.attendeesTTL + 1))
        #expect(attendees.calls == 2 && later.contains { $0.text == "Meera Iyer" })
    }

    @Test func gliner2RegistersWithResidencyOnlyWhenWeightsArePresent() async {
        let residency = ModelResidency(budgetBytes: 1 << 30)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("gliner2-absent-\(UUID().uuidString)")
        let typer = await GLiNER2EntityTyper.load(from: empty, residency: residency)
        #expect(typer == nil)
        let registered = await residency.isRegistered(GLiNER2EntityTyper.residencyKey)
        #expect(!registered)
    }

    @Test func contextGateUsesThePhonemePathWhenALexiconIsGiven() throws {
        let lexicon = try Self.sampleLexicon()
        let context = Self.context(["Sean"])
        let metaphoneOnly = ContextGate.nearMisses(hypothesis: "call shawn now", context: context, lexicon: nil)
        let withPhonemes = ContextGate.nearMisses(hypothesis: "call shawn now", context: context, lexicon: lexicon)
        #expect(withPhonemes.contains { $0.candidate == "Sean" })
        #expect(withPhonemes.count >= metaphoneOnly.count)
    }
}
