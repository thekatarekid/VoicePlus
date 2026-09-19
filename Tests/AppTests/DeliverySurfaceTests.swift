import Actions
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// R2.4 — every `DeliveryOutcome` has a row, in the existing pill language, and the held row's
/// three actions do what they say. No test here asserts a *look*: the acceptance criterion is that
/// nothing new was invented, so the assertions are about states, copy and dwell.
@Suite("R2.4 — outcome → pill row")
struct DeliveryRowTests {
    static let text = "Ship the release notes before Friday and tell the team."

    @Test func everyOutcomeHasARow() {
        let rows = [
            DeliveryOutcome.delivered(verified: true, method: "keystroke"),
            .delivered(verified: false, method: "paste"),
            .held(reason: "destination changed"),
            .failed(reason: "no method could type here: keystroke,paste"),
        ].map { PillDeliveryRouter.state(for: $0, text: Self.text, destination: "Notes") }
        #expect(rows.map(\.caseName) == ["landed", "landedUnverified", "held", "error"])
        let everyRowIsVisible = rows.allSatisfy(\.isVisible)
        #expect(everyRowIsVisible)
    }

    /// The whole point of R2.4 (V3 §4.1, §14.1): what the pill shows on land is the *committed*
    /// text, not the streaming preview the owner watched being wrong.
    @Test func landedRowShowsTheCommittedTextNotThePreview() {
        let preview = "ship the release notes before friday and tell the"
        var model = PillStateReducer()
        #expect(model.reduce(.previewing(text: preview)) == .preview(text: preview))

        let landed = PillDeliveryRouter.state(for: .delivered(verified: true, method: "keystroke"),
                                              text: Self.text, destination: "Notes")
        guard case .landed(let info) = landed else { Issue.record("expected a landed row"); return }
        #expect(info.text == Self.text)
        #expect(info.headline == Self.text)
        #expect(info.verified)
        #expect(info.subtitle == nil)          // verified draws the text in `preview`'s row
        #expect(info.text != preview)
    }

    @Test func unverifiedLandedRowSaysSoVerbatim() {
        let state = PillDeliveryRouter.state(for: .delivered(verified: false, method: "paste"),
                                             text: Self.text, destination: "Brave Browser")
        guard case .landed(let info) = state else { Issue.record("expected a landed row"); return }
        #expect(info.headline == "Landed · not confirmed")
        #expect(info.headline == DeliveryCopy.landedUnverified)
        #expect(!info.verified)
        // The committed text is still shown — in the subtitle slot, under the honest headline.
        #expect(info.subtitle == Self.text)
        #expect(state.messageLines.contains("Landed · not confirmed"))
    }

    @Test func heldRowNamesTheDestinationAndOffersThreeActions() {
        let state = PillDeliveryRouter.state(for: .held(reason: "no safe destination"),
                                             text: Self.text, destination: "Notes")
        guard case .held(let info) = state else { Issue.record("expected a held row"); return }
        #expect(info.headline == "Held for Notes")
        #expect(info.subtitle.contains("Ship the release notes"))
        #expect(HeldAction.allCases.map(\.label) == ["Insert here", "Copy", "Discard"])
        #expect(HeldAction.allCases.map(\.identifier)
            == ["pill.held.insertHere", "pill.held.copy", "pill.held.discard"])
    }

    /// A held row whose destination vanished falls back to the canonical sentence, never to a
    /// bundle ID or a raw reason.
    @Test func heldRowFallsBackToTheCanonicalSentence() {
        let changed = PillDeliveryRouter.state(for: .held(reason: "destination changed"),
                                               text: Self.text, destination: "Notes")
        guard case .held(let info) = changed else { Issue.record("expected a held row"); return }
        #expect(info.headline == "Destination changed — Copy text")

        let unknown = HeldPillInfo(text: Self.text, destination: "", reason: "target unsafe")
        #expect(unknown.headline == "Destination changed — Copy text")
    }

    /// DESIGN §8.4: every fixed string a held row draws is in `messageLines`, so `NotchGeometry`
    /// sizes the panel to it and the actions can never be clipped.
    @Test func heldAndLandedRowsAreSizedLikeEveryOtherTwoLineRow() {
        let held = PillDeliveryRouter.state(for: .held(reason: "focus moved"), text: Self.text, destination: "Notes")
        let lines = held.messageLines
        #expect(lines.contains("Destination changed — Copy text"))
        #expect(lines.contains(HeldPillInfo.actionsLine))
        #expect(HeldPillInfo.actionsLine.contains("Insert here"))
        // S2: both are actionable rows — 560 × 204 with the action row below the character bay.
        #expect(NotchGeometry.size(for: held) == NotchGeometry.actionableSize)
        let landed = PillDeliveryRouter.state(for: .delivered(verified: false, method: "paste"),
                                              text: Self.text, destination: "Notes")
        #expect(NotchGeometry.size(for: landed) == NotchGeometry.actionableSize)
        // Verified landing draws variable-length committed text; like `.preview` it is deliberately
        // not measured, so the panel keeps its reserved size instead of tracking the sentence.
        let verified = PillDeliveryRouter.state(for: .delivered(verified: true, method: "ax"),
                                                text: Self.text, destination: "Notes")
        #expect(verified.messageLines.isEmpty)
    }

    /// S2 (design §5, §10): verified insertion shows for 650 ms; a held row stays until the user acts.
    @Test func insertedDwellsSixFiftyAndHeldStaysUntilTheUserActs() {
        let landed = PillDeliveryRouter.state(for: .delivered(verified: true, method: "ax"), text: "hi")
        let held = PillDeliveryRouter.state(for: .held(reason: "focus moved"), text: "hi", destination: "Notes")
        #expect(PillDwell.minimum(for: landed) == 0.65)
        #expect(PillDwell.staysUntilAction(held))
        #expect(PillDwell.minimum(for: .landing) == PillDwell.acknowledgement)
    }

    /// The committed text cannot be flashed past: a retraction arriving in the same run-loop pass
    /// waits out the 650 ms (the `PillPresenter` rule the landed row reuses).
    @Test func aRetractionCannotTakeTheCommittedTextAwayImmediately() {
        var presenter = PillPresenter()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let landed = PillDeliveryRouter.state(for: .delivered(verified: true, method: "ax"), text: Self.text)
        #expect(presenter.request(landed, now: t0) == .show(landed))
        #expect(presenter.request(.hidden, now: t0) == .hold(until: t0.addingTimeInterval(0.65)))
        #expect(presenter.flush(now: t0.addingTimeInterval(0.5)) == .hold(until: t0.addingTimeInterval(0.65)))
        #expect(presenter.flush(now: t0.addingTimeInterval(0.7)) == .show(.hidden))
    }

    /// Acting on a row is not the same as a row flashing past: a dismissal skips the dwell.
    @Test func actingOnAHeldRowTakesItDownAtOnce() {
        var presenter = PillPresenter()
        let t0 = Date(timeIntervalSince1970: 2_000)
        let held = PillDeliveryRouter.state(for: .held(reason: "focus moved"), text: "hi", destination: "Notes")
        #expect(presenter.request(held, now: t0) == .show(held))
        #expect(presenter.dismiss(now: t0.addingTimeInterval(0.3)) == .show(.hidden))
    }
}

@Suite("R2.4 — the three held actions")
struct HeldActionTests {
    private func store() -> HeldTextStore {
        let s = HeldTextStore()
        s.clock = { Date(timeIntervalSince1970: 10) }
        return s
    }

    @Test func insertHereDeliversAndClearsTheItem() {
        let s = store()
        var inserted: [String] = []
        s.insertSink = { inserted.append($0.text); return true }
        let item = s.hold(text: "one two", destination: "Notes", reason: "destination changed")
        #expect(s.count == 1)
        #expect(s.perform(.insertHere, on: item.id) == .inserted)
        #expect(inserted == ["one two"])
        #expect(s.isEmpty)
    }

    @Test func aRefusedInsertionKeepsTheTextHeld() {
        let s = store()
        s.insertSink = { _ in false }
        let item = s.hold(text: "one two", destination: "Notes", reason: "focus moved")
        #expect(s.perform(.insertHere, on: item.id) == .unavailable)
        #expect(s.count == 1)                       // never silently dropped
    }

    @Test func copyPutsItOnThePasteboardAndDiscardThrowsItAway() {
        let s = store()
        var copied: [String] = []
        s.copySink = { copied.append($0.text) }
        let a = s.hold(text: "first", destination: "Notes", reason: "focus moved")
        let b = s.hold(text: "second", destination: "Brave Browser", reason: "focus moved")
        #expect(s.perform(.copy, on: a.id) == .copied)
        #expect(copied == ["first"])
        #expect(s.perform(.discard, on: b.id) == .discarded)
        #expect(s.isEmpty)
        #expect(s.perform(.copy, on: a.id) == .unknownItem)
    }

    @Test func withoutASinkTheActionIsUnavailableAndTheTextSurvives() {
        let s = store()
        let item = s.hold(text: "keep me", destination: "Notes", reason: "focus moved")
        #expect(s.perform(.insertHere, on: item.id) == .unavailable)
        #expect(s.perform(.copy, on: item.id) == .unavailable)
        #expect(s.count == 1)
        #expect(s.perform(.discard, on: item.id) == .discarded)
    }

    /// Discard has to reach the queue that owns the words, not just the row that draws them.
    /// `FocusGuard.held` is that queue in the real app; here the sink stands in for it.
    @Test func discardTellsTheOwnerToDropTheTextToo() {
        let s = store()
        var discarded: [String] = []
        s.discardSink = { discarded.append($0.text) }
        let item = s.hold(text: "forget this", destination: "Notes", reason: "focus moved")
        #expect(s.perform(.discard, on: item.id) == .discarded)
        #expect(discarded == ["forget this"])
        #expect(s.isEmpty)
    }

    /// The surface adopts `Injection.HeldText.id` when the composition root passes it through, so
    /// Insert here / Copy / Discard act on the same item in both queues.
    @Test @MainActor func theSurfaceAdoptsInjectionsHeldID() {
        let injectionSideID = UUID()
        let driver = DeliveryPillDriver(pill: PillViewModel())
        let state = driver.handle(.held(reason: "never-inject list"), text: "words",
                                  destination: "Brave Browser", heldID: injectionSideID)
        #expect(driver.held.latest?.id == injectionSideID)
        guard case .held(let info) = state else { Issue.record("expected the held row"); return }
        #expect(info.id == injectionSideID)
        // A never-inject hold did not lose its destination, so the row still names it.
        #expect(info.headline == "Held for Brave Browser")
    }

    @Test func theQueueIsBounded() {
        let s = HeldTextStore(limit: 2)
        s.hold(text: "a", destination: "Notes", reason: "focus moved")
        let second = s.hold(text: "b", destination: "Notes", reason: "focus moved")
        let third = s.hold(text: "c", destination: "Notes", reason: "focus moved")
        #expect(s.items.map(\.text) == ["b", "c"])
        #expect(s.item(id: second.id) != nil)
        #expect(s.item(id: third.id) != nil)
    }

    @Test @MainActor func theDriverHoldsTheTextShowsTheRowAndClearsItOnAnAction() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        var copied: [String] = []
        driver.held.copySink = { copied.append($0.text) }
        var changes: [Int] = []
        driver.onHeldChanged = { changes.append($0.count) }

        let state = driver.handle(.held(reason: "destination changed"), text: "held words", destination: "Notes")
        #expect(state.caseName == "held")
        #expect(pill.state.caseName == "held")
        #expect(driver.held.count == 1)
        guard case .held(let info) = pill.state else { Issue.record("expected the held row"); return }
        #expect(info.id == driver.held.latest?.id)

        #expect(driver.perform(.copy, on: info.id) == .copied)
        #expect(copied == ["held words"])
        #expect(driver.held.isEmpty)
        #expect(pill.state == .hidden)              // the row comes down as soon as it is handled
        #expect(changes == [1, 0])
    }

    @Test @MainActor func theDriverRoutesTheRowsOwnButtons() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        driver.held.insertSink = { _ in true }
        driver.handle(.held(reason: "focus moved"), text: "words", destination: "Notes")
        guard case .held(let info) = pill.state else { Issue.record("expected the held row"); return }
        pill.onHeldAction?(info, .insertHere)       // exactly what the pill button calls
        #expect(driver.held.isEmpty)
    }

    @Test @MainActor func deliveredAndFailedOutcomesHoldNothing() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        driver.handle(.delivered(verified: false, method: "paste"), text: "typed", destination: "Notes")
        #expect(pill.state.caseName == "landedUnverified")
        #expect(driver.held.isEmpty)
        // A secure field is the one refusal that keeps nothing: the row says so and offers the only
        // action there is, and no held item appears for the user to "recover".
        driver.handle(.failed(reason: "secure field"), text: "typed", destination: "1Password")
        #expect(pill.state == .error(message: "Text was not typed — Try again"))
        #expect(driver.held.isEmpty)
    }
}

@Suite("R2.4 — R2.5's repair suggestions land on an existing row")
struct RepairSuggestionPresentationTests {
    /// The integration point R2.5 defined: `Actions` writes the sentence, R2.4 puts it in the
    /// *existing* `.error` notice — no new row, no new action, no new mark.
    @Test @MainActor func aRepairSuggestionBecomesAnExistingNoticeRow() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        let suggestion = RepairSuggestion(command: .scratchThat, segment: nil,
                                          reason: .regionChanged(actual: "something else entirely"))
        driver.present(suggestion)   // synchronous when already on the main actor
        #expect(pill.state == .error(message: "Text changed — nothing scratched"))
        #expect(pill.state.caseName == "error")
        // A suggestion is not a delivery: nothing is held, and the quit guard stays quiet.
        #expect(driver.held.isEmpty)
        #expect(driver.quitDecision == .quit)
    }

    /// The row must carry `Actions`' own sentence, not be rewritten by the delivery copy deck —
    /// `DeliveryCopy` only speaks for `DeliveryOutcome`s.
    @Test @MainActor func theSuggestionsOwnWordsSurvive() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        driver.present(RepairSuggestion(command: .putItBack, segment: nil, reason: .nothingToPutBack))
        #expect(pill.state == .error(message: "Nothing to put back"))
        #expect(pill.state != .error(message: DeliveryCopy.couldNotType))
    }
}

@Suite("R2.4 — error copy (V3 §6, verbatim)")
struct DeliveryCopyTests {
    @Test func theThreeSentencesAreExact() {
        #expect(DeliveryCopy.destinationChanged == "Destination changed — Copy text")
        #expect(DeliveryCopy.microphoneDisconnected == "Microphone disconnected — Choose microphone")
        #expect(DeliveryCopy.noSpeechDetected == "No speech detected — Try again")
    }

    @Test func reasonsMapOntoThoseSentences() {
        #expect(DeliveryCopy.message(forFailure: "destination changed") == DeliveryCopy.destinationChanged)
        #expect(DeliveryCopy.message(forFailure: "focus moved mid-utterance") == DeliveryCopy.destinationChanged)
        // These three all mean "nothing was typed, and nothing is being held for you", so none of
        // them may say "Copy text". Two of them contain the word "destination" anyway.
        #expect(DeliveryCopy.message(forFailure: "secure field") == DeliveryCopy.couldNotType)
        #expect(DeliveryCopy.message(forFailure: "no destination") == DeliveryCopy.couldNotType)
        #expect(DeliveryCopy.message(forFailure: "every method threw") == DeliveryCopy.couldNotType)
        #expect(DeliveryCopy.message(forFailure: "microphone disconnected") == DeliveryCopy.microphoneDisconnected)
        #expect(DeliveryCopy.message(forFailure: "no input device") == DeliveryCopy.microphoneDisconnected)
        #expect(DeliveryCopy.message(forFailure: "no speech detected") == DeliveryCopy.noSpeechDetected)
        #expect(DeliveryCopy.message(forFailure: "empty transcript") == DeliveryCopy.noSpeechDetected)
    }

    /// The rule that matters: a reason we do not recognise still reads as a sentence with an action,
    /// and none of the raw text reaches the user (DESIGN §7.2 — raw errors go to the log only).
    @Test func aRawErrorIsNeverShown() {
        let raw = "Error Domain=NSAccessibilityErrorDomain Code=-25204 kAXErrorCannotComplete (OSStatus -1719)"
        let shown = DeliveryCopy.message(forFailure: raw)
        #expect(shown == DeliveryCopy.couldNotType)
        #expect(!shown.contains("-25204"))
        #expect(!shown.contains("kAXError"))
        #expect(!shown.contains("OSStatus"))
        for sentence in [DeliveryCopy.destinationChanged, DeliveryCopy.microphoneDisconnected,
                         DeliveryCopy.noSpeechDetected, DeliveryCopy.couldNotType] {
            #expect(sentence.contains(" — "))       // Problem — Action, every time
            #expect(!sentence.hasSuffix("."))
            #expect(!sentence.contains("!"))
        }
    }

    @Test func failedOutcomesNeverLeakTheMethodListIntoTheRow() {
        let state = PillDeliveryRouter.state(for: .failed(reason: "no method could type here: keystroke,paste"),
                                             text: "words")
        guard case .error(let message) = state else { Issue.record("expected an error row"); return }
        #expect(!message.contains("keystroke"))
        #expect(message == DeliveryCopy.couldNotType)
    }
}

@Suite("R2.4 — quit guard and the Recover text menu")
struct HeldMenuAndQuitTests {
    @Test func theQuitGuardFiresOnlyWhenSomethingIsHeld() {
        #expect(QuitGuard.decision(heldCount: 0) == .quit)
        #expect(!QuitGuard.decision(heldCount: 0).warns)
        #expect(QuitGuard.decision(heldCount: 1).warns)
        #expect(QuitGuard.decision(heldCount: 4).warns)
        guard case .warn(let title, let message) = QuitGuard.decision(heldCount: 1) else {
            Issue.record("expected a warning"); return
        }
        #expect(title == "Held text has not been typed")
        #expect(message.contains("One piece"))
        #expect(QuitGuard.message(heldCount: 3).contains("3 pieces"))
        #expect(QuitGuard.quitAnyway == "Quit anyway")
    }

    @Test @MainActor func theDriverAnswersTheQuitGuardFromItsOwnQueue() {
        let driver = DeliveryPillDriver(pill: PillViewModel())
        #expect(driver.quitDecision == .quit)
        driver.handle(.held(reason: "focus moved"), text: "words", destination: "Notes")
        #expect(driver.quitDecision.warns)
        driver.held.discardAll()
        #expect(driver.quitDecision == .quit)
    }

    @Test func theMenuSectionHidesWhenNothingIsHeldAndCountsWhenItIs() {
        #expect(!HeldMenu.isVisible(count: 0))
        #expect(HeldMenu.isVisible(count: 1))
        #expect(HeldMenu.title(count: 1) == "Recover text")
        #expect(HeldMenu.title(count: 2) == "Recover text (2)")
        #expect(HeldMenu.actions.map(\.menuTitle) == ["Insert here", "Copy", "Discard"])
        let item = HeldItem(text: "Ship the release notes before Friday", destination: "Notes",
                            reason: "destination changed")
        let header = HeldMenu.header(for: item)
        #expect(header.contains("Ship the release notes"))
        #expect(header.hasSuffix("— Notes"))
        #expect(!HeldMenu.header(for: HeldItem(text: "short", destination: "", reason: "x")).contains("—"))
    }
}

@Suite("R2.4 — DeliveryOutcome out of the lander")
struct LanderDeliveryOutcomeTests {
    @Test func injectionOutcomesBecomeDeliveryOutcomes() {
        #expect(DeliveryOutcome(injection: .injected(method: .keystroke, verified: true))
            == .delivered(verified: true, method: "keystroke"))
        // The readback rule: unconfirmed stays *delivered*, never a failure and never a retry.
        let unverified = DeliveryOutcome(injection: .injected(method: .paste, verified: false))
        #expect(unverified == .delivered(verified: false, method: "paste"))
        #expect(unverified.isDelivered)
        #expect(!unverified.isVerified)
        #expect(DeliveryOutcome(injection: .abortedFocusChanged(expected: nil, actual: nil)).isHeld)
        #expect(!DeliveryOutcome(injection: .abortedFocusChanged(expected: nil, actual: nil)).isTerminal)
        #expect(DeliveryOutcome(injection: .failed(attempts: [.keystroke, .paste])).isFailed)
        // R2.3's refusals: a never-inject app keeps its text for recovery, a password field does not.
        #expect(DeliveryOutcome(injection: .refused(.neverInject)).isHeld)
        #expect(DeliveryOutcome(injection: .refused(.secureField)).isFailed)
    }

    /// Every reason string `Injection` actually produces has to land on a sentence, and none of
    /// them may reach the user raw. This is the seam between R2.3 and R2.4, so it is asserted here
    /// rather than assumed.
    @Test func everyInjectionOutcomeReachesARowWithReadableCopy() {
        let outcomes: [InjectionOutcome] = [
            .injected(method: .keystroke, verified: true), .injected(method: .paste, verified: false),
            .abortedFocusChanged(expected: nil, actual: nil),
            .failed(attempts: []), .failed(attempts: [.keystroke, .paste]),
            .refused(.neverInject), .refused(.secureField),
        ]
        for outcome in outcomes {
            let state = PillDeliveryRouter.state(for: DeliveryOutcome(injection: outcome),
                                                 text: "words", destination: "Notes")
            #expect(state.isVisible)
            for line in state.messageLines {
                #expect(!line.contains("attempts"))
                #expect(!line.contains("InjectionOutcome"))
            }
            if case .error(let message) = state {
                #expect([DeliveryCopy.destinationChanged, DeliveryCopy.microphoneDisconnected,
                         DeliveryCopy.noSpeechDetected, DeliveryCopy.couldNotType].contains(message))
            }
        }
    }

    @Test func landingResultCarriesTheOutcomeAndTheDestination() {
        var result = LandingResult(utteranceID: UUID(), route: .dictate, register: .unknown,
                                   text: "landed words", injection: .injected(method: .ax, verified: true),
                                   focusDestination: "Notes", repair: nil, pipelineMs: 0, totalMs: 0)
        #expect(result.delivery == .delivered(verified: true, method: "ax"))
        #expect(result.destinationName == "Notes")
        result.injection = nil
        #expect(result.delivery == nil)             // a repair / act claim delivered nothing
        #expect(LandingResult(utteranceID: UUID(), route: .none, register: .unknown, text: "",
                              injection: nil, repair: nil, pipelineMs: 0, totalMs: 0).destinationName == "")
    }

    @Test func theDestinationIsAlwaysAHumanName() {
        let focus = FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes")
        #expect(UtteranceLander.destinationName(focus: focus, bundleID: "com.apple.Notes") == "Notes")
        // No snapshot: derive something readable from the bundle ID, never show the identifier.
        #expect(UtteranceLander.destinationName(focus: nil, bundleID: "com.apple.Notes") == "Notes")
        #expect(UtteranceLander.destinationName(focus: nil, bundleID: nil) == nil)
    }

    @Test @MainActor func aLandingResultDrivesTheRowEndToEnd() {
        let pill = PillViewModel()
        let driver = DeliveryPillDriver(pill: pill)
        let result = LandingResult(utteranceID: UUID(), route: .dictate, register: .unknown,
                                   text: "the committed sentence",
                                   injection: .abortedFocusChanged(expected: nil, actual: nil),
                                   focusDestination: "Notes", repair: nil, pipelineMs: 0, totalMs: 0)
        let state = driver.handle(result, destination: result.destinationName)
        #expect(state?.caseName == "held")
        #expect(driver.held.latest?.text == "the committed sentence")
        #expect(driver.held.latest?.destination == "Notes")
    }
}
