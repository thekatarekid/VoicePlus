import Actions
import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S2 — what the pill hands the rest of the app: where every button goes, the latch timer never
/// cutting a segment's outcome row short, inline editing, the destination name, and the key hints.
@Suite("S2 — pill wiring")
struct PillWiringTests {
    static let t0 = Date(timeIntervalSince1970: 90_000)
    static let preview = PillState.finalPreview(FinalPreviewInfo(text: "Can we meet?", dwellRemaining: 0.9))

    // MARK: - Buttons → owners

    /// Every button label the copy fixture draws maps to a real effect (the prototype's `pillAction`),
    /// except the ones `PillViewModel.perform` handles itself (held actions, Dismiss).
    @Test func everyActionHasAnOwner() {
        let finishing = PillState.finishing(elapsedWarning: true)
        let table: [(PillActionKind, PillState, PillActionEffect)] = [
            (.commit, Self.preview, .insertNow),
            (.cancel, Self.preview, .cancelPreview),
            (.cancel, finishing, .cancelFinishing),
            (.useAvailable, finishing, .useAvailableText),
            (.finish, .latched(elapsed: 4), .finishLatch),
            (.undo, .undoAvailable, .undo),
            (.unmute, .muted, .unmute),
            (.copy, .error(message: "x"), .copy("these words")),
            (.check, .landed(LandedPillInfo(text: "x", verified: false)), .open(.today)),
            (.check, .landedPartial(text: "x"), .open(.today)),
            (.review, .error(message: "x"), .open(.today)),
            (.review, .correcting, .open(.today)),
            (.voice, .warning(.unknownGood), .open(.voice)),
            (.models, .unavailable(reason: "x"), .open(.models)),
            (.permissions, .error(message: "x"), .open(.privacy)),
            (.meeting, .meeting(MeetingPillInfo(phase: .recording, elapsed: 1)), .open(.meetings)),
            (.stop, .meeting(MeetingPillInfo(phase: .recording, elapsed: 1)), .stopMeeting),
            (.dismiss, .error(message: "x"), .none),
        ]
        for (action, shown, effect) in table {
            #expect(PillActionRoute.effect(for: action, shown: shown, text: "these words") == effect,
                    "\(action.rawValue) on \(shown.caseName)")
        }
        // Copy with nothing to copy does nothing (never an empty clipboard write).
        #expect(PillActionRoute.effect(for: .copy, shown: .error(message: "x"), text: "") == .none)
        // The turn's own buttons belong to `TurnWiring`; the composition root carries out the rest,
        // so no button is handled twice.
        for (action, shown, _) in table {
            let effect = PillActionRoute.effect(for: action, shown: shown, text: "t")
            let turnOwned: Set<PillActionKind> = [.commit, .cancel, .useAvailable, .finish, .undo]
            #expect(effect.isTurnEffect == turnOwned.contains(action), "\(action.rawValue)")
        }
    }

    /// Every button the fixture-backed deck draws reaches an effect or the view model's own handling.
    @Test func everyDrawnButtonIsHandled() {
        let c = PillTurnContext(destination: "Mail", liveText: "words", captureOpen: false)
        let states: [PillState] = [
            .latched(elapsed: 1), .warning(.unknownGood), .muted, .unavailable(reason: "x"), .undoAvailable, .correcting,
            .finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0, manual: true)),
            .landed(LandedPillInfo(text: "x", verified: false)), .landedPartial(text: "x"),
            .held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed")),
            .error(message: "Text was not typed — Try again"), .error(message: DeliveryCopy.microphoneDisconnected),
            .meeting(MeetingPillInfo(phase: .recording, elapsed: 1)), .meeting(MeetingPillInfo(phase: .paused, elapsed: 1)),
            .meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 1)),
        ]
        for state in states {
            for button in PillContent.make(state, context: c).buttons {
                let effect = PillActionRoute.effect(for: button.action, shown: state, text: "words")
                let handledByModel = [.dismiss, .editDraft, .doneEditing, .cancelEditing].contains(button.action) || (state.caseName == "held" && button.action.heldAction != nil)
                #expect(effect != .none || handledByModel, "\(button.label) on \(state.caseName)")
            }
        }
    }

    // MARK: - Latch: the timer never cuts an outcome row short

    @Test func aLatchTickKeepsTheInsertedRowForItsDwell() {
        let model = PillViewModel()
        var clock = Self.t0
        model.now = { clock }
        model.latched = true
        model.present(.latched(elapsed: 3))
        model.apply(.listening(level: 0.3))
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Segment one.", destination: "Notes")
        #expect(model.state.caseName == "landed")
        // The runtime's 1 s tick and the engine's level ticks arrive during the 650 ms dwell.
        clock = clock.addingTimeInterval(0.3)
        model.present(.latched(elapsed: 4))
        model.apply(.listening(level: 0.2))
        #expect(model.state.caseName == "landed", "a tick replaced ✓ Inserted before its 650 ms")
        #expect(model.turn.latchElapsed == 4)
        // The dwell ends: back to the latched row with the newest elapsed time.
        clock = clock.addingTimeInterval(0.4)
        model.retractDelivery()
        #expect(model.state == .latched(elapsed: 4))
    }

    /// A sticky row in latch (held) stays through ticks, and the next segment's words take the pill
    /// back: capture outranks held recovery (design §6 state priority).
    @Test func theNextSegmentsWordsReplaceAHeldRowInLatch() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.latched = true
        model.present(.latched(elapsed: 10))
        model.apply(.listening(level: 0.3))
        model.present(delivery: .held(reason: "destination changed"), text: "Segment one.", destination: "Mail")
        #expect(model.state.caseName == "held")
        model.present(.latched(elapsed: 11))
        model.apply(.listening(level: 0.4))
        #expect(model.state.caseName == "held")
        model.apply(.previewing(text: "segment two"))
        #expect(model.state == .latched(elapsed: 11))
        #expect(model.content().words == .live("segment two"))
    }

    /// Words of the next segment that arrive during a landed row's dwell survive its retraction.
    @Test func theNextSegmentsWordsSurviveTheRetraction() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.latched = true
        model.present(.latched(elapsed: 2))
        model.apply(.listening(level: 0.3))
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Segment one.", destination: "Notes")
        model.apply(.previewing(text: "and then"))
        model.retractDelivery()
        #expect(model.state == .latched(elapsed: 2))
        #expect(model.content().words == .live("and then"))
    }

    // MARK: - Mouse policy

    /// V3 transcripts accept scrolling/selecting while their fixed startup hints remain click-through.
    /// Keyboard nonactivation during capture is separately covered by the native viewport tests.
    @Test func thePillTakesThePointerOnlyWhereItMatters() {
        let c = PillTurnContext(destination: "Mail", liveText: "w", captureOpen: true)
        func accepts(_ s: PillState) -> Bool { PillPanelController.acceptsMouse(s, content: PillContent.make(s, context: c)) }
        #expect(accepts(.listening(level: 0.3)))
        #expect(accepts(.starting)) // prior/live words are still readable
        #expect(accepts(.inserting(text: "w")))
        #expect(accepts(.landed(LandedPillInfo(text: "w", verified: true))))
        let emptyStart = PillContent.make(.starting, context: PillTurnContext())
        #expect(!PillPanelController.acceptsMouse(.starting, content: emptyStart))
        #expect(!PillPanelController.acceptsMouse(.hidden, content: .hidden))
        #expect(accepts(Self.preview))                                     // hover pauses the dwell
        #expect(accepts(.landed(LandedPillInfo(text: "w", verified: false))))
        #expect(accepts(.held(HeldPillInfo(text: "w", destination: "Mail", reason: "destination changed"))))
        #expect(accepts(.latched(elapsed: 3)))                             // Finish
        #expect(accepts(.transform(TransformPillInfo(editingWords: 3, stage: .notice("Shorter: 3 → 2 words")))))
        #expect(!accepts(.transform(TransformPillInfo(editingWords: 3, stage: .editing))))
    }

    // MARK: - Mute (I2)

    /// Mute outranks everything (design §6); only the explicit Unmute takes it down.
    @Test func mutedStaysUntilUnmute() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.present(.muted)
        model.present(.cancelled)                       // the mute's own cancellation of a live turn
        model.apply(.idle)
        model.present(.preview(text: "Dictation stopped"))
        model.hide()
        #expect(model.state == .muted)
        #expect(model.content().buttons == [PillButton("Unmute", .unmute, primary: true)])
        model.dismissNotice()                           // AppDelegate: the mute was released
        #expect(model.state == .hidden)
        model.apply(.starting)
        #expect(model.state == .starting)
    }

    // MARK: - Inline draft editing

    @Test func editDraftTurnsThePreviewIntoInlineEditingMode() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        var seen: [PillActionKind] = []
        model.onAction = { action, _ in seen.append(action) }
        model.apply(.starting)
        // N22 — only a preview that waits (Manual review) carries Edit draft; an automatic one is
        // the Inserting face with no buttons.
        model.present(.finalPreview(FinalPreviewInfo(text: "Can we meet?", dwellRemaining: 0.9, manual: true)))
        #expect(model.content().buttons.map(\.action) == [.commit, .editDraft, .cancel])
        #expect(model.content().helper == "Manual review · insert when ready")
        model.perform(.editDraft)
        #expect(seen.isEmpty && model.isEditingDraft)
        let review = model.content()
        #expect(review.buttons.map(\.action) == [.doneEditing, .cancelEditing])
        #expect(review.helper == "Editing · leave the pill to apply")  // V5 Q12
        #expect(review.surface { _ in 0 } == .actionable)
        // The next turn starts out of review mode.
        model.apply(.starting)
        #expect(!model.isEditingDraft)
    }

    // MARK: - Destination and key hints

    @Test func theDestinationIsTheFrontmostAppsNameNeverOurselvesOrABundleID() {
        #expect(PillDestination.name(localizedName: "Mail", bundleID: "com.apple.mail", ownBundleID: "in.voiceplus") == "Mail")
        #expect(PillDestination.name(localizedName: "VoicePlus", bundleID: "in.voiceplus", ownBundleID: "in.voiceplus") == nil)
        #expect(PillDestination.name(localizedName: nil, bundleID: "com.example.x", ownBundleID: nil) == nil)
        #expect(PillDestination.name(localizedName: "  ", bundleID: nil, ownBundleID: nil) == nil)
    }

    @Test func presenceRowsNameTheConfiguredKeyByItsHintLabel() {
        #expect(PresenceHover.keyHint(for: .default) == "hold fn / 🌐")
        #expect(PresenceHover.keyHint(for: HotkeyBinding(kind: .rightOption)) == "hold \(HotkeyBinding(kind: .rightOption).label)")
        #expect(!PresenceHover.keyHint(for: .default).contains("Right"))
    }

    /// Boxes drawn before the key went down (latch "draw without a key") stay counted in the new turn.
    @Test func chipsDrawnBeforeKeyDownBelongToTheTurn() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        let region = DeixisRegion(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1, text: "Q3")
        model.showDeixis([region]) { _ in nil }
        model.apply(.starting)
        #expect(model.turn.chipCount == 1)
        #expect(model.deixisChips.map(\.label) == ["Q3"])
    }
}
