import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer — the landed row's note and Undo belong to one turn, Undo is offered only where it
/// can work, and it is all or nothing (review fixes on the landing UX). Everything runs through the
/// production controller, lander, injector and a `MockSystemAccess` field (`WriterLandingUXTests.Harness`).
@Suite("Context Writer: landing note ownership and Undo")
struct WriterLandingUndoTests {
    typealias Harness = WriterLandingUXTests.Harness
    typealias Pair = WriterLandingUXTests.Pair
    static let original = WriterLandingUXTests.original
    static let second = "fan out subagents again"

    /// A field whose app rewrites it right after an AX selected-text write (a web editor
    /// re-normalising its DOM, or the user typing): each queued step runs after one write.
    final class ScriptedWrites: MockSystemAccess, @unchecked Sendable {
        var afterSelectedTextWrite: [(MockSystemAccess) -> Void] = []
        override func setFocusedSelectedText(_ text: String) throws {
            try super.setFocusedSelectedText(text)
            if !afterSelectedTextWrite.isEmpty { afterSelectedTextWrite.removeFirst()(self) }
        }
    }

    static func rangeOf(_ text: String, _ written: String) -> Range<Int>? {
        let found = (text as NSString).range(of: written)
        return found.location == NSNotFound ? nil : found.location..<(found.location + found.length)
    }

    static func notes(in events: ArraySlice<WriterLandingUXTests.Event>) -> [PillWriterNote?] {
        events.compactMap { event -> PillWriterNote?? in
            if case .note(let note) = event { return .some(note) }
            return nil
        }
    }

    /// Replays what the controller sent, in order, into a real pill (as `TurnWiring` and the delivery
    /// driver do live).
    @MainActor
    static func replay(_ events: [WriterLandingUXTests.Event]) -> PillViewModel {
        let pill = PillViewModel()
        pill.now = { Date(timeIntervalSince1970: 2_000) }
        for event in events {
            switch event {
            case .state(let state): pill.present(state)
            case .note(let note): pill.setWriter(note)
            case .landed(let result):
                if let delivery = result.delivery { pill.present(delivery: delivery, text: result.text, destination: "TextEdit") }
            }
        }
        return pill
    }

    // MARK: - 1. The note and Undo belong to the turn that owns the pill

    @Test("an older turn's Polished note and Undo never reach a newer turn's pill, even one that already stopped capturing")
    @MainActor
    func olderTurnsNoteStaysOffTheNewerTurn() async throws {
        let h = Harness()
        h.polish(after: 300, [("sub variance", "subagents")])
        let newer = WriterLandingUXTests.Recorder<TurnID>()
        let controller = h.controller
        // N23 — A is being typed; B goes down and (a short press) up before A's write returns.
        h.onNextState.set { state in
            guard case .inserting = state else { return false }
            guard case .began(let id) = controller.keyDown() else { return true }
            controller.captureOpened(id)
            controller.notePartial(Self.second)
            _ = controller.keyUp(id)
            newer.append(id)
            return true
        }
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })
        let b = try #require(newer.all.first)
        #expect(h.controller.stage(of: b) == .finishing, "B stopped capturing before A's write returned")
        #expect(h.field.contains("subagents"), "A's polish landed")
        #expect(!h.controller.isCorrectionUndoAvailable, "no Undo for A: B owns the pill")

        // B lands; its writer has nothing to say. B's words hold A's written word.
        h.writer(after: 50, outcome: "unchanged")
        await h.controller.finalize(b, spans: WriterLandingUXTests.words(Self.second))
        #expect(await h.wait { h.landed.count == 2 })

        let events = h.log.all
        let bStart = try #require(events.lastIndex { if case .state(.starting) = $0 { return true } else { return false } })
        #expect(!Self.notes(in: events[bStart...]).contains { $0?.phase == .polished }, "nothing of A's after B's key down")
        #expect(Self.notes(in: events[..<bStart]).last == .some(nil), "B's key down cleared A's note")

        let pill = Self.replay(events)
        guard case .landed(let info) = pill.state else { Issue.record("B did not land: \(pill.state)"); return }
        #expect(info.text.contains("subagents"))
        #expect(info.writer == nil, "B's row carries no Polished note of A's")
        #expect(!pill.content().buttons.contains(PillButton("Undo", .undo)))
        #expect(pill.correctedMarks(for: .final(info.text)).isEmpty, "A's word does not shimmer in B's text")

        let field = h.field
        #expect(!TurnWiring.route(.undo, shown: pill.state, to: h.controller, finishLatch: nil))
        #expect(!h.controller.undoCorrection())
        #expect(h.field == field, "A's words are never reverted from B's row")
        #expect(h.undone.all.isEmpty)
    }

    // MARK: - 2. Notes reach the pill in the order they were decided

    @Test("Writing… decided at exactly 150 ms never lands on top of the note decided right after it")
    @MainActor
    func writingFaceAndNoteKeepTheirOrder() async throws {
        // Control: on one thread the face goes up at the 150 ms mark, then the note replaces it.
        let control = Harness()
        let (channel0, clock0) = (control.channel, control.clock)
        let landing0 = UUID()
        control.probe.script = { spans in
            channel0.post(.started(landingID: landing0, backend: "cloud"))
            clock0.advance(control.controller.writerFaceDelay)
            channel0.post(.finished(landingID: landing0, outcome: "timeout", changed: [], ms: 150))
            return spans
        }
        _ = try #require(await control.dictate())
        #expect(control.notes.all == [.writing, PillWriterNote(phase: .unpolished)])

        // The race: the face is decided under the lock at 150 ms; before its hop to the pill, the
        // writer's `finished` (another thread) takes the lock, decides the note and hops first.
        let h = Harness()
        let interleave = WriterLandingUXTests.Slot<() -> Void>()
        h.controller.ui = { work in
            interleave.take()?()
            work()
        }
        let (channel, clock, delay) = (h.channel, h.clock, h.controller.writerFaceDelay)
        let landing = UUID()
        h.probe.script = { spans in
            channel.post(.started(landingID: landing, backend: "cloud"))
            interleave.set { channel.post(.finished(landingID: landing, outcome: "timeout", changed: [], ms: 150)) }
            clock.advance(delay)
            return spans
        }
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })
        #expect(h.notes.all == [PillWriterNote(phase: .unpolished)], "the older Writing… is dropped, not drawn last")
        #expect(WriterLandingUXTests.finishingFace(h.notes.all.last ?? nil).status != WriterCopy.writingStatus)

        let pill = Self.replay(h.log.all)
        #expect(pill.content().helper == WriterCopy.notPolished, "the landed row says Not polished")
    }

    // MARK: - 3. Undo only where it can work

    @Test("no Undo in a terminal (by its field or by the resolver) or a field AX cannot write; the note stays")
    func noUndoWhereARangeReplaceCannotWork() async throws {
        let terminalField = Harness()
        terminalField.system.field.hints = ["Terminal input"]   // VS Code's integrated terminal
        let resolverTerminal = Harness()
        resolverTerminal.controller.surfaceForTurn = { SurfaceResolution(kind: .terminal, confidence: 1, isWebArea: false, signals: []) }
        let readOnlyAX = Harness()
        readOnlyAX.system.axWriteWorks = false   // typed by keystrokes; AX cannot replace a range here
        for (name, h) in [("terminal field", terminalField), ("resolver terminal", resolverTerminal), ("AX not settable", readOnlyAX)] {
            h.polish(after: 300, [("sub variance", "subagents")])
            _ = try #require(await h.dictate())
            #expect(await h.wait { h.landed.count == 1 }, "\(name)")
            #expect(h.field.contains("subagents"), "\(name): the polish landed")
            #expect(h.landed.all.first?.delivery?.writeReachedDestination == true, "\(name)")
            #expect(!h.controller.isCorrectionUndoAvailable, "\(name)")
            let note = try #require(h.notes.all.last.flatMap { $0 })
            #expect(note.phase == .polished && !note.undoable, "\(name)")
            #expect(note.landed == .polished(count: 1, undoable: false), "\(name)")
            #expect(note.landed?.button == nil, "\(name): Polished 1 word, no Undo button")
        }
        // The check itself.
        let settable = FocusedElementInfo(role: "AXTextArea", value: "x", selectedRange: 1..<1, isValueSettable: true,
                                          isSelectedTextSettable: true)
        #expect(TurnController.takesRangeReplace(settable, surface: nil))
        #expect(!TurnController.takesRangeReplace(settable, surface: SurfaceResolution(kind: .terminal, confidence: 1,
                                                                                         isWebArea: false, signals: [])))
        var xterm = settable
        xterm.hints = ["xterm"]
        #expect(!TurnController.takesRangeReplace(xterm, surface: nil))
        var frozen = settable
        frozen.isValueSettable = false
        frozen.isSelectedTextSettable = false
        #expect(!TurnController.takesRangeReplace(frozen, surface: nil))
    }

    @Test("no Undo without a trusted range: a change with no range, or one whose range holds other words")
    @MainActor
    func noUndoWithoutATrustedRange() async throws {
        // No range (a group whose mark mapping failed): the note shows and the word shimmers, no Undo.
        let h = Harness()
        h.polish(after: 300, [("cotari", "Kothari")], range: { _, _ in nil })
        _ = try #require(await h.dictate("ask cotari about the deck"))
        #expect(await h.wait { h.landed.count == 1 })
        #expect(h.field.contains("Kothari"))
        #expect(!h.controller.isCorrectionUndoAvailable)
        let pill = Self.replay(h.log.all)
        #expect(pill.content().helper == "Polished 1 word")
        #expect(!pill.content().buttons.contains(PillButton("Undo", .undo)))
        guard case .landed(let info) = pill.state else { Issue.record("not landed"); return }
        #expect(pill.correctedMarks(for: .final(info.text)).ranges.count == 1, "the one Kothari shimmers")

        // A range that holds other words: no Undo either.
        let shifted = Harness()
        shifted.polish(after: 300, [("cotari", "Kothari")], range: { _, written in 0..<written.utf16.count })
        _ = try #require(await shifted.dictate("ask cotari about the deck"))
        #expect(await shifted.wait { shifted.landed.count == 1 })
        #expect(!shifted.controller.isCorrectionUndoAvailable)

        // The same word earlier, unchanged: never claimed for the shimmer, never undone.
        let text = "there is there car"
        let change = WriterChangedWord(heard: "their", written: "there", range: nil)
        #expect(WriterChangeLocator.locate([change], in: text).isEmpty, "ambiguous: not drawn on a guess")
        #expect(WriterChangeLocator.locateTrusted([change], in: text) == nil)
        #expect(WriterChangeLocator.appears([change], in: text), "the note still belongs to this text")
        let pinned = WriterChangedWord(heard: "their", written: "there", range: 9..<14)
        #expect(WriterChangeLocator.locateTrusted([pinned], in: text)?.map(\.range) == [9..<14])
        #expect(WriterChangeLocator.locateTrusted([WriterChangedWord(heard: "their", written: "there", range: 8..<13)], in: text) == nil)
        #expect(WriterChangeLocator.locateTrusted([pinned, WriterChangedWord(heard: "x", written: "re", range: 12..<14)], in: text) == nil,
                "overlapping changes")
    }

    // MARK: - 4. All or nothing, end to end

    @Test("several changed words are restored through the controller in one range-checked replacement; history follows")
    func severalWordsRestoredTogether() async throws {
        let h = Harness()
        h.polish(after: 300, [("queue three", "Q3"), ("pria", "Priya")])
        let id = try #require(await h.dictate("ship the queue three deck to pria"))
        #expect(await h.wait { h.controller.isCorrectionUndoAvailable })
        let text = try #require(h.landedText)
        #expect(text == "ship the Q3 deck to Priya")
        let note = try #require(h.notes.all.last.flatMap { $0 })
        #expect(note.undoable && note.changes.count == 2)

        let writes = h.system.journal.filter { $0 == "ax.setSelectedText" }.count
        let shown = PillState.landed(LandedPillInfo(text: text, verified: true, writer: .polished(count: 2, undoable: true)))
        #expect(TurnWiring.route(.undo, shown: shown, to: h.controller, finishLatch: nil))
        #expect(h.field == Self.original + "ship the queue three deck to pria")
        #expect(h.system.journal.filter { $0 == "ax.setSelectedText" }.count == writes + 1, "one replacement")
        #expect(h.undone.all == [Pair(heard: "queue three", written: "Q3", app: "com.apple.TextEdit"),
                                 Pair(heard: "pria", written: "Priya", app: "com.apple.TextEdit")])
        h.controller.store.flush()
        #expect(h.controller.store.record(id)?.finalText == "ship the queue three deck to pria", "history shows the field")
        #expect(h.lines.all.isEmpty)
    }

    @Test("web content: the per-word path restores every word, or rolls back and reports; the learner gets only what stands")
    func perWordUndoIsAllOrNothing() async throws {
        let heard = "ship the queue three deck\nto pria"
        let written = "ship the Q3 deck\nto Priya"
        func landed(_ system: ScriptedWrites) async throws -> (Harness, TurnID) {
            system.inWebArea = true
            let h = Harness(system: system)
            h.polish(after: 300, [("queue three", "Q3"), ("pria", "Priya")])
            let id = try #require(await h.dictate(heard))
            #expect(await h.wait { h.landed.count == 1 })
            #expect(h.landedText == written)
            #expect(h.field == Self.original + written)
            #expect(h.controller.isCorrectionUndoAvailable)
            return (h, id)
        }

        // Every word: the whole range spans a line break (not newline-safe here), so one per word.
        let ok = ScriptedWrites(frontmost: TurnControllerTests.textEdit)
        let (h, id) = try await landed(ok)
        let before = ok.journal.filter { $0 == "ax.setSelectedText" }.count
        #expect(h.controller.undoCorrection())
        #expect(h.field == Self.original + heard)
        #expect(ok.journal.filter { $0 == "ax.setSelectedText" }.count == before + 2, "one write per word")
        #expect(h.undone.all.map(\.heard) == ["queue three", "pria"])
        h.controller.store.flush()
        #expect(h.controller.store.record(id)?.finalText == heard)

        // The second word changed after the first was put back: the first is rolled back, nothing learned.
        let edited = ScriptedWrites(frontmost: TurnControllerTests.textEdit)
        let (h2, id2) = try await landed(edited)
        edited.afterSelectedTextWrite = [{ $0.field.value = $0.field.value.replacingOccurrences(of: "Q3", with: "Q4") }]
        #expect(!h2.controller.undoCorrection())
        #expect(h2.field == Self.original + "ship the Q4 deck\nto Priya", "Priya is back; the edit is kept")
        #expect(h2.undone.all.isEmpty)
        #expect(h2.lines.all == [WriterCopy.undoTextChanged])
        #expect(h2.notices.all.isEmpty, "never D10")
        h2.controller.store.flush()
        #expect(h2.controller.store.record(id2)?.finalText == written)
        #expect(!h2.controller.isCorrectionUndoAvailable)

        // AX stops writing after the first word: the rollback cannot run either, so that word stands
        // as heard, and only that pair is learned (and recorded).
        let stuck = ScriptedWrites(frontmost: TurnControllerTests.textEdit)
        let (h3, id3) = try await landed(stuck)
        stuck.afterSelectedTextWrite = [{ $0.axWriteWorks = false }]
        #expect(!h3.controller.undoCorrection())
        #expect(h3.field == Self.original + "ship the Q3 deck\nto pria")
        #expect(h3.undone.all == [Pair(heard: "pria", written: "Priya", app: "com.apple.TextEdit")])
        #expect(h3.lines.all == [WriterCopy.undoPartial])
        h3.controller.store.flush()
        #expect(h3.controller.store.record(id3)?.finalText == "ship the Q3 deck\nto pria")
    }

    @Test("a field AX cannot write at Undo time: nothing changes and the note says so (not the text-changed one)")
    func unavailableHasItsOwnNote() async throws {
        let h = Harness()
        h.polish(after: 300, [("sub variance", "subagents")])
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.controller.isCorrectionUndoAvailable })
        let field = h.field
        h.system.axWriteWorks = false
        #expect(!h.controller.undoCorrection())
        #expect(h.field == field)
        #expect(h.lines.all == [WriterCopy.undoUnavailable])
        #expect(h.notices.all.isEmpty)
        #expect(h.undone.all.isEmpty)
    }

    // MARK: - 5. The record after Undo

    @Test("the record's text and uncertain spans follow the restored words")
    func recordFollowsTheField() throws {
        let stored = "ship the Q3 deck to Priya"
        let changes = [LocatedWriterChange(range: 9..<11, heard: "queue three", written: "Q3"),
                       LocatedWriterChange(range: 20..<25, heard: "pria", written: "Priya")]
        let next = try #require(WriterUndoRecord.restored(finalText: stored, spans: [9..<11, 12..<16, 20..<25, 10..<16],
                                                          landed: stored, changes: changes))
        #expect(next.text == "ship the queue three deck to pria")
        #expect(next.spans == [9..<20, 21..<25, 29..<33, 9..<25])
        #expect(next.spans.map { MarkWords.slice(next.text, $0) } == ["queue three", "deck", "pria", "queue three deck"])

        // The record holds the landed text with continuation whitespace around it.
        let padded = try #require(WriterUndoRecord.restored(finalText: " " + stored, spans: [21..<26], landed: stored,
                                                            changes: [changes[1]]))
        #expect(padded.text == " ship the Q3 deck to pria")
        #expect(padded.spans == [21..<25])
        // Only what is in the record: a record that no longer holds the written words is left alone.
        #expect(WriterUndoRecord.restored(finalText: "something else", spans: [], landed: stored, changes: changes) == nil)
        #expect(WriterUndoRecord.restored(finalText: stored, spans: [], landed: stored,
                                          changes: [LocatedWriterChange(range: 0..<4, heard: "x", written: "Priya")]) == nil)
    }
}

extension WriterLandingUXTests.Harness {
    /// The writer as the probe plays it: `started`, `ms` on the turn's clock, then `finished` having
    /// rewritten every heard → written, each change reported at `range` (default: where its written
    /// words are in the final text, as `WriterWiring.changedWords` reports them).
    func polish(after ms: Double, _ rewrites: [(heard: String, written: String)],
                range: @escaping (_ text: String, _ written: String) -> Range<Int>? = WriterLandingUndoTests.rangeOf) {
        let landing = UUID()
        let (channel, clock) = (channel, clock)
        probe.script = { spans in
            channel.post(.started(landingID: landing, backend: "cloud"))
            clock.advance(ms / 1000)
            var text = spans.map(\.text).joined(separator: " ")
            for rewrite in rewrites { text = text.replacingOccurrences(of: rewrite.heard, with: rewrite.written) }
            let changed = rewrites.map { WriterChangedWord(heard: $0.heard, written: $0.written, range: range(text, $0.written)) }
            channel.post(.finished(landingID: landing, outcome: "accepted", changed: changed, ms: ms))
            guard var first = spans.first else { return spans }
            first.text = text
            return [first]
        }
    }
}
