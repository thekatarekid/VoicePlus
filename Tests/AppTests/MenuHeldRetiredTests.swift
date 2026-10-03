import Foundation
import Testing
@testable import VoicePlusApp

/// H23-ui — the held queue is retired: the menu never says "held" or "Needs you"; its one row
/// appears only when a Notes save failed (words kept in Today with Copy).
@Suite("H23-ui — menu after the held queue")
struct MenuHeldRetiredTests {
    @Test func nothingHeldMeansNoRow() {
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.held, in: StatusMenuSpec.entries(StatusMenuState())) == nil)
    }

    @Test func aFailedNotesSaveUsesOutcomeVocabulary() {
        let one = StatusMenuState(status: .ready, held: [StatusMenuState.Held(id: UUID(), title: "“a” — Mail")])
        let row = StatusMenuSpec.entry(StatusMenuSpec.ID.held, in: StatusMenuSpec.entries(one))
        #expect(row?.title == TurnOutcome.notesSaveFailed(intendedApp: nil).pillLine)
        #expect(row?.detail == "Kept in Today with Copy.")
        #expect(row?.action == .reviewHeld)
        for n in 1...4 {
            let title = MenuCopy.held(count: n)
            #expect(!title.lowercased().contains("held") && !title.contains("Needs you"))
        }
    }
}
