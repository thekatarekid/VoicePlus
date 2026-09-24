import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S2 verify — the auto-insert preview helpers (the fixture's second helper sentence for `preview` and
/// `uncertain`) are drawn verbatim from `design_copy.json`, not only the manual ones.
@Suite("S2 — design copy parity (auto preview)")
struct DesignCopyAutoPreviewTests {
    @Test func autoPreviewHelpersAreTheFixturesSentences() throws {
        let fixture = try DesignCopyParityTests.fixture()
        var c = DesignCopyParityTests.prototypeContext()
        c.captureOpen = false
        let sample = DesignCopyParityTests.sample

        let auto = FinalPreviewInfo(text: sample, dwellRemaining: 0.6, manual: false, destination: "Mail")
        let preview = PillContent.make(.finalPreview(auto), context: c)
        let previewEntry = try #require(fixture["preview"])
        #expect(preview.designKey == "preview")
        #expect(preview.status == previewEntry.status)
        #expect(preview.helper == "Final preview · hover to pause")
        #expect(previewEntry.strings.contains(preview.helper))
        #expect(preview.words.text == sample)

        let autoReview = FinalPreviewInfo(text: sample, uncertainCount: 1, dwellRemaining: 0.6, manual: false,
                                          destination: "Mail")
        let review = PillContent.make(.finalPreview(autoReview), context: c)
        let reviewEntry = try #require(fixture["uncertain"])
        #expect(review.designKey == "uncertain")
        #expect(review.helper == "Final preview · hover to pause")
        #expect(reviewEntry.strings.contains(review.helper))
        #expect(review.words.text == sample)
    }
}
