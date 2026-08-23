import Testing
import Foundation
import Shared
@testable import Engine

/// P5.1 — metric harness over Fixtures/directed/manifest.json. Prints the numbers; asserts the corpus
/// shape and that the hand-initialised classifier beats the ship bar on the synthetic corpus.
@Suite struct DirectedSpeechHarnessTests {
    static func harness() throws -> DirectedSpeechHarness {
        DirectedSpeechHarness(fixturesDirectory: try #require(AppPaths.fixturesDirectory()))
    }

    @Test func corpusHasBothScenesAndLabels() throws {
        let c = try Self.harness().loadCorpus()
        #expect(c.filter(\.isAddressed).count == 12)
        #expect(c.filter { !$0.isAddressed }.count == 22)
        #expect(Set(c.map(\.scene)) == ["home", "office"])
    }

    @Test func handInitialisedWeightsMeetShipBar() throws {
        let h = try Self.harness()
        let m = try h.evaluate(classifier: DirectedSpeechClassifier())
        print("P5.1 harness (hand-initialised):", m)
        #expect(m.meetsShipBar, "\(m)")
        #expect(m.missedAddressRate <= 0.34, "\(m)")  // research item: prosody alone barely separates; content/context carry it
    }

    @Test func notYouCorrectionsNeverIncreaseFalseTriggers() throws {
        let h = try Self.harness()
        let base = try h.evaluate(classifier: DirectedSpeechClassifier())
        let c = DirectedSpeechClassifier()
        _ = try h.evaluate(classifier: c, onlineCorrections: true)
        let after = try h.evaluate(classifier: c)
        print("P5.1 harness (after one 'not you' pass):", after)
        #expect(after.falseTriggers <= base.falseTriggers)
        #expect(after.meetsShipBar)
    }

    @Test func learningFromMissesReducesMisses() throws {
        let h = try Self.harness()
        let base = try h.evaluate(classifier: DirectedSpeechClassifier())
        let c = DirectedSpeechClassifier()
        _ = try h.evaluate(classifier: c, onlineCorrections: true, learnFromMisses: true)
        let after = try h.evaluate(classifier: c)
        print("P5.1 harness (after one full pass):", after)
        #expect(after.missed <= base.missed)
    }

    @Test func featuresSeparateCleanFromNoisy() throws {
        let h = try Self.harness()
        let c = try h.loadCorpus()
        let clean = try h.features(for: try #require(c.first { $0.file.hasPrefix("clean/") }))
        let white = try h.features(for: try #require(c.first { $0.file.contains("snr00db_white") }))
        let far = try h.features(for: try #require(c.first { $0.file.contains("farfield") }))
        #expect(clean.snrDB > white.snrDB)
        #expect(clean.zeroCrossingRate < white.zeroCrossingRate)
        #expect(clean.meanLevelDB > far.meanLevelDB)
        for e in c { let f = try h.features(for: e); print(e.label, e.file, f.vector.map { String(format: "%.2f", $0) }) }
    }

    @Test func metricsArithmetic() {
        var m = DirectedSpeechMetrics()
        m.ambient = 200; m.falseTriggers = 1; m.addressed = 10; m.missed = 2
        #expect(abs(m.falseTriggersPerDay - 2.0) < 1e-9)
        #expect(!m.meetsShipBar)
        #expect(abs(m.missedAddressRate - 0.2) < 1e-9)
        m.falseTriggers = 0
        #expect(m.meetsShipBar)
    }

    @Test func experimentalFlagIsEngineLocalAndOff() {
        #expect(DirectedSpeechFlags.experimentalModeID.hasPrefix("engine.directedSpeech"))
        #expect(DirectedSpeechFlags.shipBarFalseTriggersPerDay == 1)
    }
}
