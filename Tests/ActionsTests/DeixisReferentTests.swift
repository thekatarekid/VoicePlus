import Foundation
import Testing
@testable import Actions

@Suite("P3.5 conversational referents")
struct ReferentResolverTests {
    let people = ContextParticipants([
        Participant(name: "Me", gender: .masculine, isSelf: true, salience: 1),
        Participant(name: "Jane Park", gender: .feminine, salience: 0.9),
        Participant(name: "Tom Reyes", gender: .masculine, salience: 0.5),
    ])
    let artifacts = [VisibleArtifact(title: "Q3 Plan.key", kind: .deck, salience: 0.8),
                     VisibleArtifact(title: "budget.xlsx", kind: .spreadsheet, salience: 0.7)]

    @Test func resolvesPronounAndArtifact() {
        let b = ReferentResolver().resolve("Tell her the deck is ready", participants: people, artifacts: artifacts)
        #expect(b.contextLines == ["her = Jane Park", "the deck = Q3 Plan.key"])
        #expect(b.map(\.phrase) == ["her", "the deck"])
    }

    @Test func selfIsNeverAPronounTargetAndUnknownKindsReported() {
        let b = ReferentResolver().resolve("ask him about the file", participants: people, artifacts: artifacts)
        #expect(b.contextLines == ["him = Tom Reyes", "the file = unknown"])
    }

    @Test func bareNounWithoutDeterminerIsIgnored() {
        let b = ReferentResolver().resolve("deck building is fun", participants: people, artifacts: artifacts)
        #expect(b.isEmpty)
    }

    @Test func closeSalienceIsAmbiguous() {
        let two = ContextParticipants([Participant(name: "Ana", gender: .feminine, salience: 0.6), Participant(name: "Bea", gender: .feminine, salience: 0.5)])
        let b = ReferentResolver().resolve("send it to her", participants: two, artifacts: [])
        #expect(b[0].isAmbiguous && b[0].resolved == nil && b[0].candidates.count == 2)
        #expect(b.contextLines == ["her = ? (Ana | Bea)"])
    }

    @Test func providerProtocolsFeedResolver() {
        let ctx = StaticReferentContext(people: people, artifacts: artifacts)
        let b = ReferentResolver().resolve("share the spreadsheet with them", people: ctx, artifacts: ctx)
        #expect(b.contextLines == ["the spreadsheet = budget.xlsx", "them = Jane Park"])
    }
}
