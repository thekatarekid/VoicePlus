import Foundation
import Testing
import Shared
@testable import Engine

/// R1.5 · V3 §5.2 — the preview's light formatting, and the promise it must never break:
/// no punctuation it did not hear.
@Suite("Preview formatter")
struct PreviewFormatterTests {

    @Test func capitalizesTheStartAndBareI() {
        #expect(PreviewFormatter.format("hey are you free for a quick call") == "Hey are you free for a quick call")
        #expect(PreviewFormatter.format("i think we should wait") == "I think we should wait")
        #expect(PreviewFormatter.format("well i'm not sure i'll go") == "Well I'm not sure I'll go")
        // Not sentence-initial and not "I": left alone, because without punctuation there is no
        // way to know a sentence started.
        #expect(PreviewFormatter.format("she said the report is ready but i doubt it")
                == "She said the report is ready but I doubt it")
    }

    /// V5 K7 — numbers are the installed normaliser's job (in the app, `Pipeline.ITNStage`; the
    /// digit goldens live in `Tests/AppTests/ITNAgreementTests.swift`). The preview only capitalises.
    @Test func numbersComeFromTheInjectedNormalizer() {
        let stub: @Sendable (String) -> String = { $0.replacingOccurrences(of: "twenty five", with: "25") }
        #expect(PreviewFormatter.format("i think twenty five people", normalizer: stub) == "I think 25 people")
        #expect(PreviewFormatter.format("twenty five people", normalizer: stub) == "25 people")
        #expect(PreviewFormatter.format("twenty five people", normalizer: nil) == "Twenty five people")
        // The normaliser runs before capitalisation, so a sentence-initial number word it leaves alone is capitalised.
        #expect(PreviewFormatter.format("four of us", normalizer: stub) == "Four of us")
    }

    @Test func numberWrittenFormsAreNotPunctuationClaims() {
        #expect(PreviewFormatter.addsNoPunctuation(input: "at three thirty", output: "At 3:30"))
        #expect(PreviewFormatter.addsNoPunctuation(input: "twelve lakh", output: "12,00,000"))
        #expect(!PreviewFormatter.addsNoPunctuation(input: "hello there", output: "Hello, there"))
    }

    @Test func neverClaimsPunctuation() {
        let inputs = [
            "hey are you free for a quick call",
            "please transcribe this exactly as i say it including the pause here",
            "the invoice total is two thousand three hundred forty rupees not two thousand four hundred thirty",
            "run swift build with the isolated scratch path and send me the output",
            "i think we should um wait for the numbers before we decide",
            "",
            "   ",
            "one",
        ]
        for input in inputs {
            let output = PreviewFormatter.format(input)
            #expect(PreviewFormatter.addsNoPunctuation(input: input, output: output),
                    "formatting invented punctuation: '\(input)' → '\(output)'")
            #expect(!output.hasSuffix("."))
            #expect(!output.contains("?"))
        }
    }

    @Test func isIdempotentAndSafeOnEdges() {
        for input in ["", " ", "hey", "twenty five", "i'm here", "HEY already capital"] {
            let once = PreviewFormatter.format(input)
            #expect(PreviewFormatter.format(once) == once, "not idempotent for '\(input)'")
        }
        #expect(PreviewFormatter.format("") == "")
        #expect(PreviewFormatter.format("HEY already capital") == "HEY already capital")
    }

    @Test func keepsWordCountExceptWhereNumbersMerge() {
        // Word count is what WER scores, so the formatter must not add or drop words other than by
        // collapsing a spoken number into one token.
        let plain = "please send the deck to priya before the standup tomorrow"
        #expect(PreviewFormatter.format(plain).split(separator: " ").count == plain.split(separator: " ").count)
    }

    /// The decorator applied in `RecognizerFactory.makePreview`: formatting on the preview path,
    /// nothing else changed.
    @Test func decoratorFormatsWhatTheRecognizerEmits() async throws {
        final class Fake: PreviewRecognizer, @unchecked Sendable {
            var texts = ["", "i think", "i think so"]
            var index = 0
            var resets = 0
            func feed(_ samples: [Float]) async throws -> String {
                defer { index += 1 }
                return texts[min(index, texts.count - 1)]
            }
            func reset() async { resets += 1; index = 0 }
        }
        let fake = Fake()
        let formatted = FormattedPreviewRecognizer(fake)
        #expect(try await formatted.feed([0]) == "")
        #expect(try await formatted.feed([0]) == "I think")
        #expect(try await formatted.feed([0]) == "I think so")
        await formatted.reset()
        #expect(fake.resets == 1)
    }

    @Test func backendResolvesFromTheFlag() {
        #expect(PreviewBackend.measuredDefault == .eouStreaming120m)
        #expect(FeatureFlag.previewBackend.defaultOn == false)
        #expect(PreviewBackend.resolve(flags: [:]) == .eouStreaming120m)
        #expect(PreviewBackend.resolve(flags: [FeatureFlag.previewBackend.id: false]) == .eouStreaming120m)
        #expect(PreviewBackend.resolve(flags: [FeatureFlag.previewBackend.id: true]) == .pollingFinal)
        #expect(PreviewBackend.resolve(FeatureFlagService.inMemory()) == .eouStreaming120m)
        #expect(PreviewBackend.resolve(FeatureFlagService.inMemory(["previewBackend": true])) == .pollingFinal)
        #expect(PreviewBackend.allCases.count == 2)
    }
}
