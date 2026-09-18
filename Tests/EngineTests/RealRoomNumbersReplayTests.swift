import Foundation
import Testing
import Shared
@testable import Engine

/// E1/E2 (V4.11, V4.12) · the real-room corpus lines that say a number — above all line 05, "The
/// invoice total is 2,340 rupees, not 2,430." — replayed through the real final model, the way
/// `RecordingReplayTests.scoreRealRoomCorpus` does.
///
/// Prints the spans the model produced (text, confidence, `audioRange`) as Swift literals: that is
/// the snapshot in `Tests/PipelineTests/RealRoomNumberSnapshots.swift`, which
/// `NumbersTimingTests` formats through `ProseListFormatter` (the pipeline is not importable here).
/// Regenerate it with
///
///     eval "$(Scripts/bootstrap-toolchain.sh)"
///     swift test --scratch-path .build-e --filter realRoomNumberLineSpans
///
/// Skips when the git-ignored WAVs or the model weights are not on this machine.
@Suite("Real-room number lines (real model)", .serialized)
struct RealRoomNumbersReplayTests {

    static func literal(_ s: TranscriptSpan) -> String {
        String(format: "(%@, %.3f, %.3f, %.3f),", "\"\(s.text)\"", Double(s.confidence),
               s.audioRange.lowerBound, s.audioRange.upperBound)
    }

    /// Script lines that say a number, including the small counts ("at four", "for six", "two of
    /// the large ones") the digit-sequence rule must leave alone.
    static let numberLines = [2, 3, 4, 5, 8, 11, 18]

    @Test(.timeLimit(.minutes(10)))
    func realRoomNumberLineSpans() async throws {
        guard let items = RealRoomCorpus.items(pass: "builtin"), items.count >= 5 else {
            print("SKIPPED: real-room/builtin WAVs not in the checkout."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        #expect(items[4].index == 5)
        #expect(items[4].reference == "The invoice total is 2,340 rupees, not 2,430.")
        for item in items where Self.numberLines.contains(item.index) {
            for (label, url) in [("raw", item.raw), ("processed", item.processed)] {
                guard let url else { continue }
                let spans = try await final.recognize(try SampleAudioSource.load16k(url: url))
                print("\n─── line \(String(format: "%02d", item.index)) \(label): \(item.stamp) ───")
                print("  said:  \(item.reference)")
                print("  heard: \(spans.renderedText)")
                spans.forEach { print("  " + Self.literal($0)) }
                #expect(!spans.isEmpty)
                // Whatever the model heard, the preview formatter must not invent punctuation on it.
                let lower = spans.map(\.text).joined(separator: " ").lowercased()
                #expect(PreviewFormatter.addsNoPunctuation(input: lower, output: PreviewFormatter.format(lower)))
            }
        }
    }
}
