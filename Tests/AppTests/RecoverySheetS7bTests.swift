import Foundation
import GRDB
import Shared
import Testing
@testable import VoicePlusApp

// S7b — the recovery sheet and turn detail (design §8.1, §9; DESIGN.md §9.1), the turn-store reader
// over a real in-memory `TurnStore`, and the sheet's copy held to the verified prototype.

@Suite("Recovery sheet (S7b)")
@MainActor
struct RecoverySheetS7bTests {
    typealias Rig = S7bRig

    static let notes = RecoveryTarget(pid: 42, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "7",
                                      role: "AXTextArea", isSecure: false, isEditable: true)

    /// A held turn Today lists, and its sheet.
    static func heldRig(persisted: Bool = true, live: Bool = false) async throws -> (Rig, TodayDraft, RecoverySheetModel) {
        let turn = TurnID()
        var record = Rig.record("Can we meet with Mira on Friday?", spans: [17..<21], outcome: .held(reason: "destination changed"))
        record.turnID = turn
        let item = HeldItem(text: record.finalText, destination: "Mail", reason: "destination changed")
        let rig = Rig([Rig.entry(record, .held, persisted: persisted)], held: live ? [item] : [])
        if live { rig.queue.turnByHeld[item.id] = turn }
        await rig.model.reloadHistory()
        let draft = try #require(rig.model.drafts.first)
        rig.model.presentRecovery(draft)
        let sheet = try #require(rig.model.recovery)
        sheet.load()
        return (rig, draft, sheet)
    }

    @Test("the sheet shows the whole payload, the design's words and where it is kept")
    func sheetCopy() async throws {
        let (_, draft, sheet) = try await Self.heldRig()
        #expect(sheet.state.isContent)
        #expect(sheet.draft?.text == "Can we meet with Mira on Friday?", "the complete payload")
        #expect(sheet.draft?.uncertainSpans == [17..<21], "uncertain words stay marked")
        #expect(sheet.title == "Your text is still here.")
        #expect(sheet.subtitle == "Destination changed · held for Mail")
        #expect(sheet.banner?.headline == "Nothing was inserted")
        #expect(sheet.banner?.body == "Select a text field, then explicitly choose Insert here. A new destination will never receive this text automatically.")
        #expect(sheet.retentionLines.first == "Kept until resolved · closing this window keeps the draft.")
        #expect(!sheet.copyIsPrimary)
        #expect(draft.retention == .keptUntilResolved)
    }

    @Test("persistence off says “Kept for this session only”; a failed save is S03 with Copy primary")
    func sessionOnlyAndSaveFailed() async throws {
        let (_, draft, sheet) = try await Self.heldRig(persisted: false)
        #expect(draft.retention.label == "Kept for this session only")
        #expect(sheet.retentionLines.first?.hasPrefix("Kept for this session only") == true)
        #expect(!sheet.retentionLines.joined().contains("Kept until resolved"), "never claims a save that did not happen")

        let turn = TurnID()
        var record = Rig.record("unsaved words", outcome: .held(reason: "destination changed"))
        record.turnID = turn
        let rig = Rig([Rig.entry(record, .held, persisted: false)])
        rig.turns.failedSaves = [turn]
        await rig.model.reloadHistory()
        let failed = try #require(rig.model.drafts.first)
        #expect(failed.retention == .saveFailed)
        rig.model.presentRecovery(failed)
        let s03 = try #require(rig.model.recovery)
        #expect(s03.banner?.recoveryID == .S03)
        #expect(s03.banner?.headline == "This text hasn’t been saved")
        #expect(s03.banner?.actionTitle == "Copy text")
        #expect(s03.copyIsPrimary, "design §9: Copy is primary when storage fails")
    }

    @Test("history off: the sheet explains that held text is kept separately")
    func historyOffRetention() async throws {
        let (rig, _, sheet) = try await Self.heldRig()
        TodayHistorySettings.setEnabled(false, store: rig.settings)
        #expect(sheet.retentionLines.contains { $0.contains("history is off") })
        #expect(sheet.retentionLines.first == "Kept until resolved · closing this window keeps the draft.")
    }

    @Test("Insert here needs Accessibility (P02), a picked text field (D02) and never a password field (D03)")
    func insertPreconditions() async throws {
        let (rig, _, sheet) = try await Self.heldRig()
        rig.destinations.canReadFields = false
        await sheet.insertHere()
        #expect(sheet.phase == .problem(.P02))
        #expect(sheet.problemAction == "Open Accessibility settings")
        sheet.performProblemAction()
        #expect(rig.destinations.openedSettings == 1)

        rig.destinations.canReadFields = true
        rig.destinations.picked = nil
        sheet.refreshTarget()
        #expect(sheet.destinationLine == RecoverySheetModel.noFieldChosen)
        await sheet.insertHere()
        #expect(sheet.phase == .problem(.D02))

        var password = Self.notes
        password.role = "AXSecureTextField"
        password.isSecure = true
        rig.destinations.picked = password
        sheet.refreshTarget()
        #expect(sheet.destinationLine.contains("Password field"))
        await sheet.insertHere()
        #expect(sheet.phase == .problem(.D03))
        #expect(rig.destinations.forwarded.isEmpty, "nothing was brought forward, nothing written")
        #expect(rig.queue.insertedText.isEmpty && rig.actions.isEmpty)
        #expect(rig.model.drafts.count == 1, "the draft is kept")
    }

    @Test("revalidation: a field that changed after the pick holds the text (D01) — nothing is written")
    func revalidationFailureHolds() async throws {
        let (rig, _, sheet) = try await Self.heldRig()
        rig.destinations.picked = Self.notes
        sheet.refreshTarget()
        #expect(sheet.destinationLine == "Insert here goes to Notes · Text area.")
        var other = Self.notes
        other.elementToken = "8"
        rig.destinations.forwardFollowsPick = false
        rig.destinations.afterForward = other
        await sheet.insertHere()
        #expect(rig.destinations.forwarded == [Self.notes], "the picked app was brought forward")
        #expect(sheet.phase == .problem(.D01))
        #expect(sheet.outcomeNotice?.text == "Destination changed — text held")
        #expect(rig.queue.insertedText.isEmpty && rig.queue.insertedHeld.isEmpty && rig.actions.isEmpty)
        #expect(rig.model.drafts.count == 1)

        // The app never came forward: same verdict.
        rig.destinations.afterForward = nil
        await sheet.insertHere()
        #expect(sheet.phase == .problem(.D01))
        #expect(rig.queue.insertedText.isEmpty)
    }

    @Test("Insert here writes once into the revalidated field and reports the stack's outcome")
    func insertHereOnce() async throws {
        let (rig, draft, sheet) = try await Self.heldRig()
        rig.destinations.picked = Self.notes
        await sheet.insertHere()
        #expect(rig.queue.insertedText.count == 1, "one write")
        #expect(rig.queue.insertedText.first?.0 == draft.text)
        #expect(rig.queue.insertedText.first?.1 == Self.notes, "refuses unless focus is still the picked field")
        #expect(sheet.phase == .inserted(.delivered(verified: true, method: "ax"), destination: "Notes"))
        #expect(sheet.outcomeNotice == TodayNotice(text: "Inserted in Notes", tone: .good))
        #expect(rig.turns.insertions.map { $0.0 } == [draft.turnID!], "the turn follows the insertion")
        #expect(rig.model.drafts.isEmpty, "inserted text is no longer held")
        #expect(!sheet.canAct, "a resolved sheet can't write again")
        await sheet.insertHere()
        #expect(rig.queue.insertedText.count == 1, "a second press writes nothing")
        #expect(sheet.state.isContent, "the sheet that resolved it says so, not “no longer available”")
    }

    @Test("an unconfirmed insertion says so and never retries (D06)")
    func unconfirmedInsertion() async throws {
        let (rig, _, sheet) = try await Self.heldRig()
        rig.destinations.picked = Self.notes
        rig.queue.insertOutcome = .delivered(verified: false, method: "paste")
        await sheet.insertHere()
        #expect(sheet.outcomeNotice?.recoveryID == .D06)
        #expect(sheet.outcomeNotice?.text == "Inserted · not confirmed")
        #expect(rig.queue.insertedText.count == 1)
    }

    @Test("a live held item goes through the pill's queue, so its row and the menu drop it too")
    func insertThroughPillQueue() async throws {
        let (rig, draft, sheet) = try await Self.heldRig(live: true)
        #expect(draft.heldID != nil)
        rig.destinations.picked = Self.notes
        rig.turns.settle(draft.turnID!, stage: .held, outcome: .held(reason: "destination changed"))
        await sheet.insertHere()
        #expect(rig.actions.map { $0.1 } == [.insertHere])
        #expect(rig.queue.insertedText.isEmpty, "never a second path for the same words")
        // No turn controller in the rig: a reported success with no recorded outcome is unconfirmed.
        #expect(sheet.phase == .inserted(.delivered(verified: false, method: ""), destination: "Notes"))
    }

    @Test("Copy text is acknowledged only when verified; a failed copy keeps the draft and offers Select text")
    func copyVerified() async throws {
        let (rig, _, sheet) = try await Self.heldRig()
        rig.pasteboard.refuses = true
        sheet.copy()
        #expect(sheet.phase == .problem(.D08))
        #expect(sheet.outcomeNotice?.text == "Couldn’t copy your text")
        #expect(sheet.problemAction == "Select text")
        let before = sheet.selectAllRequest
        sheet.performProblemAction()
        #expect(sheet.selectAllRequest == before + 1, "the payload is selected for a manual copy")
        #expect(rig.model.drafts.count == 1 && rig.turns.resolved.isEmpty)

        rig.pasteboard.refuses = false
        sheet.copy()
        #expect(sheet.phase == .copied)
        #expect(sheet.outcomeNotice == .copied)
        #expect(rig.pasteboard.contents == "Can we meet with Mira on Friday?")
    }

    @Test("Discard… asks first only when it destroys the only saved copy")
    func discardConfirmation() async throws {
        let (rig, draft, sheet) = try await Self.heldRig()
        TodayHistorySettings.setEnabled(false, store: rig.settings)
        sheet.requestDiscard()
        #expect(sheet.confirmingDiscard, "history off: the only saved copy")
        #expect(rig.turns.deleted.isEmpty && rig.turns.resolved.isEmpty, "nothing happens before the yes")
        sheet.cancelDiscard()
        #expect(!sheet.confirmingDiscard && rig.model.drafts.count == 1)
        sheet.requestDiscard()
        sheet.confirmDiscard()
        #expect(sheet.phase == .discarded)
        #expect(rig.turns.deleted == [draft.turnID!])

        let (rig2, draft2, sheet2) = try await Self.heldRig()
        sheet2.requestDiscard()
        #expect(!sheet2.confirmingDiscard, "history keeps the turn: no confirmation")
        #expect(sheet2.phase == .discarded)
        #expect(rig2.turns.resolved == [draft2.turnID!])
    }

    @Test("closing keeps the draft")
    func closingKeepsDraft() async throws {
        let (rig, draft, _) = try await Self.heldRig()
        rig.model.closeRecovery()
        #expect(rig.model.recovery == nil)
        #expect(rig.model.drafts.map(\.id) == [draft.id])
        #expect(rig.turns.resolved.isEmpty && rig.turns.deleted.isEmpty && rig.actions.isEmpty)
    }

    @Test("a draft resolved elsewhere is “This draft is no longer available”; opening by turn shows “Opening saved text…”")
    func noLongerAvailableAndOpening() async throws {
        let (rig, draft, sheet) = try await Self.heldRig()
        rig.turns.markResolved(draft.turnID!)
        sheet.refreshDraft()
        #expect(sheet.state.rendering == .empty)
        #expect(sheet.state.headline == "This draft is no longer available")
        #expect(sheet.state.actionTitle == "Back to Today")
        #expect(!sheet.canAct)

        let opening = RecoverySheetModel(turn: TurnID(), host: rig.model)
        #expect(opening.state.rendering == .loading)
        #expect(opening.state.headline == "Opening saved text…")
        opening.load()
        #expect(opening.state.headline == "This draft is no longer available")

        let none = RecoverySheetModel(draft: nil, host: rig.model)
        #expect(none.state == SectionState.empty(.recovery, hotkey: rig.model.hotkeyLabel), "the fixture's recovery empty")
        for state in [sheet.state, opening.state, none.state] { #expect(state.isWellFormed) }
    }

    @Test("a partial draft warns about duplicates (D07) and still resolves explicitly")
    func partialDraft() async throws {
        let entry = Rig.entry(Rig.record("Half of this landed.", app: "Slack", outcome: .partial(method: "keystroke")), .landed)
        let rig = Rig([entry])
        await rig.model.reloadHistory()
        let draft = try #require(rig.model.drafts.first)
        rig.model.presentRecovery(draft)
        let sheet = try #require(rig.model.recovery)
        #expect(sheet.banner?.recoveryID == .D07)
        #expect(sheet.subtitle == "Only part may have been inserted · held for Slack")
        sheet.copy()
        #expect(sheet.phase == .copied)
        #expect(rig.model.drafts.isEmpty, "a resolved partial leaves the top of Today")
        await rig.model.reloadHistory()
        #expect(rig.model.recent.first?.tag == .unconfirmed, "…and stays Unconfirmed in history")
    }
}

@Suite("Turn detail (S7b)")
@MainActor
struct TurnDetailS7bTests {
    typealias Rig = S7bRig

    static func detail(_ entry: TurnEntry, rig: Rig? = nil) async -> (Rig, TurnDetailModel) {
        let rig = rig ?? Rig([entry])
        await rig.model.reloadHistory()
        rig.model.openTurn(entry.id)
        let model = rig.model.detail!
        await model.reload()
        return (rig, model)
    }

    @Test("final text, uncertainty count, original transcript, destination and verified delivery")
    func content() async {
        let entry = Rig.entry(Rig.record("Can we meet with Mira on Friday?", raw: "um can we meet with mira on friday",
                                         spans: [17..<21], outcome: .delivered(verified: true, method: "ax")), .landed)
        let (_, model) = await Self.detail(entry)
        #expect(model.state.isContent)
        #expect(model.title == "Can we meet with Mira on…")
        #expect(model.subtitle.hasPrefix("Mail · "))
        #expect(model.subtitle.hasSuffix(" · 7 words"))
        #expect(model.displayedText == "Can we meet with Mira on Friday?")
        #expect(model.displayedSpans == [17..<21])
        #expect(model.uncertaintyLine == "1 word to review")
        #expect(model.hasOriginal)
        model.textView = .original
        #expect(model.displayedText == "um can we meet with mira on friday")
        #expect(model.displayedSpans.isEmpty, "marks belong to the final text")
        #expect(model.destinationLine == "Mail · Text area")
        #expect(model.deliveryDetail == "Inserted in Mail through Accessibility. Readback confirmed the text.")
        #expect(model.tag == .toReview(1))
        #expect(model.statusLine == "✓ Inserted in Mail")
        #expect(model.draft == nil)
    }

    @Test("delivery evidence names the method in words and says when readback could not confirm it")
    func deliveryEvidence() {
        func evidence(_ outcome: DeliveryOutcome?) -> String {
            TurnDetailModel.deliveryEvidence(Rig.record("x", outcome: outcome))
        }
        #expect(evidence(.delivered(verified: false, method: "paste"))
                == "Inserted in Mail by paste. Readback couldn’t confirm it — check the field before trying again.")
        #expect(evidence(.partial(method: "keystroke"))
                == "Only part may have been inserted in Mail by typing. Check the destination to avoid duplicate text.")
        #expect(evidence(.held(reason: "destination changed")) == "Your destination changed before insertion. Nothing was inserted.")
        #expect(evidence(.failed(reason: "every method threw")) == "Couldn’t insert your text. Your text is kept here.")
        for outcome in [DeliveryOutcome.delivered(verified: true, method: "ax"), .delivered(verified: true, method: "adapter")] {
            let text = evidence(outcome)
            #expect(!text.contains(" ax") && !text.contains("adapter)"), "no raw method token: \(text)")
        }
    }

    @Test("a held turn: held-tape note, Recovery row, and Review opens its recovery sheet")
    func heldTurn() async {
        let entry = Rig.entry(Rig.record("Text for Mail.", outcome: .held(reason: "destination changed")), .held)
        let (rig, model) = await Self.detail(entry)
        #expect(model.statusLine == "Your text stays held until you resolve it.")
        #expect(SpoolSurfacePolicy.appearance(on: .turnDetail)?.key == .held)
        #expect(SpoolSurfacePolicy.appearance(on: .recoverySheet)?.key == .held)
        #expect(model.draft?.turnID == entry.id)
        #expect(model.canReview)
        model.review()
        #expect(rig.model.recovery?.draft?.turnID == entry.id)
    }

    @Test("Review on an inserted turn lists its uncertain words; nothing to review hides Review")
    func reviewUncertainWords() async {
        let entry = Rig.entry(Rig.record("Call Mira and Joaquin", spans: [5..<9, 14..<21],
                                         outcome: .delivered(verified: true, method: "ax")), .landed)
        let (_, model) = await Self.detail(entry)
        #expect(model.uncertaintyLine == "2 words to review")
        model.review()
        #expect(model.reviewing)
        #expect(model.uncertainWords == ["Mira", "Joaquin"])

        let plain = Rig.entry(Rig.record("All clear", outcome: .delivered(verified: true, method: "ax")), .landed)
        let (_, plainModel) = await Self.detail(plain)
        #expect(!plainModel.canReview)
        #expect(plainModel.uncertaintyLine == "No words to review")
    }

    @Test("Copy is verified; Delete asks, then deletes the turn and its held copy and goes back")
    func copyAndDelete() async {
        let turn = TurnID()
        var record = Rig.record("Delete me", outcome: .held(reason: "destination changed"))
        record.turnID = turn
        let item = HeldItem(text: "Delete me", destination: "Mail", reason: "destination changed")
        let rig = Rig([Rig.entry(record, .held)], held: [item])
        rig.queue.turnByHeld[item.id] = turn
        let (_, model) = await Self.detail(Rig.entry(record, .held), rig: rig)

        rig.pasteboard.tampered = "changed"
        model.copy()
        #expect(model.notice?.recoveryID == .D08)
        rig.pasteboard.tampered = nil
        model.copy()
        #expect(model.notice == .copied)
        #expect(rig.model.drafts.count == 1, "copying a turn is not resolving its held draft")

        model.askDelete()
        #expect(model.confirmingDelete)
        #expect(rig.turns.deleted.isEmpty)
        model.confirmDelete()
        #expect(rig.turns.deleted == [turn])
        #expect(rig.actions.map { $0.1 } == [.discard], "its held copy goes too")
        #expect(rig.model.detail == nil, "back to Today")
    }

    @Test("renderings: “Opening saved text…”, the fixture's turn empty, S01 when unreadable, S03 when unsaved")
    func renderings() async {
        let rig = Rig()
        let missing = TurnDetailModel(turnID: TurnID(), host: rig.model)
        #expect(missing.state.rendering == .loading)
        #expect(missing.state.headline == "Opening saved text…")
        await missing.reload()
        #expect(missing.state == SectionState.empty(.turn, hotkey: rig.model.hotkeyLabel))
        #expect(missing.state.headline == "No saved text here")
        #expect(missing.state.actionTitle == "Open Today")

        rig.turns.failure = S7bTurns.Boom()
        let broken = TurnDetailModel(turnID: TurnID(), host: rig.model)
        await broken.reload()
        #expect(broken.state.rendering == .error)
        #expect(broken.state.recoveryID == .S01)

        let turn = TurnID()
        var record = Rig.record("unsaved", outcome: .delivered(verified: true, method: "ax"))
        record.turnID = turn
        let unsaved = Rig([Rig.entry(record, .landed, persisted: false)])
        unsaved.turns.failedSaves = [turn]
        let (_, model) = await Self.detail(Rig.entry(record, .landed), rig: unsaved)
        #expect(model.state.isContent, "the in-memory copy stays readable")
        #expect(model.banner?.recoveryID == .S03)
        #expect(model.banner?.actionTitle == "Copy text")
        #expect(model.retentionLabel == "Kept for this session only")
        for state in [missing.state, broken.state, model.state] { #expect(state.isWellFormed) }
    }
}

@Suite("Today's turn-store reader over TurnStore (S7b × S11)")
@MainActor
struct TodayTurnStoreReaderS7bTests {
    static func record(_ text: String) -> TurnRecord {
        TurnRecord(turnID: TurnID(), startedAt: Date(), destination: .init(bundleID: "com.apple.mail", appName: "Mail"),
                   rawText: text, finalText: text)
    }

    @Test("reads what the store keeps; an unreadable turn table is an error, never an empty history")
    func readsAndProbes() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        let reader = TodayTurnStoreReader(store: store, database: db)
        var landed = Self.record("landed words")
        landed.outcome = .delivered(verified: true, method: "ax")
        store.save(landed, stage: .landed)
        let held = Self.record("held words")
        store.save(held, stage: .held)
        store.flush()
        #expect(try reader.recentTurns(limit: 10).map(\.record.finalText).sorted() == ["held words", "landed words"])
        #expect(reader.recoverableTurns(limit: 10).map(\.id) == [held.turnID])
        #expect(reader.persistence == .keptUntilResolved)

        reader.markResolved(held.turnID)
        #expect(try reader.turnEntry(held.turnID)?.stage == .resolved)
        reader.recordInsertion(landed.turnID, outcome: .delivered(verified: false, method: "paste"))
        #expect(try reader.turnEntry(landed.turnID)?.record.outcome == .delivered(verified: false, method: "paste"))
        reader.delete(landed.turnID)
        store.flush()
        #expect(try reader.turnEntry(landed.turnID) == nil)

        try db.writer.write { try $0.execute(sql: "DROP TABLE \(TurnStore.table)") }
        #expect(throws: (any Error).self) { try reader.recentTurns(limit: 10) }
        #expect(throws: (any Error).self) { try reader.turnEntry(TurnID()) }
    }

    @Test("a save that fails is remembered (S03) and reads “Kept for this session only”")
    func saveFailure() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        let reader = TodayTurnStoreReader(store: store, database: db)
        try db.writer.write { try $0.execute(sql: "DROP TABLE \(TurnStore.table)") }
        let record = Self.record("words")
        store.save(record, stage: .held)
        store.flush()
        #expect(reader.saveFailed(record.turnID))
        let entry = try #require(store.entry(record.turnID))
        #expect(TodayRetention.of(entry, saveFailed: reader.saveFailed(record.turnID)) == .saveFailed)
        #expect(TodayRetention.saveFailed.label == "Kept for this session only")

        let off = TurnStore(database: nil)
        #expect(TodayTurnStoreReader(store: off, database: nil).persistence == .sessionOnly)
    }
}

@Suite("S7b copy held to the verified prototype")
@MainActor
struct TodayCopyS7bTests {
    static func prototype() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
    }

    @Test("the recovery sheet's, Today's and turn detail's sentences are the prototype's")
    func verbatim() throws {
        let html = try Self.prototype()
        for sentence in [RecoverySheetModel.nothingInsertedHeadline, RecoverySheetModel.nothingInsertedBody,
                         "Kept until resolved · closing this window keeps the draft.",
                         "If saving fails, this changes to “Kept for this session only”.",
                         TodayCopy.recentHeading, TodayCopy.destinationChangedNothingInserted,
                         TodayCopy.reviewText, TodayCopy.holdHintAfter, TodayCopy.tryDictation,
                         "Your text stays held until you resolve it.",
                         "1 word to review", "Final text", "Original transcript", "Open recovery", "Discard…",
                         "Insert here", "Copy text"] {
            #expect(html.contains(sentence), "not in design_v1.html: \(sentence)")
        }
        #expect(html.contains("Text waiting for Mail"))
        #expect(TodayCopy.textWaiting(for: "Mail") == "Text waiting for Mail")
        #expect(html.contains("Destination changed · held for Mail"))
        #expect(html.contains("Loading recent dictations…") && html.contains("Opening saved text…")
                && html.contains("This draft is no longer available"))
        #expect(TodayCopy.loadingRecent == "Loading recent dictations…")
        #expect(TodayCopy.openingSavedText == "Opening saved text…")
        #expect(RecoverySheetModel.noLongerAvailableHeadline == "This draft is no longer available")
    }
}
