import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Pins the decoder configuration the app actually ships (V5 B1): `AppContainer.prepareForUtterance`
/// builds a boost list from the Dictionary + corrections (never the screen) and installs a final-pass
/// booster through `BiasingRecognizerProvider.install`; an empty list installs nothing.
@Suite("Shipping decoder configuration")
struct ShippingDecoderConfigTests {
    /// Minimal boostable `Decoder` that only has to record what was installed on it.
    final class SpyDecoder: Decoder, VocabularyBoostable, @unchecked Sendable {
        let name = "spy"
        var biaser: LogitBiaser?
        var booster: VocabularyBooster?
        func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult { DecodeResult(tokens: []) }
        func reset() async {}
    }

    static func provider(_ decoder: Decoder) async throws -> BiasingRecognizerProvider {
        let p = BiasingRecognizerProvider(inner: StaticRecognizerProvider(final: DecoderFinalRecognizer(decoder: decoder)))
        _ = try await p.resolve()
        return p
    }

    static func controller(dictionary: [String] = [], corrections: [String] = []) -> BoostingController {
        BoostingController(dictionary: { dictionary }, corrections: { corrections },
                           makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
    }

    /// A user with no Dictionary words and no corrections gets no booster at all: nothing to prefer.
    @Test
    func emptyVocabularyInstallsNoBooster() async throws {
        let decoder = SpyDecoder()
        let p = try await Self.provider(decoder)
        p.install(Self.controller().makeBoosterForUtterance())     // exactly AppContainer.prepareForUtterance()
        #expect(decoder.booster == nil)
        #expect(p.boostingInstalled == false)
    }

    /// Dictionary words reach the decoder as a booster; clearing clears.
    @Test
    func dictionaryReachesTheDecoder() async throws {
        let decoder = SpyDecoder()
        let p = try await Self.provider(decoder)
        let booster = try #require(Self.controller(dictionary: ["Kothari", "TeamViewer"]).makeBoosterForUtterance())
        p.install(booster)
        #expect(decoder.booster?.terms == ["Kothari", "TeamViewer"])
        #expect(p.boostingInstalled)

        p.install(nil)
        #expect(decoder.booster == nil, "clearing must actually clear, or one utterance's list leaks into the next")
    }

    /// Apple Speech has no decoder: the provider reports boosting off rather than pretending.
    @Test
    func nonDecoderRecognizerReportsBoostingOff() async throws {
        final class Plain: FinalRecognizer, @unchecked Sendable {
            let name = "plain"
            func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { [] }
        }
        let p = BiasingRecognizerProvider(inner: StaticRecognizerProvider(final: Plain()))
        _ = try await p.resolve()
        p.install(Self.controller(dictionary: ["Kothari"]).makeBoosterForUtterance())
        #expect(p.boostingInstalled == false)
    }

    /// The list is rebuilt per utterance, so a word added to the Dictionary is boosted next time.
    @Test
    func eachUtteranceRebuildsTheList() throws {
        final class Box: @unchecked Sendable { var words = ["Kothari"] }
        let box = Box()
        let c = BoostingController(dictionary: { box.words }, makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(c.makeBoosterForUtterance()?.terms == ["Kothari"])
        box.words.append("Priya")
        #expect(c.makeBoosterForUtterance()?.terms == ["Kothari", "Priya"])
    }

    /// The app wiring reads only authored sources: a screen-only term is never boosted.
    @Test
    func screenTextIsNeverBoosted() {
        let screenOnly = ContextRanker().rank([ContextEntry(text: "Zephyr", source: .axTree, observedAt: Date(), salience: 1)])
        let c = BoostingController(context: { _ in screenOnly }, dictionary: { ["Kothari"] },
                                   makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(c.makeBoosterForUtterance()?.terms == ["Kothari"])
    }
}
