import Foundation
import Testing
import Shared
@testable import Lab

/// V2 — the committed baselines file parses and carries a source for every entry.
@Suite struct BaselinesFileTests {
    @Test func committedBaselinesParse() throws {
        let url = try #require(AppPaths.fixturesDirectory()).deletingLastPathComponent().appendingPathComponent("Lab/results/baselines.json")
        let b = try Baselines.load(from: url)
        #expect(b.gateDelta == 0.3)
        #expect(b.entries.allSatisfy { $0.source.hasPrefix("https://") })
        #expect(b.entry(model: "parakeet-tdt-v3", set: "librispeech-test-clean", metric: "wer", normalizer: .normalized)?.value == 1.93)
    }
}
