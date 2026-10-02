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

        // N22 + owner decision 2 (no dwell): an automatic preview is the Inserting face — the
        // design's inserting row with the final words, no countdown and no buttons.
        let auto = FinalPreviewInfo(text: sample, dwellRemaining: 0.6, manual: false, destination: "Mail")
        let preview = PillContent.make(.finalPreview(auto), context: c)
        let inserting = try #require(fixture["inserting"])
        #expect(preview.designKey == "inserting")
        #expect(preview.status == inserting.status)
        #expect(inserting.strings.contains(preview.helper))
        #expect(preview.buttons.isEmpty)
        #expect(preview.words.text == sample)

        let autoReview = FinalPreviewInfo(text: sample, uncertainCount: 1, dwellRemaining: 0.6, manual: false,
                                          destination: "Mail")
        let review = PillContent.make(.finalPreview(autoReview), context: c)
        #expect(review.designKey == "inserting")
        #expect(review.words.text == sample)

        // A preview the user froze waits for them: the design's preview row with its pause helper.
        let paused = FinalPreviewInfo(text: sample, dwellRemaining: 0.6, paused: true, destination: "Mail")
        let held = PillContent.make(.finalPreview(paused), context: c)
        let previewEntry = try #require(fixture["preview"])
        #expect(held.designKey == "preview")
        #expect(held.status == previewEntry.status)
        #expect(previewEntry.strings.contains(held.helper))
    }
}
