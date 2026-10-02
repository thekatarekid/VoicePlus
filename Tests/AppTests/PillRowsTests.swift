import Actions
import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S2 — PillTests: state → rows / copy, the turn context behind them (timer, destination, live words,
/// latch timer), dwell, the actions, the text lane and the deixis chip.
@Suite("S2 — pill rows (state → rows / copy)")
struct PillRowsTests {
    static let t0 = Date(timeIntervalSince1970: 70_000)

    static func context(_ live: String = "", open: Bool = true, destination: String? = "Mail",
                        at seconds: TimeInterval = 6) -> PillTurnContext {
        PillTurnContext(keyLabel: "fn / 🌐", destination: destination, startedAt: t0,
                        now: t0.addingTimeInterval(seconds), liveText: live, captureOpen: open)
    }

    static let everyState: [PillState] = [
        .idle, .starting, .listening(level: 0.4), .preview(text: "um can we"), .listeningQuiet, .latched(elapsed: 6),
        .warning(MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor)), .landing,
        .finishing(elapsedWarning: false), .finalPreview(FinalPreviewInfo(text: "Can we?", dwellRemaining: 0.9)),
        .inserting(text: "Can we?"), .landed(LandedPillInfo(text: "Can we?", verified: true)),
        .landed(LandedPillInfo(text: "Can we?", verified: false)), .landedPartial(text: "Can we?"),
        .held(HeldPillInfo(text: "Can we?", destination: "Mail", reason: "destination changed")),
        .unavailable(reason: "x"), .error(message: "boom"), .transform(TransformPillInfo(editingWords: 2, stage: .editing)),
        .muted, .cancelled, .correcting, .editing, .undoAvailable, .meeting(MeetingPillInfo(phase: .recording, elapsed: 5)),
    ]

    // MARK: - Rows

    @Test func everyVisibleStateDrawsAStatusRowAndAValidSpool() {
        for state in Self.everyState {
            let content = PillContent.make(state, context: Self.context("words so far"))
            #expect(!content.status.isEmpty, "\(state.caseName)")
            #expect(content.showsSpool, "\(state.caseName)")
            #expect(SpoolStateKey(rawValue: content.spoolKey) != nil, "\(state.caseName) → \(content.spoolKey)")
            #expect(!content.accessibilityLabel.isEmpty)
        }
    }

    /// The status row: the real timer while capture is open, the destination afterwards.
    @Test func theStatusRowCarriesTheTimerOrTheDestination() {
        let c = Self.context("Can we meet", at: 6)
        for state: PillState in [.listening(level: 0.2), .listeningQuiet,
                                 .warning(MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor))] {
            #expect(PillContent.make(state, context: c).trailing.text == "0:06", "\(state.caseName)")
        }
        #expect(PillContent.make(.latched(elapsed: 75), context: c).trailing.text == "1:15")
        var closed = c
        closed.captureOpen = false
        #expect(PillContent.make(.finishing(elapsedWarning: false), context: closed).trailing == .destination("Mail"))
        #expect(PillContent.make(.inserting(text: "x"), context: closed).trailing == .destination("Mail"))
        closed.destination = nil
        #expect(PillContent.make(.inserting(text: "x"), context: closed).trailing == .none)
        #expect(PillContent.make(.inserting(text: "x"), context: closed).status == "Inserting…")
    }

    /// C5: the warning annotates the live words, it never replaces them; Spool keeps listening with
    /// the concerned-brow overlay.
    @Test func theWarningKeepsTheLiveWords() {
        let content = PillContent.make(.warning(MicQuality(snr: 4, clipping: 0, lowLevel: true, verdict: .bad)),
                                       context: Self.context("Can we meet with Mira"))
        #expect(content.words == .live("Can we meet with Mira"))
        #expect(content.status == "⚠ Microphone sounds unclear")
        #expect(content.tone == .warn)
        #expect(content.spoolKey == "warning")
        #expect(SpoolPoseTable.isLive(.warning))
        #expect(SpoolPoseTable.overlays(for: .warning) == [.concernedBrows])
        #expect(content.buttons.map(\.label) == ["Check microphone"])
    }

    /// Design §5: "Listening" only while capture is actually open. A `.preview` line presented with no
    /// capture open is a notice, never transcript under "Listening".
    @Test func aPreviewOutsideCaptureIsANoticeNotListening() {
        let notice = PillContent.make(.preview(text: "Voice learned"), context: Self.context(open: false))
        #expect(notice.status == "Voice learned")
        #expect(notice.words == .none)
        #expect(notice.designKey == "notice")
        let live = PillContent.make(.preview(text: "um can we"), context: Self.context())
        #expect(live.status == "Listening")
        #expect(live.words == .live("um can we"))
        #expect(live.escapeHint)
    }

    /// Design §5: after 2 s "Still finishing your text"; after 10 s "Use available text" when valid
    /// partial text exists, otherwise "Cancel".
    @Test func finishingTimeouts() {
        var c = Self.context("half a sentence", open: false)
        c.finishingSince = Self.t0
        c.now = Self.t0.addingTimeInterval(1)
        #expect(PillContent.make(.finishing(elapsedWarning: false), context: c).status == "Finishing…")
        c.now = Self.t0.addingTimeInterval(2.1)
        #expect(PillContent.make(.finishing(elapsedWarning: false), context: c).status == "Still finishing your text")
        #expect(PillContent.make(.finishing(elapsedWarning: true), context: c).buttons.isEmpty)
        c.now = Self.t0.addingTimeInterval(10)
        #expect(PillContent.make(.finishing(elapsedWarning: true), context: c).buttons.isEmpty,
                "N2: the pill's own clock never puts up buttons; only the turn's offer does")
        c.offer = .useAvailableText
        let offer = PillContent.make(.finishing(elapsedWarning: true), context: c)
        #expect(offer.buttons == [PillButton("Use available text", .useAvailable, primary: true), PillButton("Cancel", .cancel)])
        c.liveText = ""
        #expect(PillContent.make(.finishing(elapsedWarning: true), context: c).buttons == [PillButton("Cancel", .cancel, primary: true)])
        c.offer = .cancel
        #expect(PillContent.make(.finishing(elapsedWarning: true), context: c).buttons == [PillButton("Cancel", .cancel, primary: true)])
    }

    /// Any hold keeps its three actions; a destination change is the design's H0 row verbatim, any
    /// other reason speaks with its catalogue entry — never the raw reason.
    @Test func heldRows() {
        let changed = PillContent.make(.held(HeldPillInfo(text: "t", destination: "Mail", reason: "destination changed")),
                                       context: Self.context(open: false))
        #expect(changed.status == "⚠ Destination changed · text held")
        let never = PillContent.make(.held(HeldPillInfo(text: "t", destination: "Brave", reason: "never-inject")),
                                     context: Self.context(open: false))
        #expect(never.status == "⚠ Dictation is off in this app")
        #expect(never.helper == "Your app rule prevents insertion.")
        #expect(never.trailing == .destination("Brave"))
        for row in [changed, never] {
            #expect(row.buttons.map(\.label) == ["Insert here", "Copy text", "Discard…"])
            #expect(row.buttons.compactMap(\.action.heldAction) == HeldAction.allCases)
            #expect(row.notice)
        }
    }

    /// Errors: T01 with recovered words → E0; a quiet no-result return fades with no actions; anything
    /// else states its catalogue problem and consequence and can always be dismissed (S11).
    @Test func errorRows() {
        let recovered = PillContent.make(.error(message: RecoveryCatalog.entry(.T01).headline),
                                         context: Self.context("these words", open: false))
        #expect(recovered.status == "⚠ Couldn’t finish this dictation")
        #expect(recovered.words == .final("these words"))
        let quiet = PillContent.make(.error(message: DeliveryCopy.noSpeechDetected), context: Self.context("x", open: false))
        #expect(quiet.status == "No speech detected")
        #expect(quiet.helper == "Nothing was typed.")
        #expect(quiet.buttons.isEmpty && !quiet.notice)
        let mic = PillContent.make(.error(message: DeliveryCopy.microphoneDisconnected), context: Self.context(open: false))
        #expect(mic.status == "⚠ Microphone disconnected")
        #expect(mic.buttons == [PillButton("Choose microphone", .voice, primary: true), PillButton("Dismiss", .dismiss)])
        // S11: text the catalogue does not know is never drawn — it is the catch-all X08.
        let unknown = PillContent.make(.error(message: "Nothing to put back"), context: Self.context(open: false))
        #expect(unknown.status == "⚠ VoicePlus couldn’t finish this step")
        #expect(unknown.buttons == [PillButton("Dismiss", .dismiss, primary: true)])
    }

    @Test func theTransformUndoIsTheDesignsUndoRow() {
        let done = PillContent.make(.transform(TransformPillInfo(editingWords: 3, stage: .done(changed: 2))),
                                    context: Self.context("Can we meet on Friday?", open: false))
        #expect(done.designKey == "undo")
        #expect(done.status == "✓ Updated in Mail")
        #expect(done.buttons == [PillButton("Undo", .undo, primary: true)])
    }

    // MARK: - Dwell (design §5, §10)

    @Test func theDwellTable() {
        #expect(PillDwell.minimum(for: .landed(LandedPillInfo(text: "x", verified: true))) == 0.65)
        #expect(PillDwell.minimum(for: .cancelled) == 0.8)
        let quiet = PillDwell.minimum(for: .error(message: DeliveryCopy.noSpeechDetected))
        #expect(RecoveryCatalog.fadeWindow.contains(quiet))
        let sticky: [PillState] = [
            .held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed")),
            .landed(LandedPillInfo(text: "x", verified: false)), .landedPartial(text: "x"),
            .error(message: "Text was not typed — Try again"), .unavailable(reason: "x"), .muted,
        ]
        for state in sticky {
            #expect(PillDwell.staysUntilAction(state), "\(state.caseName)")
            #expect(PillDwell.minimum(for: state) == .infinity)
        }
        for key in ["held", "unconfirmed", "partial", "error", "unavailable", "blocked"] {
            #expect(PillDwell.rule(forDesignKey: key) == .untilAction, "\(key)")
        }
        #expect(PillDwell.rule(forDesignKey: "inserted") == .minimum(0.65))
        #expect(PillDwell.rule(forDesignKey: "cancelled") == .minimum(0.8))
        // Final preview: S3 owns its dwell; the pill never holds it back.
        #expect(PillDwell.minimum(for: .finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0.9))) == 0)
    }

    /// No timed dismissal for a sticky notice: an hour later it is still there; the user's action
    /// takes it down at once; a new turn replaces it immediately.
    @Test func aStickyNoticeStaysUntilTheUserActs() {
        var p = PillPresenter()
        let error = PillState.error(message: "Text was not typed — Try again")
        #expect(p.request(error, now: Self.t0) == .show(error))
        #expect(p.request(.hidden, now: Self.t0) == .hold(until: .distantFuture))
        #expect(p.flush(now: Self.t0.addingTimeInterval(3_600)) == .hold(until: .distantFuture))
        #expect(p.displayed == error)
        #expect(p.dismiss(now: Self.t0.addingTimeInterval(3_601)) == .show(.hidden))
        var q = PillPresenter()
        _ = q.request(error, now: Self.t0)
        #expect(q.request(.starting, now: Self.t0.addingTimeInterval(1)) == .show(.starting))
    }

    // MARK: - View model: the turn behind the rows

    @Test func theViewModelTracksTheTurn() {
        let model = PillViewModel()
        var clock = Self.t0
        model.now = { clock }
        var asked = 0
        model.destinationProvider = { asked += 1; return "Notes" }
        model.keyLabel = { "fn / 🌐" }
        model.apply(.starting)
        model.apply(.listening(level: 0.3))
        model.apply(.previewing(text: "can we meet"))
        clock = clock.addingTimeInterval(4)
        #expect(asked == 1)
        #expect(model.turn.destination == "Notes")
        #expect(model.turn.captureOpen)
        let content = model.content()
        #expect(content.words == .live("can we meet"))
        #expect(content.trailing.text == "0:04")
        #expect(content.helper == "Release fn / 🌐 to finish")
        // Key up: the words stay through finishing; the microphone is closed.
        model.apply(.finishing)
        #expect(!model.turn.captureOpen)
        #expect(model.content().words == .live("can we meet"))
        #expect(model.content().trailing == .destination("Notes"))
        // A landed row, then a new press: a fresh turn (fresh clock, fresh words, destination asked again).
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Can we meet?", destination: "Notes")
        #expect(model.content().status == "✓ Inserted in Notes")
        model.apply(.listening(level: 0.1))
        #expect(asked == 2)
        #expect(model.turn.liveText.isEmpty)
        #expect(model.content().trailing.text == "0:00")
    }

    /// B4 hand-off: engine ticks never overwrite the latch timer; the latched row keeps the live words.
    @Test func engineTicksDoNotOverwriteTheLatchTimer() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.latched = true
        model.present(.latched(elapsed: 12))
        model.apply(.listening(level: 0.5))
        #expect(model.state == .latched(elapsed: 12))
        model.apply(.previewing(text: "segment two words"))
        #expect(model.state == .latched(elapsed: 12))
        #expect(model.content().words == .live("segment two words"))
        #expect(model.content().trailing.text == "0:12")
        model.present(.latched(elapsed: 13))
        #expect(model.content().trailing.text == "0:13")
        // A segment's landed row comes back to the latched row, not down under an open microphone.
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "segment two words.", destination: "Notes")
        #expect(model.state.caseName == "landed")
        model.retractDelivery()
        #expect(model.state == .latched(elapsed: 13))
        #expect(model.turn.liveText.isEmpty)
    }

    /// A notice presented mid-capture (the deixis "Screen text isn't available") never replaces the
    /// live words: it becomes the lane note under them.
    @Test func aNoticeMidCaptureBecomesTheLaneNote() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.apply(.listening(level: 0.2))
        model.apply(.previewing(text: "look at this"))
        model.present(.preview(text: "Screen text isn't available"))
        #expect(model.state == .preview(text: "look at this"))
        #expect(model.laneNote == "Screen text isn't available")
        model.apply(.idle)
        #expect(model.laneNote == nil)
    }

    @Test func buttonsRouteToTheirOwners() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        var actions: [PillActionKind] = []
        var held: [HeldAction] = []
        model.onAction = { action, _ in actions.append(action) }
        model.onHeldAction = { _, action in held.append(action) }
        model.present(.held(HeldPillInfo(text: "t", destination: "Mail", reason: "destination changed")))
        model.perform(.insert)
        model.perform(.copy)
        #expect(held == [.insertHere, .copy])
        #expect(actions.isEmpty)
        model.present(.finalPreview(FinalPreviewInfo(text: "t", dwellRemaining: 0, manual: true)))
        model.perform(.commit)
        #expect(actions == [.commit])
        // Dismiss takes a sticky notice down at once.
        model.present(delivery: .delivered(verified: false, method: "paste"), text: "t", destination: "Docs")
        model.apply(.idle)
        #expect(model.state.caseName == "landedUnverified")
        model.perform(.dismiss)
        #expect(model.state == .hidden)
        // Check destination hands off (to Today) and takes the row down.
        model.present(delivery: .partial(method: "paste"), text: "t", destination: "Docs")
        model.perform(.check)
        #expect(actions.last == .check)
        #expect(model.state == .hidden)
    }

    @Test func hoverIsReportedOnceEachWay() {
        let model = PillViewModel()
        var seen: [Bool] = []
        model.onPointerInsideChange = { seen.append($0) }
        model.setPointerInside(true)
        model.setPointerInside(true)
        model.setPointerInside(false)
        #expect(seen == [true, false])
        #expect(!model.pointerInside)
    }

    @Test func finalSpansMarkTheUncertainWords() {
        let model = PillViewModel()
        model.setFinalSpans([TranscriptSpan(text: "Can", confidence: 0.9, audioRange: 0...0.2),
                             TranscriptSpan(text: "Mira,", confidence: 0.3, audioRange: 0.2...0.5),
                             TranscriptSpan(text: "Friday", confidence: 0.95, audioRange: 0.5...0.9)])
        #expect(model.turn.uncertainCount == 1)
        #expect(model.turn.uncertainWords == ["mira"])
        #expect(PillTextLane.normalized("Mira?") == "mira")
    }

    // MARK: - Text lane

    // MARK: - Deixis chip

    @Test func theDeixisChipLivesInTheTurnsHeader() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.apply(.listening(level: 0.2))
        let a = DeixisRegion(id: UUID(), rect: CGRect(x: 0, y: 0, width: 50, height: 20), displayID: 1,
                             text: "Quarterly revenue by region and product line")
        let b = DeixisRegion(id: UUID(), rect: CGRect(x: 0, y: 0, width: 50, height: 20), displayID: 1, isPending: true)
        model.showDeixis([a, b]) { _ in nil }
        #expect(model.deixisChips.map(\.label) == ["Quarterly revenue by reg…", "Box 2"])
        #expect(model.deixisChips.last?.pending == true)
        #expect(model.turn.chipCount == 2)
        let lanes = PillLaneLayout(size: NotchGeometry.activeSize, hasChip: true, hasActions: false)
        #expect(lanes.chipRow != nil && !(lanes.chipRow!.intersects(lanes.bay)))
        #expect(lanes.wordsLane.height == 48)
        #expect(lanes.chipRow!.maxY < lanes.wordsLane.minY)
        // The turn ends: the chip goes with it.
        model.apply(.idle)
        #expect(model.deixisChips.isEmpty)
        #expect(PillDeixisChip.make(a, index: 1, image: nil).thumbnail == nil)
    }
}
