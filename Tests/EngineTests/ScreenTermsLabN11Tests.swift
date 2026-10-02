import Foundation
import Shared
import Testing
@testable import Engine

/// N11-lab (F27) — entity suite + distractor screens, accuracy with and without screen terms.
@Suite("Screen terms Lab (N11-lab)", .serialized)
struct ScreenTermsLabN11Tests {
    static func suite() throws -> ScreenTermsExperiment.Suite {
        try #require(try ScreenTermsExperiment.Suite.bundled(), "Fixtures/context/entity_screens.json")
    }

    static func references() throws -> [String: String] {
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/entity")
        let entries = try JSONDecoder().decode([FixtureEntry].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.file, $0.transcript) })
    }

    @Test func suiteCoversEveryEntityFixtureAndEntitiesAreSpoken() throws {
        let suite = try Self.suite(), refs = try Self.references()
        #expect(suite.items.count == refs.count)
        for item in suite.items {
            let ref = try #require(refs[item.file], "\(item.file)")
            for e in item.entities { #expect(ref.contains(e), "\(e) spoken in \(item.file)") }
            for e in item.entities { #expect(!item.distractor.contains(e), "distractor screen must not show \(e)") }
        }
    }

    @Test func defaultRubricKeepsScreenTermsOutOfTheBoostList() throws {
        #expect(ContextRubric.Config.default.screenTermsInBoost == false)
        let item = try #require(try Self.suite().items.first)
        let screen = ContextCandidates.screen(text: item.matching, caretOffset: item.matching.count)
        let r = ContextRubric.rank(candidates: screen, surface: ScreenTermsExperiment.surface(item.surface))
        #expect(r.boostTerms.isEmpty)
        #expect(!r.promptTerms.isEmpty, "screen terms still reach the cleanup prompt")
    }

    @Test func armsDifferOnlyByTheScreen() throws {
        let suite = try Self.suite()
        let exp = ScreenTermsExperiment(dictionary: suite.distractorTerms)
        var shownOnMatching = 0, expected = 0
        for item in suite.items {
            let none = exp.boostTerms(for: item, arm: .noScreen)
            let matching = exp.boostTerms(for: item, arm: .matchingScreen)
            let distractor = exp.boostTerms(for: item, arm: .distractorScreen)
            // No-screen arm: only the dictionary (minus words the collision rule holds back).
            #expect(Set(none.map { $0.lowercased() }).isSubset(of: Set(suite.distractorTerms.map { $0.lowercased() })), "\(item.file)")
            for e in item.entities {
                expected += 1
                if matching.contains(where: { $0.caseInsensitiveCompare(e) == .orderedSame }) { shownOnMatching += 1 }
                #expect(!none.contains(e) && !distractor.contains(e))
            }
            #expect(distractor.count <= none.count + ContextRubric.Config.default.perTurnBudget)
        }
        // The extractor must find most spoken entities on a matching screen, or the test is moot.
        #expect(Double(shownOnMatching) / Double(expected) >= 0.8, "\(shownOnMatching)/\(expected)")
    }

    /// Deterministic stand-in for the acoustic rescorer: the "recognizer" mishears every entity
    /// (drops each word's last letter) and a booster rewrites a heard word to a boost term whenever
    /// `BoostGuard` would accept the swap — the same guard the CTC path uses. Exercises the
    /// harness end to end without models.
    @Test func harnessMeasuresGainAndDistractorCost() async throws {
        let suite = try Self.suite(), refs = try Self.references()
        let exp = ScreenTermsExperiment(dictionary: suite.distractorTerms)
        func misheard(_ item: ScreenTermsExperiment.Item) -> String {
            var text = refs[item.file] ?? ""
            for e in item.entities {
                let garbled = e.split(separator: " ").map { $0.count > 3 ? String($0.dropLast()) : String($0) }.joined(separator: " ")
                text = text.replacingOccurrences(of: e, with: garbled)
            }
            return text
        }
        let metrics = await exp.run(items: suite.items, reference: { refs[$0.file] ?? "" }) { item, terms in
            misheard(item).split(separator: " ").map { raw -> String in
                let word = String(raw)
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                guard core.count > 2, let hit = terms.first(where: { !$0.contains(" ") && $0.lowercased() != core.lowercased()
                    && BoostGuard.accepts(original: core, replacement: $0) })
                else { return word }
                return word.replacingOccurrences(of: core, with: hit)
            }.joined(separator: " ")
        }
        let none = try #require(metrics[.noScreen]), match = try #require(metrics[.matchingScreen])
        let distractor = try #require(metrics[.distractorScreen])
        print(String(format: "N11-lab (simulated): recall %.2f → %.2f (matching) / %.2f (distractor); FI %.4f / %.4f / %.4f",
                     none.entityRecall, match.entityRecall, distractor.entityRecall,
                     none.falseInsertionRate, match.falseInsertionRate, distractor.falseInsertionRate))
        #expect(none.utterances == suite.items.count && match.utterances == none.utterances)
        #expect(match.entityRecall > none.entityRecall)
        #expect(distractor.entityRecall <= match.entityRecall)
        // The harness must see the cost too: look-alike screen words get swapped in (this is why
        // screen terms stay off by default until a real-model report passes the Lab gate).
        #expect(distractor.falseInsertionRate > none.falseInsertionRate)
    }

    /// The real measurement: Parakeet TDT v3 + the CTC rescorer. Skipped unless both models are on
    /// disk. Prints the three arms; the App writes the Lab report (`ScreenTermsDefault`).
    @Test(.timeLimit(.minutes(30)))
    func realRescorerWithAndWithoutScreenTerms() async throws {
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3), await manager.isPresent(.parakeetCTC110m) else {
            print("SKIPPED: N11-lab needs parakeet-tdt-0.6b-v3 and parakeet-ctc-110m on disk."); return
        }
        let suite = try Self.suite(), refs = try Self.references()
        let audio = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/entity")
        let models = try #require(try await manager.load(.parakeetTDTv3).asrModels)
        let decoder = try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.v3")
        let recognizer = DecoderFinalRecognizer(decoder: decoder)
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false)
        let exp = ScreenTermsExperiment(dictionary: suite.distractorTerms)
        let metrics = try await exp.run(items: suite.items, reference: { refs[$0.file] ?? "" }) { item, terms in
            let samples = try SampleAudioSource.load16k(url: audio.appendingPathComponent(item.file))
            recognizer.installBooster(terms.isEmpty ? nil : CTCVocabularyBooster(terms: terms, source: source))
            return try await recognizer.recognize(samples).joinedText
        }
        for arm in ScreenTermsExperiment.Arm.allCases {
            let m = metrics[arm] ?? BiasingMetrics()
            print(String(format: "N11-lab %@: recall %.3f (%d/%d) FI %d rate %.4f", arm.rawValue,
                         m.entityRecall, m.entitiesRecalled, m.entitiesExpected, m.falseInsertions, m.falseInsertionRate))
        }
        let none = metrics[.noScreen] ?? BiasingMetrics(), d = metrics[.distractorScreen] ?? BiasingMetrics()
        #expect(d.falseInsertionRate - none.falseInsertionRate <= 0.005, "distractor screens must not add false insertions")
    }
}
