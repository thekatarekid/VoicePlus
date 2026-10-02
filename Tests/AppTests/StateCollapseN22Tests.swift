import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// N22 — the pill and the notch collapse to five turn-facing states each (investigation §4).
@Suite("N22 — five-state pill and notch")
struct StateCollapseN22Tests {
    static let words = "can we meet with Mira on Friday"

    // MARK: Pill — the state-mapping table

    @Test func everyTurnStateMapsOntoOneOfFiveFaces() {
        let table: [(PillState, PillTurnFace?)] = [
            (.idle, .listening), (.starting, .listening), (.listening(level: 0.3), .listening),
            (.preview(text: "hi"), .listening), (.listeningQuiet, .listening), (.latched(elapsed: 2), .listening),
            (.warning(MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor)), .listening),
            (.landing, .inserting), (.finishing(elapsedWarning: false), .inserting),
            (.finishing(elapsedWarning: true), .inserting),
            (.finalPreview(FinalPreviewInfo(text: Self.words, dwellRemaining: 0)), .inserting),
            (.inserting(text: Self.words), .inserting),
            (.finalPreview(FinalPreviewInfo(text: Self.words, dwellRemaining: 0, manual: true)), .needsYou),
            (.finalPreview(FinalPreviewInfo(text: Self.words, dwellRemaining: 0.4, paused: true)), .needsYou),
            (.landed(LandedPillInfo(text: Self.words, verified: true)), .done),
            (.landed(LandedPillInfo(text: Self.words, verified: false)), .done),
            (.landed(LandedPillInfo(text: Self.words, verdict: .unreadable)), .done),
            (.landedPartial(text: Self.words), .done), (.undoAvailable, .done),
            (.held(HeldPillInfo(text: Self.words, destination: "Mail", reason: "destination changed")), .needsYou),
            (.cancelled, .nothing), (.error(message: "x"), .nothing),
            (.hidden, nil), (.ready(hint: "Hold fn"), nil), (.muted, nil), (.unavailable(reason: "x"), nil),
            (.correcting, nil), (.editing, nil),
        ]
        for (state, face) in table {
            #expect(state.turnFace() == face, "\(state.caseName)")
        }
        #expect(PillState.error(message: "x").turnFace(recoveredWords: true) == .needsYou)
        var c = PillTurnContext(destination: "Mail")
        c.liveText = Self.words
        #expect(PillContent.face(.error(message: "x"), context: c) == .needsYou)
        #expect(Set(table.compactMap(\.1)) == Set(PillTurnFace.allCases))
    }

    /// Inserting is one row: "Inserting in <App>…" with the words, whether the final pass is
    /// running (slow or not), the automatic preview is up, or the write is in flight.
    @Test func theInsertingFaceIsOneRow() {
        var c = PillTurnContext(destination: "Mail")
        c.captureOpen = false
        c.liveText = Self.words
        c.finishingSince = Date(timeIntervalSince1970: 0)
        c.now = Date(timeIntervalSince1970: 30)   // long past the old 2 s / 10 s thresholds
        let states: [PillState] = [.landing, .finishing(elapsedWarning: false), .finishing(elapsedWarning: true),
                                   .finalPreview(FinalPreviewInfo(text: Self.words, dwellRemaining: 0.6, destination: "Mail")),
                                   .inserting(text: Self.words)]
        for state in states {
            let row = PillContent.make(state, context: c)
            #expect(row.designKey == "inserting", "\(state.caseName)")
            #expect(row.status == "Inserting in Mail…", "\(state.caseName)")
            #expect(row.words.text == Self.words)
            #expect(row.buttons.isEmpty, "no countdown, no 10 s offer, no Edit draft")
            #expect(!row.status.contains("Still finishing") && !row.helper.contains("nothing inserted yet"))
        }
        // The only button it ever carries: the one Cancel the controller raised (N2 keeps the words).
        c.offer = .useAvailableText
        #expect(PillContent.make(.finishing(elapsedWarning: true), context: c).buttons
                == [PillButton("Cancel", .cancel, primary: true)])
    }

    /// Done clears on its own, ⚠ rows included; an action on one still takes it down at once.
    @Test func everyDoneRowClearsOnItsOwn() {
        let done: [PillState] = [.landed(LandedPillInfo(text: "x", verified: true)),
                                 .landed(LandedPillInfo(text: "x", verdict: .unreadable)),
                                 .landed(LandedPillInfo(text: "x", verified: false)),
                                 .landedPartial(text: "x"), .undoAvailable]
        for state in done {
            #expect(state.turnFace() == .done)
            #expect(!PillDwell.staysUntilAction(state), "\(state.caseName)")
            #expect(PillDwell.minimum(for: state).isFinite)
            #expect(PillRetention.applies(to: state), "\(state.caseName) is owned by the K19 backstop")
        }
        let model = PillViewModel()
        model.apply(.starting)
        model.present(.landed(LandedPillInfo(text: "x", verified: false)))
        model.perform(.check)
        #expect(model.state == .hidden)
    }

    /// Needs you is the only face that stays until the user acts.
    @Test func onlyNeedsYouWaitsForTheUser() {
        let held = PillState.held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed"))
        #expect(held.turnFace() == .needsYou && PillDwell.staysUntilAction(held))
        let row = PillContent.make(held, context: PillTurnContext(destination: "Mail"))
        #expect(row.buttons.map(\.action) == [.insert, .copy, .discard])
        for state in [PillState.cancelled, .finishing(elapsedWarning: true), .inserting(text: "x")] {
            #expect(!PillDwell.staysUntilAction(state), "\(state.caseName)")
        }
    }

    // MARK: Notch — five visible faces

    @Test func theNotchHasFiveVisibleFaces() {
        let table: [(PresenceState, Int, PresenceFace)] = [
            (.off, 0, .off), (.off, 2, .off),
            (.ready, 0, .ready), (.paused, 0, .ready),
            (.listening(level: 0.4), 0, .listening), (.listening(level: 0.4), 1, .listening),
            (.processing, 0, .working), (.processing, 1, .working),
            (.ready, 1, .needsYou), (.paused, 3, .needsYou),
            (.muted, 0, .blocked), (.muted, 1, .blocked),
            (.blocked(.microphoneDenied), 0, .blocked), (.blocked(.modelMissing), 1, .blocked),
        ]
        for (state, held, face) in table {
            #expect(PresenceFace.of(state, heldWaiting: held) == face, "\(state.caseName) held=\(held)")
        }
        let visible = Set(table.map(\.2)).subtracting([.off])
        #expect(visible == [.ready, .listening, .working, .needsYou, .blocked])
    }

    @Test func needsYouDrawsAsABadgeAndItsRow() {
        let view = PresenceIndicatorView(state: .ready, hovered: false, cornerRadius: 8, hint: "hold fn",
                                         heldWaiting: 2)
        #expect(view.needsYou)
        #expect(view.contentKind == .badge)
        #expect(!view.contentKind.showsDot)
        let hovered = PresenceIndicatorView(state: .ready, hovered: true, cornerRadius: 8, hint: "hold fn",
                                            heldWaiting: 2)
        #expect(hovered.contentKind == .row)
        #expect(hovered.rowText == PresenceFace.needsYouDetail(2))
        // Held text never hides an open microphone or a blocker.
        let listening = PresenceIndicatorView(state: .listening(level: 0.3), hovered: false, cornerRadius: 8,
                                              hint: "hold fn", heldWaiting: 2)
        #expect(!listening.needsYou)
        #expect(PresenceIndicatorView(state: .ready, hovered: false, cornerRadius: 8, hint: "").contentKind == .dot)
    }

    /// The held queue drives the notch through one notification (no extra wiring).
    @MainActor @Test func theHeldQueuePostsItsCount() async {
        var counts: [Int] = []
        let token = NotificationCenter.default.addObserver(forName: .voicePlusHeldWaitingChanged, object: nil,
                                                           queue: nil) { note in
            if let n = note.userInfo?["count"] as? Int { counts.append(n) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let driver = DeliveryPillDriver(pill: PillViewModel())
        driver.handle(.held(reason: "destination changed"), text: "x", destination: "Mail")
        #expect(counts.last == 1)
        driver.held.discardAll()
        #expect(counts.last == 0)
    }
}
