import Foundation
import Testing
@testable import Shared

private func roundTrip<T: Codable & Equatable>(_ value: T, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value, sourceLocation: sourceLocation)
}

@Suite struct TypesTests {
    @Test func moduleMarker() {
        #expect(SharedModule.name == "Shared")
    }

    @Test func transcriptSpanRoundTrip() throws {
        let span = TranscriptSpan(
            text: "Kothari", confidence: 0.29, audioRange: 0.75...1.3,
            alternates: [Alternate(text: "Kotari", score: 0.28, source: .beam)],
            provenance: [.asr, .biasing], needsRepair: true
        )
        try roundTrip(span)
        try roundTrip([span, span.touched(by: .gatekeeper)])
    }

    @Test func transcriptSpanClampsConfidence() {
        #expect(TranscriptSpan(text: "x", confidence: 1.7, audioRange: 0...1).confidence == 1)
        #expect(TranscriptSpan(text: "x", confidence: -0.2, audioRange: 0...1).confidence == 0)
    }

    @Test func transcriptSpanDecodesMinimalKeysWithDefaults() throws {
        let json = #"{"text":"hi","confidence":0.9,"audioStart":0.1,"audioEnd":0.4}"#
        let span = try JSONDecoder().decode(TranscriptSpan.self, from: Data(json.utf8))
        #expect(span.text == "hi")
        #expect(span.audioRange == 0.1...0.4)
        #expect(span.alternates.isEmpty)
        #expect(span.provenance.isEmpty)
        #expect(!span.needsRepair)
    }

    @Test func stageIDEncodesAsPlainString() throws {
        let data = try JSONEncoder().encode([StageID.formatterEmail])
        #expect(String(decoding: data, as: UTF8.self) == #"["formatter.email"]"#)
        let custom: StageID = "myStage"
        try roundTrip(custom)
        #expect(StageID.known.count == 11)
    }

    @Test func utteranceRoundTrip() throws {
        let utterance = Utterance(
            spans: [TranscriptSpan(text: "hello", confidence: 0.9, audioRange: 0...0.5, provenance: [.asr])],
            startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_002),
            register: .email, route: .dictate
        )
        try roundTrip(utterance)
        #expect(utterance.text == "hello")
        #expect(utterance.duration == 2)
    }

    @Test func engineStateRoundTrip() throws {
        let quality = MicQuality(snr: 9.5, clipping: 0.02, lowLevel: false, verdict: .poor)
        let states: [EngineState] = [
            .idle, .prewarming, .listening(level: 0.4), .previewing(text: "hi"), .finalizing, .landed,
            .warning(quality), .error("boom"),
        ]
        try roundTrip(states)
        #expect(EngineState.listening(level: 0).isActive)
        #expect(!EngineState.idle.isActive)
        #expect(EngineState.warning(quality).caseName == "warning")
    }

    @Test func featureFlagRoundTripAndDefaults() throws {
        try roundTrip(FeatureFlag.all)
        #expect(FeatureFlag.contextBiasing.defaultOn)
        #expect(FeatureFlag.voiceRepair.defaultOn)
        #expect(!FeatureFlag.dualPath.defaultOn)
        #expect(!FeatureFlag.cloudASR.defaultOn)
        #expect(Set(FeatureFlag.all.map(\.id)).count == FeatureFlag.all.count)
    }

    @Test func spanHelpersAppendProvenance() {
        let span = TranscriptSpan(text: "a", confidence: 0.3, audioRange: 0...1, provenance: [.asr])
        #expect(span.flaggedForRepair(by: .gatekeeper).provenance == [.asr, .gatekeeper])
        #expect(span.flaggedForRepair(by: .gatekeeper).needsRepair)
        #expect(span.rewritten("b", by: .style).text == "b")
        #expect(span.isLowConfidence)
    }
}
