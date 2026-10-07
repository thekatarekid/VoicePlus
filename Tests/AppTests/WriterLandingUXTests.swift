import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer — the landing UX (VoicePlus_ContextWriter_Plan.md §4: "no deadline, one landing").
/// The writer runs inside the lander before anything is typed. A probe stage in the lander's pipeline
/// plays the writer: it posts `WriterLandingEvents` on a private channel, advances the turn's manual
/// clock and (when it "polishes") rewrites the words, so the production controller, lander, injector
/// and `MockSystemAccess` field run end to end. Nothing here touches a real app or the shared channel.
@Suite("Context Writer: landing UX (one landing, the wait is the animation)")
struct WriterLandingUXTests {
    typealias ManualClock = TurnControllerTests.ManualClock
    static let original = "Dear Mira, "
    static let heard = "we should fan out sub variance today"
    static let written = "we should fan out subagents today"

    static func words(_ text: String) -> [TranscriptSpan] {
        [TranscriptSpan(text: text, confidence: 0.95, audioRange: 0...1, provenance: [.asr], stability: .final)]
    }

    // MARK: - Harness

    final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    /// Plays the writer inside the lander's pipeline (the real writer stage runs there too).
    final class WriterProbe: PipelineStage, @unchecked Sendable {
        let id: StageID = "test.writerProbe"
        var script: (([TranscriptSpan]) -> [TranscriptSpan])?
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            (script?(spans) ?? spans).map { span in
                var out = span
                out.provenance.append(id)
                return out
            }
        }
    }

    struct Pair: Equatable {
        let heard: String
        let written: String
        let app: String?
    }

    struct Harness {
        let system: MockSystemAccess
        let lander: UtteranceLander
        let controller: TurnController
        let clock = ManualClock()
        let channel = WriterLandingEvents()
        let probe = WriterProbe()
        let notes = Recorder<PillWriterNote?>()
        let states = Recorder<PillState>()
        let landed = Recorder<LandingResult>()
        let notices = Recorder<RecoveryID>()
        let undone = Recorder<Pair>()
        let polish = Recorder<TurnID>()

        init(dwell: PreviewDwell = .immediate) {
            system = MockSystemAccess(frontmost: TurnControllerTests.textEdit)
            system.field = MockSystemAccess.Field(role: "AXTextArea", value: WriterLandingUXTests.original)
            let injector = TextInjector(system: system)
            lander = UtteranceLander(pipeline: PipelineRunner(stages: [probe]), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
            let reader = FieldContextReader(system: system)
            lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
            controller = TurnController(lander: lander, focusGuard: injector.focusGuard, store: TurnStore(database: nil),
                                        clock: clock,
                                        targets: FocusGuardTargetReader(focusGuard: injector.focusGuard, display: { 7 }),
                                        dwell: { dwell })
            controller.ui = { $0() }
            controller.snapshotQueue = { $0() }
            controller.hookQueue = { $0() }
            controller.useReplaceRange(over: system)
            lander.gate = controller
            controller.observeWriterEvents(channel)
            let (notes, states, landed, notices, undone, polish) = (notes, states, landed, notices, undone, polish)
            controller.onWriter = { notes.append($0) }
            controller.onPresent = { states.append($0) }
            controller.onLanded = { landed.append($0) }
            controller.onNotice = { notices.append($0.id) }
            controller.onUndoCorrection = { undone.append(Pair(heard: $0, written: $1, app: $2)) }
            controller.onPolishRequest = { polish.append($0) }
        }

        /// The writer as the probe plays it: `started`, `ms` of model time on the turn's clock, then
        /// `finished` with `outcome` and (for a polish) the words rewritten heard → written.
        func writer(after ms: Double, outcome: String = "accepted", from heard: String? = nil, to written: String? = nil) {
            let landing = UUID()
            let (channel, clock) = (channel, clock)
            probe.script = { spans in
                channel.post(.started(landingID: landing, backend: "cloud"))
                clock.advance(ms / 1000)
                guard let heard, let written else {
                    channel.post(.finished(landingID: landing, outcome: outcome, changed: [], ms: ms))
                    return spans
                }
                let text = spans.map(\.text).joined(separator: " ").replacingOccurrences(of: heard, with: written)
                let start = (text as NSString).range(of: written).location
                channel.post(.finished(landingID: landing, outcome: outcome,
                                       changed: [WriterChangedWord(heard: heard, written: written,
                                                                   range: start..<(start + written.utf16.count))],
                                       ms: ms))
                return spans.enumerated().map { index, span in
                    var out = span
                    out.text = index == 0 ? text : ""
                    return out
                }.filter { !$0.text.isEmpty }
            }
        }

        /// Key down → capture → key up → final pass (the writer runs inside it) → typed at once.
        func dictate(_ text: String = WriterLandingUXTests.heard) async -> TurnID? {
            guard case .began(let id) = controller.keyDown() else { return nil }
            controller.captureOpened(id)
            controller.notePartial(text)
            guard controller.keyUp(id) else { return nil }
            await controller.finalize(id, spans: WriterLandingUXTests.words(text))
            return id
        }

        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<3000 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }

        var field: String { system.field.value }
        var landedText: String? { landed.all.first?.text }
        var stateNames: [String] { states.all.map(\.caseName) }
    }

    /// What the pill draws for the finishing face with `note` (the controller's latest).
    static func finishingFace(_ note: PillWriterNote?, live: String = heard) -> PillContent {
        var c = PillTurnContext(destination: "TextEdit", liveText: live, captureOpen: false)
        c.writer = note
        return PillContent.make(.finishing(elapsedWarning: false), context: c)
    }

    // MARK: - 1. Fast writer: no "Writing…" (no flicker)

    @Test("a writer that finishes within 150 ms never shows Writing…; the text lands once, as today")
    func fastWriterNeverShowsWriting() async throws {
        let h = Harness()
        h.writer(after: 100, outcome: "unchanged")
        let id = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })
        #expect(h.notes.all.isEmpty, "nothing to say: no Writing face, no note")
        #expect(!h.notes.all.contains(.writing))
        #expect(h.stateNames == ["starting", "finishing", "finalPreview", "inserting"])
        #expect(Self.finishingFace(nil).status == "Inserting in TextEdit…")
        #expect(h.field == Self.original + (h.landedText ?? "∅"))
        #expect(h.system.postCount == 1, "one landing")
        #expect(!h.controller.isCorrectionUndoAvailable)
        _ = id

        // 149 ms is still fast; a polish that fast shows no face either, only the landed row's note.
        let quick = Harness()
        quick.writer(after: 149, from: "sub variance", to: "subagents")
        _ = try #require(await quick.dictate())
        #expect(await quick.wait { quick.landed.count == 1 })
        #expect(!quick.notes.all.contains(.writing))
        #expect(quick.notes.all.first??.phase == .polished)
    }

    // MARK: - 2. Slow writer: "Writing…", then the one landing

    @Test("a slow writer turns the finishing face into Writing… (calm pose, shimmering line); then it lands once")
    func slowWriterShowsWritingThenLands() async throws {
        let h = Harness()
        let face = Recorder<PillContent>()
        let landing = UUID()
        let (channel, clock, notes) = (h.channel, h.clock, h.notes)
        h.probe.script = { spans in
            channel.post(.started(landingID: landing, backend: "local"))
            clock.advance(0.149)
            face.append(Self.finishingFace(notes.all.last ?? nil))   // not yet
            clock.advance(0.002)
            face.append(Self.finishingFace(notes.all.last ?? nil))   // now
            clock.advance(0.6)
            channel.post(.finished(landingID: landing, outcome: "unchanged", changed: [], ms: 751))
            face.append(Self.finishingFace(notes.all.last ?? nil))   // gone again
            return spans
        }
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })

        let shown = face.all
        try #require(shown.count == 3)
        #expect(shown[0].status == "Inserting in TextEdit…", "under 150 ms: the usual face")
        #expect(shown[1].status == WriterCopy.writingStatus)
        #expect(shown[1].status == "Writing…")
        #expect(shown[1].statusShimmers, "the line shimmers (still under Reduce Motion)")
        #expect(shown[1].spoolKey == "finishing", "the calm finishing pose")
        #expect(shown[1].designKey == "inserting", "the same face family (N22): no resize")
        #expect(shown[1].words == .live(Self.heard), "the heard words stay; nothing new is typed")
        #expect(shown[1].helper == PillCopy.finishingHelper)
        #expect(shown[1].buttons.isEmpty)
        #expect(shown[2].status == "Inserting in TextEdit…", "the writer finished: Writing… goes")
        #expect(h.notes.all == [.writing, nil])

        #expect(h.stateNames == ["starting", "finishing", "finalPreview", "inserting"])
        #expect(h.system.postCount == 1, "one landing, after the writer")
        #expect(h.field == Self.original + (h.landedText ?? "∅"))
    }

    @Test("the writer's events only ever act on the turn being landed")
    func eventsBindToTheTurnBeingLanded() async throws {
        let h = Harness()
        // Nothing is being landed: an event names no turn and is ignored.
        h.channel.post(.started(landingID: UUID(), backend: "cloud"))
        h.clock.advance(1)
        #expect(h.notes.all.isEmpty)
        #expect(h.controller.landingTurn == nil)

        // The id of the turn itself binds exactly.
        let seen = Recorder<TurnID?>()
        let (channel, clock, controller) = (h.channel, h.clock, h.controller)
        h.probe.script = { spans in
            let turn = controller.landingTurn
            seen.append(turn)
            if let turn {
                channel.post(.started(landingID: turn.rawValue, backend: "cloud"))
                clock.advance(0.3)
                channel.post(.finished(landingID: turn.rawValue, outcome: "timeout", changed: [], ms: 2500))
            }
            return spans
        }
        let id = try #require(await h.dictate())
        #expect(seen.all == [id], "landingTurn names the turn whose final pass is being formatted")
        #expect(h.notes.all == [.writing, PillWriterNote(phase: .unpolished)])
    }

    @Test("a run bound by timing to the wrong landing gives way to the turn's own landing events")
    func ownLandingEventsWinOverATimingBinding() async throws {
        let h = Harness(dwell: .manual)   // the turn stays in its preview, so it can be reconciled
        let segment = UUID(), own = UUID()
        let channel = h.channel
        h.probe.script = { spans in
            // A hands-free piece formatting alongside: its events find this turn first.
            channel.post(.started(landingID: segment, backend: "cloud"))
            channel.post(.finished(landingID: segment, outcome: "timeout", changed: [], ms: 2500))
            // The turn's own landing: unclaimed, because the turn already holds a run.
            channel.post(.started(landingID: own, backend: "cloud"))
            channel.post(.finished(landingID: own, outcome: "accepted",
                                   changed: [WriterChangedWord(heard: "sub variance", written: "subagents")], ms: 300))
            return spans
        }
        let id = try #require(await h.dictate())
        #expect(h.notes.all == [PillWriterNote(phase: .unpolished)])
        h.controller.reconcileWriter(id, landing: own)   // what `finalize` does with the landing's id
        let rebound = try #require(h.notes.all.last.flatMap { $0 })
        #expect(rebound.phase == .polished)
        #expect(rebound.changes.map(\.written) == ["subagents"])
        h.controller.reconcileWriter(id, landing: own)
        #expect(h.notes.count == 2, "once")
        h.controller.reconcileWriter(id, landing: UUID())
        #expect(h.notes.count == 2, "no events for that landing: the binding stands")
    }

    // MARK: - 3. Changed words: "Polished N words" + Undo that restores the heard words

    @Test("a polished landing says Polished 1 word; Undo puts the heard words back in place and calls the hook")
    @MainActor
    func polishedLandingUndo() async throws {
        let h = Harness()
        h.writer(after: 400, from: "sub variance", to: "subagents")
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })
        let text = try #require(h.landedText)
        #expect(text.contains("subagents"), "the writer's text is what landed")
        #expect(h.field == Self.original + text)
        #expect(h.controller.isCorrectionUndoAvailable)
        let note = try #require(h.notes.all.last.flatMap { $0 })
        #expect(note.phase == .polished && note.undoable)
        #expect(note.changes.map(\.heard) == ["sub variance"])

        // The pill: the landed row carries the note and the Undo action.
        let pill = PillViewModel()
        pill.now = { Date(timeIntervalSince1970: 1_000) }
        pill.present(.finishing(elapsedWarning: false))
        pill.setWriter(note)
        let delivery = try #require(h.landed.all.first?.delivery)
        pill.present(delivery: delivery, text: text, destination: "TextEdit")
        guard case .landed(let info) = pill.state else { Issue.record("not a landed row: \(pill.state)"); return }
        #expect(info.writer == .polished(count: 1, undoable: true))
        let row = pill.content()
        #expect(row.status == "✓ Inserted in TextEdit")
        #expect(row.helper == "Polished 1 word")
        #expect(row.buttons == [PillButton("Undo", .undo)])
        #expect(PillDwell.rule(for: pill.state) == .minimum(PillDwell.undoWindow), "long enough to act on")
        #expect(PillContent.make(.landed(LandedPillInfo(text: text, verified: true, writer: .polished(count: 2, undoable: true))),
                                 context: PillTurnContext(destination: "TextEdit")).helper == "Polished 2 words")

        // Undo, as the pill's button routes it.
        #expect(TurnWiring.route(.undo, shown: pill.state, to: h.controller, finishLatch: nil))
        let restored = text.replacingOccurrences(of: "subagents", with: "sub variance")
        #expect(h.field == Self.original + restored, "exactly the heard words, in place")
        #expect(h.undone.all == [Pair(heard: "sub variance", written: "subagents", app: "com.apple.TextEdit")])
        #expect(!h.controller.isCorrectionUndoAvailable)
        #expect(h.notices.all.isEmpty)
        #expect(!TurnWiring.route(.undo, shown: pill.state, to: h.controller, finishLatch: nil), "once")
    }

    @Test("Undo of a polish is range-safe: a field the user changed is left alone (D10) and nothing is learned")
    func polishedUndoIsRangeSafe() async throws {
        let h = Harness()
        h.writer(after: 300, from: "sub variance", to: "subagents")
        _ = try #require(await h.dictate())
        #expect(await h.wait { h.controller.isCorrectionUndoAvailable })
        h.system.field.value = "Dear Mira, we should fan out something else today"
        #expect(!h.controller.undoCorrection())
        #expect(h.field == "Dear Mira, we should fan out something else today", "untouched")
        #expect(h.notices.all.last == .D10)
        #expect(h.undone.all.isEmpty)

        // The offer also ends with the next dictation.
        let h2 = Harness()
        h2.writer(after: 300, from: "sub variance", to: "subagents")
        _ = try #require(await h2.dictate())
        #expect(await h2.wait { h2.controller.isCorrectionUndoAvailable })
        h2.probe.script = nil
        _ = h2.controller.keyDown()
        #expect(!h2.controller.isCorrectionUndoAvailable)
    }

    @Test("several changed words are restored in one range-checked replacement")
    func severalWordsRestoredTogether() throws {
        let system = MockSystemAccess(frontmost: TurnControllerTests.textEdit)
        let landed = "ship the Q3 deck to Priya"
        system.field = MockSystemAccess.Field(role: "AXTextArea", value: "Hi. " + landed)
        let changes = [WriterChangedWord(heard: "queue three", written: "Q3", range: 9..<11),
                       WriterChangedWord(heard: "pria", written: "Priya", range: 20..<25)]
        let located = WriterChangeLocator.locate(changes, in: landed)
        #expect(located.map(\.range) == [9..<11, 20..<25])
        #expect(WriterChangeLocator.restoringHeard(located, in: landed) == "ship the queue three deck to pria")
        // The replacement `TurnController.restoreHeard` builds: first change to last, heard words in.
        let editor = ReplaceRangeEditor(system: system)
        let expected = try #require(MarkWords.slice(landed, 9..<25))
        let shifted = located.map { LocatedWriterChange(range: ($0.range.lowerBound - 9)..<($0.range.upperBound - 9), heard: $0.heard, written: $0.written) }
        let outcome = editor.replace(ReplaceRangeRequest(range: (4 + 9)..<(4 + 25), expected: expected,
                                                         replacement: WriterChangeLocator.restoringHeard(shifted, in: expected)))
        #expect(outcome == .replaced(verified: true))
        #expect(system.field.value == "Hi. ship the queue three deck to pria")
    }

    @Test("changed words are found by their written words, never trusted by range alone")
    func locatorTrustsOnlyMatchingRanges() {
        let text = "Fan out subagents, then subagents again."
        // Exact range.
        let exact = WriterChangeLocator.locate([WriterChangedWord(heard: "sub agents", written: "subagents", range: 8..<17)], in: text)
        #expect(exact.map(\.range) == [8..<17])
        // A range shifted by formatting (a leading space, a capital): the nearest whole-word occurrence.
        let shifted = WriterChangeLocator.locate([WriterChangedWord(heard: "sub agents", written: "subagents", range: 23..<32)], in: text)
        #expect(shifted.map(\.range) == [24..<33])
        // Two changes never claim the same words.
        let both = WriterChangeLocator.locate([WriterChangedWord(heard: "a", written: "subagents", range: 8..<17),
                                               WriterChangedWord(heard: "b", written: "subagents", range: 8..<17)], in: text)
        #expect(both.map(\.range) == [8..<17, 24..<33])
        // Not in the text (another landing): dropped. Inside a longer word: not a match.
        #expect(WriterChangeLocator.locate([WriterChangedWord(heard: "x", written: "Priya", range: 0..<5)], in: text).isEmpty)
        #expect(WriterChangeLocator.locate([WriterChangedWord(heard: "x", written: "agents", range: nil)], in: text).isEmpty)
        // Only real changes make a note.
        #expect(PillWriterNote.outcome(of: .finished(landingID: UUID(), outcome: "accepted",
                                                     changed: [WriterChangedWord(heard: "same", written: "same")], ms: 1)) == nil)
        #expect(PillWriterNote.outcome(of: .finished(landingID: UUID(), outcome: "rejected:preamble", changed: [], ms: 1)) == nil)
        #expect(PillWriterNote.outcome(of: .finished(landingID: UUID(), outcome: "failed:http", changed: [], ms: 1))?.phase == .unpolished)
    }

    // MARK: - 4. Unpolished: "Not polished" + Polish (wave 3), never a silent swap

    @Test("a writer that timed out leaves the heard words, a Not polished note and a Polish action")
    @MainActor
    func unpolishedLandingNote() async throws {
        let h = Harness()
        h.writer(after: 2500, outcome: "timeout")
        let id = try #require(await h.dictate())
        #expect(await h.wait { h.landed.count == 1 })
        let text = try #require(h.landedText)
        #expect(text.contains("sub variance"), "the rules text landed: nothing swapped")
        #expect(h.field == Self.original + text)
        #expect(h.system.postCount == 1)
        #expect(h.notes.all == [.writing, PillWriterNote(phase: .unpolished)])
        #expect(!h.controller.isCorrectionUndoAvailable)

        let pill = PillViewModel()
        pill.now = { Date(timeIntervalSince1970: 1_000) }
        pill.present(.finishing(elapsedWarning: false))
        pill.setWriter(PillWriterNote(phase: .unpolished))
        pill.present(delivery: .delivered(verified: true, method: "ax"), text: text, destination: "TextEdit")
        let row = pill.content()
        #expect(row.status == "✓ Inserted in TextEdit")
        #expect(row.helper == "Not polished")
        #expect(row.buttons == [PillButton("Polish", .polish)])
        #expect(row.tone == .normal, "a note, not a warning")
        #expect(PillDwell.rule(for: pill.state) == .minimum(PillDwell.transientNotice), "timed, never sticky")
        #expect(PillActionRoute.effect(for: .polish, shown: pill.state, text: text) == .none, "the turn's, not the root's")

        #expect(TurnWiring.route(.polish, shown: pill.state, to: h.controller, finishLatch: nil))
        #expect(h.polish.all == [id], "the wave-3 hook gets the turn")
        #expect(h.field == Self.original + text, "Polish swaps nothing today")

        // An unconfirmed landing keeps its own warning: no writer note on a ⚠ row.
        let warned = PillViewModel()
        warned.setWriter(PillWriterNote(phase: .unpolished))
        let state = warned.withWriterNote(.landed(LandedPillInfo(text: text, verified: false)))
        guard case .landed(let info) = state else { Issue.record("not landed"); return }
        #expect(info.writer == nil)
    }

    // MARK: - 5. Shimmer and Reduce Motion

    @Test("changed words shimmer for ~3 s; under Reduce Motion a still tint instead; then plain ink")
    @MainActor
    func shimmerAndReduceMotion() throws {
        typealias S = CorrectedMarkStyle
        // Normal motion: a sweeping band for 3 s, then settled.
        guard case .shimmer = S.appearance(elapsed: 0.5, reduceMotion: false) else { Issue.record("no shimmer"); return }
        #expect(S.appearance(elapsed: 2.9, reduceMotion: false) != .tint)
        #expect(S.appearance(elapsed: 3.0, reduceMotion: false) == .plain)
        // Reduce Motion: no shimmer at any moment — the tint alone, for the same 3 s.
        for t in stride(from: 0.0, to: 3.0, by: 0.1) {
            #expect(S.appearance(elapsed: t, reduceMotion: true) == .tint, "t = \(t)")
        }
        #expect(S.appearance(elapsed: 3.0, reduceMotion: true) == .plain)
        // The band enters and leaves the word: every sweep starts and ends on the plain tint.
        #expect(S.highlight(phase: 0, position: 0) == 0)
        #expect(S.highlight(phase: 1, position: 1) == 0)
        #expect(S.highlight(phase: 0.5, position: 0.5) == 1)
        #expect(S.color(.tint, position: 0.5, base: Tokens.Pill.ink) == Tokens.Pill.primary)
        #expect(S.color(.plain, position: 0.5, base: Tokens.Pill.ink) == Tokens.Pill.ink)
        // The tint is legible on the pill, and distinct from the uncertainty mark's colour.
        #expect(Tokens.Pill.Token.primary.value.contrastRatio(against: Tokens.Pill.Token.background.value) >= 7)
        #expect(Tokens.Pill.Token.primary.value != Tokens.Pill.Token.uncertainty.value)
        #expect(WordMarkKind.allCases == [.uncertain, .corrected])

        // The pill: the changed words are marked on the final text, clocked from their first frame.
        let t0 = Date(timeIntervalSince1970: 5_000)
        let pill = PillViewModel()
        pill.now = { t0 }
        pill.present(.finishing(elapsedWarning: false))
        pill.setWriter(PillWriterNote(phase: .polished, changes: [WriterChangedWord(heard: "sub variance", written: "subagents", range: 18..<27)]))
        let text = "We should fan out subagents today"
        pill.present(.finalPreview(FinalPreviewInfo(text: text, dwellRemaining: 0)))
        let marks = pill.correctedMarks(for: .final(text))
        #expect(marks.kind == .corrected)
        #expect(marks.ranges == [18..<27])
        #expect(marks.shownAt == t0)
        #expect(marks.appearance(at: t0.addingTimeInterval(1), reduceMotion: true) == .tint)
        #expect(marks.appearance(at: t0.addingTimeInterval(4), reduceMotion: true) == .plain)
        #expect(pill.correctedMarks(for: .live(text)).isEmpty, "never on live words")
        #expect(pill.marks(for: .final(text)).marks.isEmpty, "a corrected word is not an uncertain one")

        // The Writing line's shimmer is decoration only; under Reduce Motion `PillBody` draws it still
        // (`statusShimmers && !motion.reduced`), like the Spool's still finishing pose.
        #expect(MotionPolicy(system: true, app: false).reduced)
        #expect(MotionPolicy(system: true, app: false).drawsStillSpool)
    }

    // MARK: - 6. VoiceOver

    @Test("VoiceOver hears Writing, then Polished N words or Not polished with the landed row")
    @MainActor
    func announcements() throws {
        let pill = PillViewModel()
        pill.now = { Date(timeIntervalSince1970: 9_000) }
        let posted = Recorder<PillAnnouncement>()
        let center = PillAnnouncementCenter(model: pill, post: { posted.append($0) })
        pill.apply(.starting)
        pill.present(.listening(level: 0.3))
        pill.present(.finishing(elapsedWarning: false))
        pill.setWriter(.writing)
        pill.present(.finishing(elapsedWarning: true))   // the 2 s line: Writing is not said twice
        pill.setWriter(PillWriterNote(phase: .polished, changes: [WriterChangedWord(heard: "pria", written: "Priya"),
                                                                  WriterChangedWord(heard: "queue three", written: "Q3")],
                                      undoable: true))
        pill.present(delivery: .delivered(verified: true, method: "ax"), text: "ship the Q3 deck to Priya", destination: "Mail")
        let spoken = posted.all.map(\.spoken)
        #expect(spoken.filter { $0 == "Writing" }.count == 1)
        #expect(spoken.last == "Inserted in Mail, Polished 2 words")
        _ = center

        let other = PillViewModel()
        let heard = Recorder<PillAnnouncement>()
        let center2 = PillAnnouncementCenter(model: other, post: { heard.append($0) })
        other.apply(.starting)
        other.present(.listening(level: 0.3))
        other.present(.finishing(elapsedWarning: false))
        other.setWriter(PillWriterNote(phase: .unpolished))
        other.present(delivery: .delivered(verified: true, method: "ax"), text: "ship it", destination: "Mail")
        #expect(heard.all.last?.spoken == "Inserted in Mail, Not polished")
        #expect(!heard.all.map(\.spoken).contains("Writing"), "a fast writer is never announced")
        _ = center2
    }
}
