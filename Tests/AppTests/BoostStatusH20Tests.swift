import Testing
import Foundation
import Engine
import Shared
@testable import VoicePlusApp

/// H20 — the booster reaches the recogniser the engine actually uses, and every turn records why
/// it was (or was not) rescored.
@Suite struct BoostStatusH20Tests {
    final class FakeDecoder: Decoder, VocabularyBoostable, @unchecked Sendable {
        let name = "fake"
        var biaser: LogitBiaser?
        var booster: VocabularyBooster?
        func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult { DecodeResult(tokens: []) }
        func reset() async {}
    }

    /// Like `ModelManagerRecognizerProvider`: a brand-new recogniser on every resolve.
    final class FreshProvider: RecognizerProvider, @unchecked Sendable {
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
            (DecoderFinalRecognizer(decoder: FakeDecoder()), nil)
        }
    }

    struct Terms: VocabularyBooster {
        let terms: [String]
        func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? { nil }
    }

    static func booster(of r: FinalRecognizer) -> VocabularyBooster? {
        ((r as? DecoderFinalRecognizer)?.decoder as? FakeDecoder)?.booster
    }

    @Test func boosterReachesEngineInstanceAfterAnotherCallerResolves() async throws {
        let p = BiasingRecognizerProvider(inner: FreshProvider())
        let engineFinal = try await p.resolve().final      // RealEngine prewarm
        let otherFinal = try await p.resolve().final       // correction / meeting / code-switch resolve
        #expect(engineFinal !== otherFinal)
        p.install(Terms(terms: ["hold-to-talk", "VoicePlus"]))
        #expect(Self.booster(of: engineFinal)?.terms == ["hold-to-talk", "VoicePlus"])  // pre-H20: nil
        #expect(Self.booster(of: otherFinal) != nil)
        #expect(p.boostingInstalled)
        #expect(p.boostTargetCount == 2)
    }

    @Test func recogniserResolvedAfterInstallGetsCurrentBooster() async throws {
        let p = BiasingRecognizerProvider(inner: FreshProvider())
        p.install(Terms(terms: ["Kubernetes"]))            // key-down before the cold-start resolve
        #expect(!p.boostingInstalled)
        let cold = try await p.resolve().final
        #expect(Self.booster(of: cold)?.terms == ["Kubernetes"])
        #expect(p.boostingInstalled)
    }

    @Test func clearingRemovesBoosterEverywhere() async throws {
        let p = BiasingRecognizerProvider(inner: FreshProvider())
        let a = try await p.resolve().final
        p.install(Terms(terms: ["x"]))
        p.install(nil)
        #expect(Self.booster(of: a) == nil)
        #expect(!p.boostingInstalled)
        let b = try await p.resolve().final
        #expect(Self.booster(of: b) == nil)
    }

    @Test func statusAndTermCountRecordedInExtras() {
        var extras = TurnRecordExtras()
        FinalPassTimingRecorder.apply(FinalPassTiming(recogniseMs: 90, totalMs: 100, boostStatus: .modelNotReady,
                                                      rawPreBoostText: "a", finalText: "a", boostTermCount: 14), to: &extras)
        #expect(FinalPassTimingRecorder.boostStatus(in: extras) == .modelNotReady)
        #expect(extras.stageMs?[FinalPassTimingRecorder.boostTermsKey] == 14)
        // A later pass for the same turn replaces the status (one status per turn).
        FinalPassTimingRecorder.apply(FinalPassTiming(recogniseMs: 90, totalMs: 100, boostStatus: .boosted,
                                                      rawPreBoostText: "a", finalText: "b", boostTermCount: 3), to: &extras)
        #expect(FinalPassTimingRecorder.boostStatus(in: extras) == .boosted)
        #expect(extras.stageMs?.keys.filter { $0.hasPrefix(FinalPassTimingRecorder.boostStatusPrefix) }.count == 1)
        #expect(extras.stageMs?[FinalPassTimingRecorder.boostTermsKey] == 3)
        // Survives the JSON round trip into extras_json.
        let data = try? JSONEncoder().encode(extras)
        let back = data.flatMap { try? JSONDecoder().decode(TurnRecordExtras.self, from: $0) }
        #expect(back.map { FinalPassTimingRecorder.boostStatus(in: $0) } == .boosted)
    }

    @Test func notAppliedRecordedWithZeroTerms() {
        var extras = TurnRecordExtras()
        FinalPassTimingRecorder.apply(FinalPassTiming(recogniseMs: 1, totalMs: 1, boostStatus: .notApplied,
                                                      rawPreBoostText: "", finalText: ""), to: &extras)
        #expect(FinalPassTimingRecorder.boostStatus(in: extras) == .notApplied)
        #expect(extras.stageMs?[FinalPassTimingRecorder.boostTermsKey] == 0)
    }
}
