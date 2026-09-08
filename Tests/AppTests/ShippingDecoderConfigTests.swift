import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Pins the decoder configuration the app actually ships, so a test can never again pass against a
/// decoder the user never runs.
///
/// The gap this closes: every accuracy test resolved the recognizer with
/// `RecognizerFactory.makeFinal`, which leaves `decoder.biaser == nil`, while `AppContainer`
/// additionally calls `BiasingRecognizerProvider.install(biasing.makeBiaser())` on every
/// hotkey-down. Nothing asserted that those two agree, so "the app's real decoder config" was
/// untested by construction. These tests assert the whole install path end to end, and
/// `Tests/EngineTests/BiasedDecodeWERTests.swift` measures WER through it against the real model.
@Suite("Shipping decoder configuration")
struct ShippingDecoderConfigTests {
    /// Minimal `Decoder` that only has to record what was installed on it.
    final class SpyDecoder: Decoder, @unchecked Sendable {
        let name = "spy"
        var biaser: LogitBiaser?
        func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult { DecodeResult(tokens: []) }
        func reset() async {}
    }

    static func provider(_ decoder: Decoder) async throws -> BiasingRecognizerProvider {
        let p = BiasingRecognizerProvider(inner: StaticRecognizerProvider(final: DecoderFinalRecognizer(decoder: decoder)))
        _ = try await p.resolve()
        return p
    }

    static func controller(flagOn: Bool, screen: [String] = ["Quake Engine Release Notes", "Rishi Kothari", "TeamViewer AG"]) -> BiasingController {
        BiasingController(harvester: ContextHarvester(sources: [AXTreeSource(provider: MockFocusedWindowText(screen))]),
                          vocabulary: BiasVocabulary.synthetic(),
                          flags: .inMemory([FeatureFlag.contextBiasing.id: flagOn]))
    }

    /// **The production default.** `contextBiasing` has been `defaultOn: false` since P1.12 T2
    /// (DECISIONS.md), so with no override on disk `makeBiaser()` returns nil and the shipping app
    /// installs *no* biaser. If this test ever fails, the app started biasing decodes — go and read
    /// `BiasedDecodeWERTests` before deciding that is fine.
    @Test
    func shippingDefaultInstallsNoBiaser() async throws {
        #expect(FeatureFlag.contextBiasing.defaultOn == false)
        let flags = FeatureFlagService.inMemory()          // no overrides: production defaults
        #expect(flags.isEnabled(.contextBiasing) == false)

        let decoder = SpyDecoder()
        let p = try await Self.provider(decoder)
        let biasing = BiasingController(harvester: ContextHarvester(sources: []),
                                        vocabulary: BiasVocabulary.synthetic(), flags: flags)
        p.install(biasing.makeBiaser())                    // exactly AppContainer.prepareForUtterance()
        #expect(decoder.biaser == nil)
        #expect(p.biasingInstalled == false)
    }

    /// With the flag on, the biaser really does reach the decoder — i.e. the install path is live
    /// and `BiasedDecodeWERTests` is measuring something real, not a silently-dropped hook.
    @Test
    func flagOnReachesTheDecoder() async throws {
        let decoder = SpyDecoder()
        let p = try await Self.provider(decoder)
        let biaser = try #require(Self.controller(flagOn: true).makeBiaser())
        p.install(biaser)
        #expect(decoder.biaser != nil)
        #expect(p.biasingInstalled)
        #expect(biaser.tree.entryCount > 0, "an empty trie would make the biased path indistinguishable from the plain one")

        p.install(nil)
        #expect(decoder.biaser == nil, "clearing must actually clear, or one utterance's screen text leaks into the next")
    }

    /// The install path is only reachable through `DecoderFinalRecognizer`. Apple Speech has no
    /// decoder hook, and the provider must report that honestly rather than pretend biasing is on.
    @Test
    func nonDecoderRecognizerReportsBiasingOff() async throws {
        final class Plain: FinalRecognizer, @unchecked Sendable {
            let name = "plain"
            func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { [] }
        }
        let p = BiasingRecognizerProvider(inner: StaticRecognizerProvider(final: Plain()))
        _ = try await p.resolve()
        p.install(Self.controller(flagOn: true).makeBiaser())
        #expect(p.biasingInstalled == false)
    }

    /// `AppContainer` rebuilds the biaser per utterance from whatever is on screen *now*. Two
    /// different screens must produce two different tries — otherwise the harvest is stale and the
    /// "refresh on hotkey-down" contract is not being honoured.
    @Test
    func eachUtteranceRebuildsFromTheCurrentScreen() throws {
        let first = try #require(Self.controller(flagOn: true, screen: ["Rishi Kothari"]).makeBiaser())
        let second = try #require(Self.controller(flagOn: true, screen: ["Rishi Kothari", "TeamViewer AG", "Priya"]).makeBiaser())
        #expect(second.tree.entryCount > first.tree.entryCount)
    }

    /// Screen-harvested terms live only in the in-memory trie for the duration of one utterance.
    /// Nothing in the biasing path writes them to disk — the persisted vocabularies are the user's
    /// own dictionary and corrections, which they entered or confirmed. Guards the Build doc §1
    /// privacy stance the same way a test guards behaviour.
    @Test
    func harvestedScreenTextIsNotPersisted() throws {
        let harvester = ContextHarvester(sources: [AXTreeSource(provider: MockFocusedWindowText(["Acme Secret Project Zephyr"]))])
        let controller = BiasingController(harvester: harvester, vocabulary: BiasVocabulary.synthetic(),
                                           flags: .inMemory([FeatureFlag.contextBiasing.id: true]))
        _ = controller.makeBiaser()
        #expect(controller.lastEntries.contains { $0.text.contains("Zephyr") }, "the harvest should have seen it")

        // The only on-disk state the biasing path touches is the read-only vocabulary file.
        let support = AppPaths.supportDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        for name in files where name.hasSuffix(".json") {
            let text = (try? String(contentsOf: support.appendingPathComponent(name), encoding: .utf8)) ?? ""
            #expect(text.contains("Zephyr") == false, "harvested screen text reached \(name)")
        }
    }
}
