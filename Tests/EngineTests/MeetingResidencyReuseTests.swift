import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M12/M7/M9 verify — one `ModelResidency` key per meeting model, but a new backend instance per
/// meeting. The second meeting's backend must see the weights the first one made resident (the key
/// stays `.resident`, so its loader is not called again).
@Suite("V5 M12 verify — meeting backends across meetings")
struct MeetingResidencyReuseTests {
    @Test("a second meeting's WeSpeaker backend embeds while the first one's load is still resident",
          .enabled(if: SpeakerEmbedderFactory.locateModel() != nil, "WeSpeaker weights not on disk"))
    func secondMeetingEmbeds() async throws {
        let dir = try #require(SpeakerEmbedderFactory.locateModel())
        let residency = ModelResidency(budgetBytes: 1 << 31)
        let audio = (0..<32_000).map { i in Float(sin(Double(i) * 0.05) * 0.3) }

        let first = ResidentSpeakerEmbedding(directory: dir, residency: residency)
        try await first.prepare()
        #expect(!(try first.embedding(for: audio)).isEmpty)

        let second = ResidentSpeakerEmbedding(directory: dir, residency: residency)
        try await second.prepare()
        #expect(!(try second.embedding(for: audio)).isEmpty, "the resident weights reach the next meeting's backend")

        await residency.unload(ResidentSpeakerEmbedding.residencyKey)
        #expect(throws: (any Error).self) { try second.embedding(for: audio) }
        try await second.prepare()
        #expect(!(try second.embedding(for: audio)).isEmpty, "reloaded after an unload")
    }
}
