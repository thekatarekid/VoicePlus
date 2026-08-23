import Foundation

/// P5.1 — metric harness: false-trigger rate/day and missed-address rate over a labelled corpus
/// (`Fixtures/directed/manifest.json`). Run before trusting the classifier; decides whether the
/// mode ships default-on or stays opt-in "experimental".
public struct DirectedCorpusEntry: Codable, Equatable, Sendable {
    public var file: String           // relative to Fixtures/audio
    public var label: String          // "addressed" | "ambient"
    public var preview: String
    public var scene: String          // "home" | "office"
    public var textFieldFocused: Bool
    public var addressedRecently: Bool
    public var isAddressed: Bool { label == "addressed" }
}

public struct DirectedSpeechMetrics: Equatable, Sendable, CustomStringConvertible {
    public var addressed = 0, ambient = 0, falseTriggers = 0, missed = 0
    /// Simulated ambient utterances heard per day (home + office, ~8 h of background talk).
    public var ambientUtterancesPerDay = 400.0
    public var falseTriggerRate: Double { ambient == 0 ? 0 : Double(falseTriggers) / Double(ambient) }
    public var falseTriggersPerDay: Double { falseTriggerRate * ambientUtterancesPerDay }
    public var missedAddressRate: Double { addressed == 0 ? 0 : Double(missed) / Double(addressed) }
    public var meetsShipBar: Bool { falseTriggersPerDay < DirectedSpeechFlags.shipBarFalseTriggersPerDay }
    public var description: String {
        String(format: "addressed=%d ambient=%d falseTriggers=%d (%.1f/day) missed=%d (%.1f%%) shipBar=%@",
               addressed, ambient, falseTriggers, falseTriggersPerDay, missed, missedAddressRate * 100, meetsShipBar ? "PASS" : "FAIL → experimental")
    }
}

public struct DirectedSpeechHarness: Sendable {
    public var fixturesDirectory: URL
    public var extractor = DirectedSpeechFeatureExtractor()

    public init(fixturesDirectory: URL) { self.fixturesDirectory = fixturesDirectory }

    public func loadCorpus() throws -> [DirectedCorpusEntry] {
        let url = fixturesDirectory.appendingPathComponent("directed/manifest.json")
        return try JSONDecoder().decode([DirectedCorpusEntry].self, from: Data(contentsOf: url))
    }

    public func features(for e: DirectedCorpusEntry) throws -> DirectedSpeechFeatures {
        let wav = try WAVFile.read(url: fixturesDirectory.appendingPathComponent("audio/\(e.file)"))
        return extractor.extract(samples: wav.mono, preview: e.preview,
                                 context: DirectedSpeechContext(isTextFieldFocused: e.textFieldFocused, addressedRecently: e.addressedRecently))
    }

    /// Evaluate; when `onlineCorrections` is true every false trigger feeds a "not you" update (the
    /// signal the product actually collects) and, if `learnFromMisses`, every miss a "was me" update.
    public func evaluate(classifier: DirectedSpeechClassifier, corpus: [DirectedCorpusEntry]? = nil,
                         onlineCorrections: Bool = false, learnFromMisses: Bool = false) throws -> DirectedSpeechMetrics {
        var m = DirectedSpeechMetrics()
        for e in try corpus ?? loadCorpus() {
            let f = try features(for: e)
            let directed = classifier.isDirected(f)
            if e.isAddressed {
                m.addressed += 1
                if !directed { m.missed += 1; if onlineCorrections && learnFromMisses { classifier.update(f, directed: true) } }
            } else {
                m.ambient += 1
                if directed { m.falseTriggers += 1; if onlineCorrections { classifier.update(f, directed: false) } }
            }
        }
        return m
    }
}
