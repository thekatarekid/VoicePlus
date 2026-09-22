import AppKit
import Carbon.HIToolbox
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S10 — VoiceOver announcements (start, stop, "final text ready · N words to review", the delivery
/// result; never a token) and keyboard behaviour (reading order of held / error actions, Escape
/// closes a popover before cancelling a turn, focus returns, no Escape taken outside a turn).
@Suite("S10 — VoiceOver announcements and keyboard")
struct AnnouncementKeyboardS10Tests {

    // MARK: - Announcement sequence through the real pill model

    /// A pill model with a recording announcement center.
    private func rig() -> (PillViewModel, PillAnnouncementCenter) {
        let model = PillViewModel()
        model.keyLabel = { "fn / 🌐" }
        model.destinationProvider = { "Mail" }
        let center = PillAnnouncementCenter(model: model, post: { _ in })
        return (model, center)
    }

    @Test("a hold turn is announced as start, stop, final text ready with its count, and the delivery result")
    func holdTurnSequence() {
        let (model, center) = rig()
        model.apply(.starting)
        model.apply(.listening(level: 0.2))
        for words in ["Can", "Can we", "Can we meet", "Can we meet with Mira", "Can we meet with Mira on Friday"] {
            model.apply(.previewing(text: words))
            model.apply(.listening(level: 0.6))
        }
        model.present(.finishing(elapsedWarning: false))
        model.present(.finalPreview(FinalPreviewInfo(text: "Can we meet with Mira on Friday?", uncertainCount: 1,
                                                     dwellRemaining: 1.8, destination: "Mail")))
        model.present(.inserting(text: "Can we meet with Mira on Friday?"))
        model.present(delivery: .delivered(verified: true, method: "keystroke"),
                      text: "Can we meet with Mira on Friday?", destination: "Mail")

        #expect(center.posted.map(\.kind) == [.start, .stop, .final, .delivery])
        #expect(center.posted.map(\.text) == [
            PillDeck.startingStatus,
            PillCopy.finishingHelper,
            "Final text ready · 1 word to review",
            "✓ Inserted in Mail · 1 word to review in the field",
        ])
        #expect(center.posted.map(\.spoken) == [
            "Starting microphone…",
            "Microphone closed, nothing inserted yet",
            "Final text ready, 1 word to review",
            "Inserted in Mail, 1 word to review in the field",
        ])
        #expect(center.posted.allSatisfy { $0.priority == .medium })
    }

    @Test("never per token: live words, level ticks, quiet and the timer say nothing")
    func neverPerToken() {
        let (model, center) = rig()
        model.apply(.starting)
        #expect(center.posted.count == 1)
        var words = ""
        for i in 0..<60 {
            words += (words.isEmpty ? "" : " ") + "word\(i)"
            model.apply(.previewing(text: words))
            model.apply(.listening(level: Float(i % 10) / 10))
        }
        model.present(.listeningQuiet)
        model.apply(.listening(level: 0.4))
        #expect(center.posted.count == 1, "only the start")
        #expect(center.posted.allSatisfy { !$0.text.contains("word") }, "no transcript is ever spoken")
    }

    @Test("a final text with every word confident says only that it is ready")
    func confidentFinal() {
        var announcer = PillAnnouncer()
        let info = FinalPreviewInfo(text: "See you soon.", dwellRemaining: 0.9, destination: "Mail")
        let line = announcer.next(.finalPreview(info), content: PillContent.make(.finalPreview(info), context: PillTurnContext()),
                                  captureOpen: false)
        #expect(line == PillAnnouncement(.final, "Final text ready"))
        let two = FinalPreviewInfo(text: "Mira and Meera", uncertainCount: 2, dwellRemaining: 1.8)
        #expect(announcer.next(.finalPreview(two), content: PillContent.make(.finalPreview(two), context: PillTurnContext()),
                               captureOpen: false)?.text == "Final text ready · 2 words to review")
        #expect(announcer.next(.finalPreview(two), content: PillContent.make(.finalPreview(two), context: PillTurnContext()),
                               captureOpen: false) == nil, "a paused or reviewed preview is not announced again")
    }

    @Test("every delivery result is said once; problems interrupt")
    func deliveryResults() {
        let context = PillTurnContext(destination: "Mail")
        let cases: [(PillState, String, PillAnnouncement.Priority)] = [
            (.landed(LandedPillInfo(text: "Hi", verified: true)), "✓ Inserted in Mail", .medium),
            (.landed(LandedPillInfo(text: "Hi", verified: false)),
             "⚠ Couldn’t confirm insertion · Check the field before trying again", .high),
            (.landedPartial(text: "Hi"), PillDeck.partialStatus + " · " + PillDeck.partialHelper, .high),
            (.held(HeldPillInfo(text: "Hi", destination: "Mail", reason: "")),
             "⚠ Destination changed · text held · Nothing was typed into the new field", .high),
            (.cancelled, [PillDeck.cancelledStatus, PillDeck.cancelledWords, PillDeck.cancelledHelper]
                .filter { !$0.isEmpty }.joined(separator: " · "), .medium),
        ]
        for (state, text, priority) in cases {
            var announcer = PillAnnouncer()
            let content = PillContent.make(state, context: context)
            let line = announcer.next(state, content: content, captureOpen: false)
            #expect(line?.kind == .delivery, "\(state.caseName)")
            #expect(line?.text == text, "\(state.caseName)")
            #expect(line?.priority == priority, "\(state.caseName)")
            #expect(announcer.next(state, content: content, captureOpen: false) == nil, "\(state.caseName): once")
        }
    }

    @Test("a latch session: one start, each segment's final and result, no false 'Microphone closed', then the stop")
    func latchSession() {
        let (model, center) = rig()
        model.latched = true
        model.present(.latched(elapsed: 0))
        for second in 1...8 { model.present(.latched(elapsed: TimeInterval(second))) }
        #expect(center.posted.map(\.kind) == [.start])
        #expect(center.posted.first?.text == PillDeck.latchedStatus)
        for segment in 1...2 {
            let text = "Segment \(segment) text."
            model.present(.finalPreview(FinalPreviewInfo(text: text, dwellRemaining: 0.9, destination: "Mail")))
            model.present(.inserting(text: text))
            model.present(delivery: .delivered(verified: true, method: "keystroke"), text: text, destination: "Mail")
            // The row's dwell ends; the next level tick under the open microphone brings the latched
            // row back (the pill may pass through hidden in between).
            model.retractDelivery(immediately: true)
            model.apply(.listening(level: 0.3))
            #expect(model.state.caseName == "latched")
        }
        #expect(center.posted.map(\.kind) == [.start, .final, .delivery, .final, .delivery],
                "each segment is heard, the latch is not re-announced")
        model.latched = false
        model.present(.finishing(elapsedWarning: false))
        #expect(center.posted.last == PillAnnouncement(.stop, PillCopy.finishingHelper))
    }

    @Test("a microphone warning is said once per warning, with priority")
    func warningOnce() {
        let (model, center) = rig()
        let quality = MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor)
        model.apply(.starting)
        model.apply(.warning(quality))
        model.apply(.warning(quality))
        model.apply(.listening(level: 0.3))
        #expect(center.posted.map(\.kind) == [.start, .notice])
        #expect(center.posted.last?.priority == .high)
        #expect(center.posted.last?.text.hasPrefix(PillDeck.warningStatus) == true)
    }

    @Test("speech drops status glyphs and reads the separator as a pause")
    func spokenForm() {
        #expect(PillSpeech.spoken("⚠ Destination changed · text held") == "Destination changed, text held")
        #expect(PillSpeech.spoken("✓ Inserted in Mail") == "Inserted in Mail")
        #expect(PillSpeech.spoken("⊘ VoicePlus is muted") == "VoicePlus is muted")
        #expect(PillSpeech.spoken("Listening") == "Listening")
    }

    @Test("the pill's label is the semantic state, never the live words or the ticking timer")
    func containerLabel() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let live = PillContent.make(.listening(level: 0.5),
                                    context: PillTurnContext(startedAt: start, now: start.addingTimeInterval(7),
                                                             liveText: "Can we meet with"))
        let label = PillSpeech.containerLabel(live)
        #expect(!label.contains("Can we meet"))
        #expect(!label.contains("0:07"))
        #expect(label.hasPrefix("Listening"))
        let later = PillContent.make(.listening(level: 0.1),
                                     context: PillTurnContext(startedAt: start, now: start.addingTimeInterval(9),
                                                              liveText: "Can we meet with Mira on"))
        #expect(PillSpeech.containerLabel(later) == label, "the label does not change while words stream")
        let final = PillContent.make(.finalPreview(FinalPreviewInfo(text: "Can we meet?", dwellRemaining: 0.9)),
                                     context: PillTurnContext(destination: "Mail"))
        #expect(PillSpeech.containerLabel(final).contains("Can we meet?"), "the final payload can be read")
    }

    @Test("artwork is decoration: hidden from accessibility wherever it is drawn")
    func artworkHidden() throws {
        // The drawings carry the prototype's aria-hidden / focusable=false.
        for key in SpoolStateKey.allCases {
            for drawing in [SpoolScene.frame(key, t: 0, still: true, drive: .capture(level: 0)).drawing,
                            SpoolScene.cameo(key).drawing] {
                #expect(drawing.attributes.contains(SpoolAttribute("aria-hidden", "true")), "\(key)")
                #expect(drawing.attributes.contains(SpoolAttribute("focusable", "false")), "\(key)")
            }
        }
        // Every view that draws the art hides it.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let hosts: [(file: String, marker: String)] = [
            ("App/UI/Spool/SpoolView.swift", "struct SpoolView: View"),
            ("App/UI/Components/SpoolCameo.swift", "struct SpoolCameo: View"),
            ("App/Settings/VoiceTestView.swift", "SpoolView(key: appearance.key"),
            ("App/UI/Accessibility/PillAccessibilityViews.swift", "struct PillLevelReadout: View"),
        ]
        for host in hosts {
            let source = try String(contentsOf: root.appendingPathComponent(host.file), encoding: .utf8)
            let from = try #require(source.range(of: host.marker), "\(host.file)")
            #expect(source[from.upperBound...].contains(".accessibilityHidden(true)"), "\(host.file)")
        }
    }

    // MARK: - Keyboard: reading order

    @Test("held and error actions are reached in reading order, the primary recovery first — as the design draws them")
    func actionReadingOrder() throws {
        let fixture = try DesignFixture.pill()
        let context = PillTurnContext(destination: "Mail", liveText: "Can we meet with Mira on Friday")
        let states: [(String, PillState)] = [
            ("held", .held(HeldPillInfo(text: "Can we meet?", destination: "Mail", reason: ""))),
            ("unconfirmed", .landed(LandedPillInfo(text: "Can we meet?", verified: false))),
            ("partial", .landedPartial(text: "Can we meet?")),
            ("unavailable", .unavailable(reason: "No speech model installed")),
            ("error", .error(message: "Something failed")),
            ("uncertain", .finalPreview(FinalPreviewInfo(text: "Can we meet with Mira?", uncertainCount: 1,
                                                         dwellRemaining: 1.8, manual: true))),
            ("warning", .warning(MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor))),
        ]
        for (key, state) in states {
            let content = PillContent.make(state, context: context)
            let chain = PillReadingOrder.focusChain(content)
            let expected = try #require(fixture[key], "\(key)")
            #expect(chain.map(\.label) == expected.map(\.label), "\(key): order as drawn")
            #expect(chain.map(\.action.rawValue) == expected.map(\.action), "\(key)")
            if let primary = chain.firstIndex(where: \.primary) {
                #expect(primary == 0, "\(key): the primary recovery comes first")
            }
            let priorities = PillReadingOrder.chainPriorities(content)
            #expect(zip(priorities, priorities.dropFirst()).allSatisfy { $0 > $1 }, "\(key): strictly in order")
        }
        let blocked = PillReadingOrder.focusChain(PillContent.blocked(keyLabel: "fn / 🌐"))
        let blockedExpected = try #require(fixture["blocked"])
        #expect(blocked.map(\.label) == blockedExpected.map(\.label))
    }

    @Test("rows are read top to bottom: status, words, chips, level, helper with Review all, then the actions")
    func regionOrder() {
        let order = PillReadingOrder.Region.allCases.map(PillReadingOrder.priority)
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 > $1 })
        #expect(PillReadingOrder.Region.allCases == [.status, .words, .chips, .levelReadout, .helper, .actions])
        for count in 1...4 {
            let row = (0..<count).map { PillReadingOrder.actionPriority(index: $0, count: count) }
            #expect(zip(row, row.dropFirst()).allSatisfy { $0 > $1 }, "left to right")
        }
        let final = PillContent.make(.finalPreview(FinalPreviewInfo(text: "long", dwellRemaining: 0, manual: true)),
                                     context: PillTurnContext())
        let chain = PillReadingOrder.focusChain(final, overflowLabel: "42 words · Review all")
        #expect(chain.map(\.label) == ["42 words · Review all", "Insert now", "Edit draft", "Cancel"])
        let priorities = PillReadingOrder.chainPriorities(final, overflowLabel: "42 words · Review all")
        #expect(zip(priorities, priorities.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("the Escape hint is not a stop: capture rows offer only their buttons")
    func escapeHintIsNotFocusable() {
        let latched = PillContent.make(.latched(elapsed: 4), context: PillTurnContext())
        #expect(latched.escapeHint)
        #expect(PillReadingOrder.focusChain(latched, overflowLabel: "3 words · Review all").map(\.label) == ["Finish dictation"])
    }

    // MARK: - Keyboard: Escape closes a popover before cancelling the turn

    private func escapeRig() -> (EscapeHotkey, EscapeLayerStack, Recorder) {
        let layers = EscapeLayerStack()
        let recorder = Recorder()
        let escape = EscapeHotkey(backend: EscapeKeyBackend { token in
            recorder.installs.append(token)
            return InstalledHotkeySource(setEnabled: { _ in }, invalidate: { recorder.invalidations += 1 })
        })
        escape.layers = layers
        escape.onEscape = { recorder.fired.append($0) }
        return (escape, layers, recorder)
    }

    @Test("Escape closes a popover shown over the turn first; the next press cancels the turn")
    func popoverFirst() {
        let (escape, layers, recorder) = escapeRig()
        escape.update(.finalPreview(FinalPreviewInfo(text: "Can we meet with Mira?", uncertainCount: 1, dwellRemaining: 1.8)))
        #expect(escape.isRegistered)
        let popover = NSObject()
        var closed = 0
        layers.push(ObjectIdentifier(popover)) { closed += 1 }

        escape.press()
        #expect(closed == 1, "the popover closed")
        #expect(recorder.fired.isEmpty, "the turn was not cancelled")
        #expect(escape.firedCount == 0 && escape.swallowedCount == 0, "the turn still has its Escape")
        #expect(layers.isEmpty)

        escape.press()
        #expect(recorder.fired == [.cancel])
    }

    @Test("nested popovers close newest first, one per press")
    func nestedLayers() {
        let (escape, layers, recorder) = escapeRig()
        escape.update(.listening(level: 0.3))
        var order: [String] = []
        let a = NSObject(), b = NSObject()
        layers.push(ObjectIdentifier(a)) { order.append("a") }
        layers.push(ObjectIdentifier(b)) { order.append("b") }
        escape.press()
        escape.press()
        #expect(order == ["b", "a"])
        #expect(recorder.fired.isEmpty)
        escape.press()
        #expect(recorder.fired == [.cancel])
    }

    @Test("NSPopovers register and unregister themselves as Escape layers")
    @MainActor
    func popoverNotifications() {
        let layers = EscapeLayerStack()
        let center = NotificationCenter()
        layers.observePopovers(center: center)
        layers.observePopovers(center: center)   // idempotent
        let popover = NSPopover()
        center.post(name: NSPopover.willShowNotification, object: popover)
        #expect(layers.topID == ObjectIdentifier(popover))
        #expect(layers.layers.count == 1)
        center.post(name: NSPopover.didCloseNotification, object: popover)
        #expect(layers.isEmpty)
    }

    @Test("a popover closed by the user leaves the stack; Escape then goes to the turn")
    func closedByUser() {
        let (escape, layers, recorder) = escapeRig()
        escape.update(.starting)
        let popover = NSObject()
        layers.push(ObjectIdentifier(popover)) {}
        layers.remove(ObjectIdentifier(popover))
        escape.press()
        #expect(recorder.fired == [.cancel])
    }

    @Test("no Escape is taken outside a turn — not even with a popover or a menu open")
    func noSwallowingOutsideTheTurn() {
        let (escape, layers, recorder) = escapeRig()
        let outside: [PillState] = [
            .hidden, .idle, .ready(hint: "Hold fn / 🌐 to dictate"), .muted, .unavailable(reason: "x"),
            .error(message: "Text was not typed"), .held(HeldPillInfo(text: "a", destination: "Mail", reason: "moved")),
            .landed(LandedPillInfo(text: "a", verified: true)), .landed(LandedPillInfo(text: "a", verified: false)),
            .landedPartial(text: "a"), .cancelled, .correcting, .editing, .undoAvailable,
            .meeting(MeetingPillInfo(phase: .recording, elapsed: 5)), .preview(text: "Muted — mic stays closed"), .landing,
        ]
        let popover = NSObject()
        layers.push(ObjectIdentifier(popover)) {}
        for state in outside {
            escape.update(state)
            #expect(!escape.isRegistered, "\(state.caseName): Escape belongs to the frontmost app")
            escape.press()
        }
        #expect(recorder.installs.isEmpty)
        #expect(recorder.fired.isEmpty)
        #expect(layers.layers.count == 1, "a press that never reached VoicePlus closed nothing")

        // During a turn, an open menu hands Escape back too (it closes the menu).
        escape.update(.listening(level: 0.2))
        #expect(escape.isRegistered)
        escape.setMenuOpen(true)
        #expect(!escape.isRegistered)
        escape.setMenuOpen(false)
        #expect(escape.isRegistered)
        escape.update(.hidden)
        #expect(!escape.isRegistered, "released when the turn ends")
    }

    // MARK: - Keyboard: focus returns

    @Test("focus returns to where it was opened from, innermost first")
    func focusReturns() {
        let focus = FocusReturn()
        focus.opened(from: "today.turn.a")
        focus.opened(from: "word.mira")
        #expect(focus.closed() == "word.mira")
        #expect(focus.restoreTarget == "word.mira")
        focus.restored("word.mira")
        #expect(focus.restoreTarget == nil)
        #expect(focus.closed() == "today.turn.a")
        focus.restored("somewhere.else")
        #expect(focus.restoreTarget == "today.turn.a", "only the target itself clears the request")
        #expect(focus.closed() == nil)
    }

    @Test("closing a turn detail sends focus back to its Today row")
    func turnDetailBackToRow() {
        let id = TurnID()
        #expect(TodayFocus.row(id) == TodayFocus.row(id))
        #expect(TodayFocus.row(id) != TodayFocus.row(TurnID()))
        let focus = FocusReturn()
        focus.restore(TodayFocus.row(id))
        #expect(focus.restoreTarget == TodayFocus.row(id))
    }
}

private final class Recorder {
    var installs: [Int] = []
    var invalidations = 0
    var fired: [EscapeResolution] = []
}

/// `design_copy.json` › `pill` › `<state>` › `buttons`.
private enum DesignFixture {
    struct Button: Decodable {
        var label: String
        var action: String
        var primary: Bool
    }

    private struct Row: Decodable { var buttons: [Button]? }
    private struct File: Decodable { var pill: [String: Row] }

    struct Missing: Error {}

    static func pill() throws -> [String: [Button]] {
        guard let dir = AppPaths.fixturesDirectory() else { throw Missing() }
        let url = dir.appendingPathComponent("design/design_copy.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return file.pill.compactMapValues(\.buttons)
    }
}
