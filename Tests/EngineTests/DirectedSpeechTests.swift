import Testing
import Foundation
@testable import Engine

/// P5.1 — unit tests for the ring, feature extractor, classifier and detector (synthetic signals only).
@Suite struct DirectedSpeechTests {
    static func tone(_ hz: Double, seconds: Double, amp: Float = 0.3, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }
    static func noise(seconds: Double, amp: Float = 0.05, seed: UInt64 = 1) -> [Float] {
        var s = seed
        return (0..<Int(seconds * 16_000)).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return amp * (Float(s >> 33) / Float(1 << 31) * 2 - 1)
        }
    }
    /// "Speech": 120 Hz tone bursts separated by silence, over a faint noise floor.
    static func bursts(count: Int, amp: Float = 0.3) -> [Float] {
        var out = noise(seconds: 0.2, amp: 0.002)
        for _ in 0..<count { out += tone(120, seconds: 0.25, amp: amp); out += noise(seconds: 0.15, amp: 0.002) }
        return out
    }

    // MARK: Ring
    @Test func ringKeepsOnlyLastTenSeconds() {
        let r = RollingAudioRing(seconds: 1, sampleRate: 100)
        r.append((0..<250).map(Float.init))
        #expect(r.count == 100)
        #expect(abs(r.streamTime - 2.5) < 1e-9)
        #expect(r.samples(in: 2.0...2.05) == [200, 201, 202, 203, 204])
        #expect(r.samples(in: 0...0.5).isEmpty)   // fell out of the ring
    }
    @Test func ringWipeZeroes() {
        let r = RollingAudioRing(seconds: 1, sampleRate: 100)
        r.append([Float](repeating: 1, count: 50)); r.wipe()
        #expect(r.count == 0); #expect(r.samples(in: 0...1).isEmpty)
    }

    // MARK: Features
    @Test func voicedToneHasPitchPeakNoiseDoesNot() {
        let ex = DirectedSpeechFeatureExtractor()
        let v = ex.extract(samples: Self.tone(150, seconds: 1), preview: "", context: .init())
        let n = ex.extract(samples: Self.noise(seconds: 1, amp: 0.3), preview: "", context: .init())
        #expect(v.voicedRatio > 0.9); #expect(n.voicedRatio < 0.2)
        #expect(n.zeroCrossingRate > v.zeroCrossingRate)
    }
    @Test func snrAndRateFromBursts() {
        let ex = DirectedSpeechFeatureExtractor()
        let f = ex.extract(samples: Self.bursts(count: 5), preview: "", context: .init())
        #expect(f.snrDB > 1)            // > 20 dB
        #expect(f.speakingRate > 0.3)   // ≈ 2.5 onsets/s / 5
        let quiet = ex.extract(samples: Self.bursts(count: 5, amp: 0.03), preview: "", context: .init())
        #expect(quiet.meanLevelDB < f.meanLevelDB)
    }
    @Test func emptyAudioYieldsContextOnly() {
        let f = DirectedSpeechFeatureExtractor().extract(samples: [], preview: "", context: .init(isTextFieldFocused: true, addressedRecently: true))
        #expect(f.previewEmpty == 1); #expect(f.isTextFieldFocused == 1); #expect(f.addressedRecently == 1); #expect(f.snrDB == 0)
    }
    @Test func keywordSpotter() {
        let k = KeywordSpotter()
        #expect(k.score(preview: "Type hello") == 1)
        #expect(k.score(preview: "Hey, send the thing") == 0.8)
        #expect(k.score(preview: "can you book it") == 0.35)
        #expect(k.score(preview: "yeah so anyway") == 0)
        #expect(k.score(preview: "") == 0)
    }
    @Test func featureVectorOrderMatchesNames() {
        #expect(DirectedSpeechFeatures().vector.count == DirectedSpeechFeatures.names.count)
        #expect(DirectedSpeechClassifier.handInitialisedWeights.count == DirectedSpeechFeatures.names.count)
        var f = DirectedSpeechFeatures(); f.keywordScore = 0.7
        #expect(f.vector[DirectedSpeechFeatures.names.firstIndex(of: "keywordScore")!] == 0.7)
    }

    // MARK: Classifier
    @Test func handWeightsFireOnStrongCueAndNotOnSilence() {
        let c = DirectedSpeechClassifier()
        let strong = DirectedSpeechFeatures(snrDB: 1.5, meanLevelDB: 0.6, voicedRatio: 0.7, zeroCrossingRate: 0.3, speakingRate: 0.5, keywordScore: 1, isTextFieldFocused: 1)
        let weak = DirectedSpeechFeatures(snrDB: 0.3, meanLevelDB: 0.2, voicedRatio: 0.2, zeroCrossingRate: 1.2, previewEmpty: 1)
        #expect(c.isDirected(strong)); #expect(!c.isDirected(weak))
        #expect(c.probability(strong) > c.probability(weak))
    }
    @Test func notYouLowersProbabilityAndResetRestores() {
        let c = DirectedSpeechClassifier()
        let f = DirectedSpeechFeatures(snrDB: 1.2, meanLevelDB: 0.5, voicedRatio: 0.6, keywordScore: 0.8, isTextFieldFocused: 1)
        let before = c.probability(f)
        for _ in 0..<5 { c.update(f, directed: false) }
        #expect(c.probability(f) < before); #expect(c.correctionCount == 5)
        c.reset()
        #expect(c.probability(f) == before); #expect(c.correctionCount == 0)
    }
    @Test func wasMeRaisesProbability() {
        let c = DirectedSpeechClassifier()
        let f = DirectedSpeechFeatures(snrDB: 0.6, voicedRatio: 0.4)
        let before = c.probability(f)
        c.update(f, directed: true)
        #expect(c.probability(f) > before)
    }

    // MARK: Detector
    @Test func detectorDecidesOnSpeechEnd() {
        let d = DirectedSpeechDetector()
        let audio = Self.bursts(count: 6)
        d.appendAudio(audio)
        d.preview = "type hello there"
        d.context = DirectedSpeechContext(isTextFieldFocused: true)
        #expect(d.handle(.speechStart(at: 0.2)) == nil)
        let end = Double(audio.count) / 16_000
        let dec = d.handle(.speechEnd(at: end))
        #expect(dec?.directed == true)
        #expect(dec?.features.keywordScore == 1)
        #expect(d.preview == "")            // consumed
        #expect(d.lastDecision == dec)
    }
    @Test func detectorRejectsQuietNoisyAmbient() {
        let d = DirectedSpeechDetector()
        let audio = Self.noise(seconds: 2, amp: 0.02)
        d.appendAudio(audio)
        d.preview = "yeah so anyway"
        d.handle(.speechStart(at: 0.1))
        let dec = d.handle(.speechEnd(at: 1.9))
        #expect(dec?.directed == false)
    }
    @Test func speechEndWithoutStartIsIgnored() {
        let d = DirectedSpeechDetector()
        #expect(d.handle(.speechEnd(at: 1)) == nil)
    }
    @Test func addressedRecentlyCarriesAcrossUtterances() {
        let d = DirectedSpeechDetector()
        let audio = Self.bursts(count: 6)
        d.appendAudio(audio); d.preview = "type hi"
        d.handle(.speechStart(at: 0.2)); let end = Double(audio.count) / 16_000
        #expect(d.handle(.speechEnd(at: end))?.directed == true)
        d.appendAudio(audio); d.preview = "and the report"
        d.handle(.speechStart(at: end + 0.2))
        let second = d.handle(.speechEnd(at: end * 2))
        #expect(second?.features.addressedRecently == 1)
        d.markNotYou()
        d.appendAudio(audio); d.preview = "and the report"
        d.handle(.speechStart(at: end * 2 + 0.2))
        #expect(d.handle(.speechEnd(at: end * 3))?.features.addressedRecently == 0)
        #expect(d.classifier.correctionCount == 1)
    }
    @Test func wipeClearsEverything() {
        let d = DirectedSpeechDetector()
        d.appendAudio(Self.bursts(count: 2)); d.preview = "x"
        d.handle(.speechStart(at: 0)); _ = d.handle(.speechEnd(at: 1))
        d.wipe()
        #expect(d.lastDecision == nil); #expect(d.ring.count == 0); #expect(d.preview == "")
    }
}
