import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// S3 — the turn controller (design_v1 §5, §12): key-down snapshot → finishing → one immutable final
/// payload → preview for its dwell → revalidate → insert once. Driven with a manual clock over the
/// production lander and `TextInjector` on `MockSystemAccess`; nothing here touches a real app.
@Suite("Turn controller: preview before insert (S3)")
struct TurnControllerTests {
    static let textEdit = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")
    static let mail = FocusSnapshot(pid: 200, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-2")
    static let original = "Dear Mira, "

    static func words(_ text: String, confidence: Float = 0.95) -> [TranscriptSpan] {
        [TranscriptSpan(text: text, confidence: confidence, audioRange: 0...1, provenance: [.asr], stability: .final)]
    }

    // MARK: - Harness

    /// The turn's commit clock, advanced by hand. Timers fire in due order, outside any lock.
    final class ManualClock: TurnClock, @unchecked Sendable {
        private struct Item {
            let due: Date
            let order: Int
            let timer: TurnTimer
            let work: () -> Void
        }
        private let lock = NSLock()
        private var current = Date()
        private var items: [Item] = []
        private var counter = 0

        var now: Date { lock.withLock { current } }

        func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> TurnTimer {
            let timer = TurnTimer()
            lock.withLock {
                counter += 1
                items.append(Item(due: current.addingTimeInterval(max(0, seconds)), order: counter, timer: timer, work: work))
            }
            return timer
        }

        func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while true {
                let work = lock.withLock { () -> (() -> Void)? in
                    items.removeAll { $0.timer.isCancelled }
                    guard let index = items.indices.filter({ items[$0].due <= target })
                        .min(by: { (items[$0].due, items[$0].order) < (items[$1].due, items[$1].order) }) else { return nil }
                    let item = items.remove(at: index)
                    current = max(current, item.due)
                    return item.work
                }
                guard let work else { break }
                work()
            }
            lock.withLock { current = max(current, target) }
        }
    }

    /// Everything the controller told the outside world, in order.
    final class Events: @unchecked Sendable {
        enum Event: Equatable {
            case present(String)
            case retract
            case notice(RecoveryID)
            case landed
            case cancelCapture
        }
        private let lock = NSLock()
        private var log: [Event] = []
        private var _states: [PillState] = []
        private var _landed: [LandingResult] = []
        private var _ended: [(TurnID, TurnStage)] = []
        private var _offers: [FinishingOffer?] = []
        private var _spans: [[TranscriptSpan]] = []

        var events: [Event] { lock.withLock { log } }
        var states: [PillState] { lock.withLock { _states } }
        var landed: [LandingResult] { lock.withLock { _landed } }
        var ended: [(TurnID, TurnStage)] { lock.withLock { _ended } }
        var offers: [FinishingOffer?] { lock.withLock { _offers } }
        var finalSpans: [[TranscriptSpan]] { lock.withLock { _spans } }
        var notices: [RecoveryID] { events.compactMap { if case .notice(let id) = $0 { return id } else { return nil } } }
        var stateNames: [String] { states.map(\.caseName) }

        func attach(to c: TurnController) {
            c.onPresent = { [self] state in lock.withLock { _states.append(state); log.append(.present(state.caseName)) } }
            c.onRetract = { [self] in lock.withLock { log.append(.retract) } }
            c.onNotice = { [self] entry in lock.withLock { log.append(.notice(entry.id)) } }
            c.onLanded = { [self] result in lock.withLock { _landed.append(result); log.append(.landed) } }
            c.onCancelCapture = { [self] in lock.withLock { log.append(.cancelCapture) } }
            c.onTurnEnded = { [self] id, stage in lock.withLock { _ended.append((id, stage)) } }
            c.onOffer = { [self] _, offer in lock.withLock { _offers.append(offer) } }
            c.onFinalSpans = { [self] spans, _ in lock.withLock { _spans.append(spans) } }
        }
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    struct Harness {
        let system: MockSystemAccess
        let injector: TextInjector
        let focusGuard: FocusGuard
        let lander: UtteranceLander
        let store: TurnStore
        let clock: ManualClock
        let controller: TurnController
        let events: Events
        let dwell: Box<PreviewDwell>

        init(value: String = TurnControllerTests.original, dwell: PreviewDwell = .standard) {
            system = MockSystemAccess(frontmost: TurnControllerTests.textEdit)
            system.field = MockSystemAccess.Field(role: "AXTextArea", value: value)
            injector = TextInjector(system: system)
            focusGuard = injector.focusGuard
            lander = UtteranceLander(pipeline: PipelineRunner(stages: []), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
            let reader = FieldContextReader(system: system)
            lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
            store = TurnStore(database: nil)
            clock = ManualClock()
            events = Events()
            let setting = Box(dwell)
            self.dwell = setting
            controller = TurnController(lander: lander, focusGuard: focusGuard, store: store, clock: clock,
                                        targets: FocusGuardTargetReader(focusGuard: focusGuard, display: { 7 }),
                                        dwell: { setting.value })
            controller.ui = { $0() }
            controller.snapshotQueue = { $0() }
            controller.useReplaceRange(over: system)
            lander.gate = controller
            events.attach(to: controller)
        }

        /// Key down → capture open → key up → the engine's final pass. Returns once the payload is
        /// on screen (or queued for the gate).
        func holdToPreview(_ spans: [TranscriptSpan], partial: String? = nil) async -> TurnID? {
            guard case .began(let id) = controller.keyDown() else { return nil }
            controller.captureOpened(id)
            if let partial { controller.notePartial(partial) }
            guard controller.keyUp(id) else { return nil }
            await controller.finalize(id, spans: spans)
            return id
        }

        /// Polls (real time) until `condition` holds; the gate's write runs on its own task.
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<3000 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }

        var field: String { system.field.value }
    }

    // MARK: - Dwell

    @Test("the final payload is previewed and nothing is written until 600 ms after its first rendered frame")
    func dwellFromRenderedFrame() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        #expect(h.controller.stage(of: id) == .finalPreview)
        let info = try #require(h.controller.previewInfo)
        #expect(info.dwellRemaining == 0.6)
        #expect(info.destination == "TextEdit", "the key-down snapshot names the destination")
        #expect(!info.text.isEmpty)
        #expect(h.events.finalSpans.count == 1, "the pill gets the payload's spans with the preview")

        // Backend completion alone does not start the dwell (design §12).
        h.clock.advance(0.5)
        #expect(h.system.postCount == 0)
        h.controller.finalRendered(id)
        h.clock.advance(0.599)
        #expect(h.controller.stage(of: id) == .finalPreview)
        #expect(h.system.postCount == 0, "nothing is written during the dwell")
        #expect(h.field == Self.original)

        h.clock.advance(0.002)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == Self.original + info.text, "inserted text is exactly the previewed payload")
        #expect(h.system.postCount == 1, "inserted once")
        #expect(h.events.landed.first?.delivery == .delivered(verified: true, method: "ax"))
        #expect(h.events.stateNames == ["starting", "finishing", "finalPreview", "inserting"])
        #expect(h.store.entry(id)?.stage == .landed)
    }

    @Test("a pill that never acknowledges the final frame cannot strand the payload")
    func renderAckTimeout() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.clock.advance(h.controller.renderAckTimeout)
        #expect(h.store.entry(id)?.record.capture.finalRendered != nil, "the dwell started at the timeout")
        #expect(h.system.postCount == 0)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("hover freezes the dwell; leaving resumes it with the time that was left")
    func hoverPauses() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.controller.finalRendered(id)
        h.clock.advance(0.5)
        h.controller.pauseDwell(.hover)
        h.controller.pauseDwell(.focus)
        #expect(h.controller.previewInfo?.paused == true)
        guard case .finalPreview(let shown)? = h.events.states.last else { Issue.record("no preview"); return }
        #expect(shown.paused, "the pill is told the dwell is frozen")
        h.clock.advance(30)
        #expect(h.system.postCount == 0, "paused: nothing is written however long the pointer stays")
        h.controller.resumeDwell(.hover)
        h.clock.advance(30)
        #expect(h.system.postCount == 0, "focus still holds it")
        h.controller.resumeDwell(.focus)
        #expect(h.controller.previewInfo?.paused == false)
        h.clock.advance(0.149)
        #expect(h.system.postCount == 0)
        h.clock.advance(0.002)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.system.postCount == 1)
    }

    @Test("a low-confidence word keeps the fixed 600 ms dwell and is flagged, never forced")
    func lowConfidenceExtends() async throws {
        let h = Harness()
        let spans = Self.words("please sign the") + Self.words("contract", confidence: 0.3)
        let id = try #require(await h.holdToPreview(spans))
        let info = try #require(h.controller.previewInfo)
        #expect(info.dwellRemaining == 0.6)
        #expect(info.uncertainCount == 1)
        #expect(info.needsReview)
        #expect(info.status == "Ready for TextEdit · 1 word to review")
        let record = try #require(h.store.entry(id)?.record)
        let range = try #require(record.uncertainSpans.first)
        #expect((record.finalText as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)) == "contract")

        h.controller.finalRendered(id)
        h.clock.advance(0.599)
        #expect(h.system.postCount == 0)
        h.clock.advance(0.002)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == Self.original + info.text)
    }

    @Test("the dwell setting: 600 ms and 1200 ms", arguments: [(PreviewDwell.short, 0.6), (PreviewDwell.long, 1.2)])
    func dwellSettings(_ setting: PreviewDwell, _ seconds: TimeInterval) async throws {
        let h = Harness(dwell: setting)
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        #expect(h.controller.previewInfo?.dwellRemaining == seconds)
        h.controller.finalRendered(id)
        h.clock.advance(seconds - 0.001)
        #expect(h.system.postCount == 0)
        h.clock.advance(0.002)
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("manual review inserts only on the Insert action")
    func manualReview() async throws {
        let h = Harness(dwell: .manual)
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        let info = try #require(h.controller.previewInfo)
        #expect(info.manual)
        h.controller.finalRendered(id)
        h.clock.advance(120)
        #expect(h.system.postCount == 0, "manual review never inserts on a timer")
        #expect(h.controller.stage(of: id) == .finalPreview)
        // The pill's "Insert text" button (`PillDeck.manualPreviewButtons`) is the turn's.
        #expect(TurnWiring.route(.commit, shown: .finalPreview(info), to: h.controller, finishLatch: nil))
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == Self.original + info.text)
        #expect(h.system.postCount == 1)
    }

    // MARK: - Revalidation

    enum Change: String, CaseIterable {
        case typed, caretMoved, otherApp, passwordField
    }

    @Test("the destination changed during the preview: held with D01 copy, nothing typed", arguments: Change.allCases)
    func revalidationFailureHolds(_ change: Change) async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        let info = try #require(h.controller.previewInfo)
        h.controller.finalRendered(id)
        switch change {
        case .typed: h.system.field.value = Self.original + "x"
        case .caretMoved: h.system.field.selection = 0..<0
        case .otherApp: h.system.frontmost = Self.mail
        case .passwordField: h.system.field = .secure()
        }
        let before = h.system.field.value
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })

        #expect(h.system.postCount == 0, "a changed cursor is never followed")
        #expect(h.system.field.value == before)
        let result = try #require(h.events.landed.first)
        let delivery = try #require(result.delivery)
        #expect(delivery == .held(reason: DeliveryReason.destinationChanged))
        let entry = try #require(RecoveryCatalog.entry(for: delivery))
        #expect(entry.id == .D01)
        #expect(entry.headline == "Destination changed — text held")
        #expect(h.focusGuard.heldText(turn: id)?.text == info.text, "the payload is kept, turn attached")
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.store.entry(id)?.record.writeAttempted == false)
        #expect(h.store.entry(id)?.evidence == .held)
    }

    @Test("Insert here re-targets a held turn and its record follows")
    func insertHereUpdatesRecord() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.controller.finalRendered(id)
        h.system.frontmost = Self.mail
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
        let item = try #require(h.focusGuard.heldText(turn: id))
        #expect(h.focusGuard.insertHere(item.id)?.succeeded == true)
        #expect(h.store.entry(id)?.stage == .landed)
        #expect(h.store.entry(id)?.record.outcome == .delivered(verified: true, method: "ax"))
    }

    @Test("our own previous landing (a latch segment) does not count as the field changing")
    func ownLandingIsNotAChange() async throws {
        let h = Harness()
        let first = Task { await h.lander.land(Self.words("first part"), startedAt: Date(), focus: Self.textEdit) }
        #expect(await h.wait { h.controller.previewInfo != nil })
        let second = Task { await h.lander.land(Self.words("second part"), startedAt: Date(), focus: Self.textEdit) }
        #expect(await h.wait { h.store.recent().count == 2 })
        let firstText = try #require(h.controller.previewInfo?.text)
        h.controller.finalRendered(text: firstText)
        h.clock.advance(0.9)
        let one = await first.value
        #expect(one.landed)
        #expect(await h.wait { h.controller.previewInfo != nil })
        let secondText = try #require(h.controller.previewInfo?.text)
        h.controller.finalRendered(text: secondText)
        h.clock.advance(0.9)
        let two = await second.value
        #expect(two.landed, "the second segment's snapshot predates the first landing; that landing is ours")
        #expect(h.field == Self.original + firstText + secondText)
    }

    // MARK: - Stale callbacks, duplicates, K04

    @Test("a final pass for a turn cancelled during capture is dropped by TurnID")
    func staleFinalAfterCancel() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.escape() == .cancel)
        #expect(!h.controller.keyUp(id))
        await h.controller.finalize(id, spans: Self.words("late words"))
        h.clock.advance(5)
        #expect(h.controller.previewInfo == nil)
        #expect(h.system.postCount == 0)
        #expect(h.events.landed.isEmpty)
        #expect(h.store.entry(id)?.stage == .cancelled)
    }

    @Test("after 10 s, 'Use available text' takes the live words; the late final pass is dropped")
    func useAvailableText() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.notePartial("hello from the")
        #expect(h.controller.keyUp(id))
        h.clock.advance(2)
        #expect(h.events.states.last == .finishing(elapsedWarning: true), "2 s: Still finishing your text")
        h.clock.advance(8)
        #expect(h.events.offers == [.useAvailableText])
        #expect(h.controller.finishingOffer == .useAvailableText)

        h.controller.useAvailableText()
        #expect(await h.wait { h.controller.previewInfo != nil })
        let info = try #require(h.controller.previewInfo)
        #expect(info.text.contains("hello from the"))
        await h.controller.finalize(id, spans: Self.words("hello from the other side"))
        #expect(h.controller.previewInfo?.text == info.text, "the late result does not replace the payload")
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == Self.original + info.text)
        #expect(h.system.postCount == 1)
    }

    @Test("after 10 s with no words the offer is Cancel, and Cancel inserts nothing")
    func cancelOffer() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        h.clock.advance(10)
        #expect(h.events.offers == [.cancel])
        #expect(TurnWiring.route(.cancel, shown: .finishing(elapsedWarning: true), to: h.controller, finishLatch: nil))
        await h.controller.finalize(id, spans: Self.words("too late"))
        #expect(h.system.postCount == 0)
        #expect(h.store.entry(id)?.stage == .cancelled)
        #expect(h.events.events.contains(.cancelCapture))
    }

    @Test("key repeat and a duplicate key-up create no second turn and no second insert")
    func duplicates() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        #expect(h.controller.keyDown() == .repeated(id), "key repeat")
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        #expect(!h.controller.keyUp(id), "duplicate key-up")
        await h.controller.finalize(id, spans: Self.words("hello there"))
        await h.controller.finalize(id, spans: Self.words("hello there"))
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.store.recent().count == 1, "one turn, one record")
        #expect(h.system.postCount == 1)

        // The lander's one insert, keyed: the same turn and revision twice posts once.
        var again = try #require(h.events.landed.first)
        again.injection = nil
        let key = TurnCommitKey(turnID: TurnID(), revision: 1)
        let first = await h.lander.inject(payload: again, commit: key)
        let second = await h.lander.inject(payload: again, commit: key)
        #expect(!first.duplicateCommit && first.landed)
        #expect(second.duplicateCommit, "a second commit with the same key is refused")
        #expect(h.system.postCount == 2, "the turn's insert and the first keyed one; the duplicate posted nothing")
    }

    @Test("a press while the previous turn is finishing is refused with K04 and steals nothing")
    func busyPress() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        #expect(h.controller.keyDown() == .busy(id))
        #expect(h.events.notices == [.K04])
        #expect(RecoveryCatalog.entry(.K04).headline == "Finishing your previous dictation")
        #expect(h.controller.stage(of: id) == .finishing, "the current turn keeps going")
        h.clock.advance(RecoveryCatalog.fadeWindow.upperBound)
        #expect(h.events.states.last == .finishing(elapsedWarning: false), "then the pill shows the turn again")
    }

    @Test("no speech: A06, nothing inserted; a latched session's empty tail ends quietly")
    func noSpeech() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview([]))
        #expect(h.events.notices == [.A06])
        #expect(h.store.entry(id)?.stage == .empty)
        #expect(h.system.postCount == 0)

        guard case .began(let latched) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(latched)
        h.controller.noteLatched(true)
        #expect(h.controller.keyUp(latched))
        await h.controller.finalize(latched, spans: [])
        #expect(h.events.notices == [.A06], "no second No speech detected")
        #expect(h.events.events.last == .retract)
    }

    @Test("a quiet-return stop reason is A06 even with stray text")
    func quietReturnReason() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        await h.controller.finalize(id, spans: Self.words("thank you"), stopReason: .noSpeech)
        #expect(h.events.notices == [.A06])
        #expect(h.system.postCount == 0)
    }

    // MARK: - Capture states

    @Test("Listening · quiet after 1.5 s of VAD silence, back to Listening on speech")
    func quietWhileHolding() throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        #expect(h.store.entry(id)?.stage == .starting)
        h.controller.captureOpened(id)
        #expect(h.controller.admitsEngineState(.listening(level: 0.3)))
        h.clock.advance(1.5)
        #expect(h.controller.stage(of: id) == .listeningQuiet)
        #expect(h.events.states.last == .listeningQuiet)
        #expect(!h.controller.admitsEngineState(.listening(level: 0.3)), "the engine cannot overwrite Quiet")
        h.controller.noteVoiceActivity(speech: true)
        #expect(h.controller.stage(of: id) == .listening)
        #expect(h.events.states.last == .listening(level: 0))
        h.controller.noteVoiceActivity(speech: false)
        h.clock.advance(1.0)
        #expect(h.controller.stage(of: id) == .listening)
        #expect(h.controller.admitsEngineState(.error("x")), "errors always pass")
    }

    // MARK: - Escape

    @Test("Escape while listening cancels: nothing is inserted (N2: a preview is kept instead)", arguments: [false])
    func escapeBeforeWrite(_ inPreview: Bool) async throws {
        let h = Harness()
        let id: TurnID
        if inPreview {
            id = try #require(await h.holdToPreview(Self.words("hello there")))
            h.controller.finalRendered(id)
            h.clock.advance(0.4)
        } else {
            guard case .began(let began) = h.controller.keyDown() else { Issue.record("no turn"); return }
            id = began
            h.controller.captureOpened(id)
        }
        #expect(h.controller.escapePhase == .beforeWrite, "Escape is borrowed while nothing is written")
        #expect(h.controller.escape() == .cancel)
        #expect(h.controller.escapePhase == .none, "and given back once the turn is over")
        #expect(h.events.states.last == .cancelled)
        #expect(h.events.events.contains(.cancelCapture))
        h.clock.advance(5)
        #expect(h.system.postCount == 0)
        #expect(h.field == Self.original)
        #expect(h.store.entry(id)?.stage == .cancelled)
        #expect(h.events.events.last == .retract, "Cancelled goes after its 800 ms")
        if !inPreview { await h.controller.finalize(id, spans: Self.words("late")) }
        #expect(h.system.postCount == 0, "and nothing late lands")
    }

    @Test("Escape after the write began: the outcome is reported truthfully, then a safe Undo")
    func escapeDuringWrite() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        let info = try #require(h.controller.previewInfo)
        let resolution = Box<EscapeResolution?>(nil)
        let phase = Box<EscapeTurnPhase?>(nil)
        h.system.beforeSideEffect = { [controller = h.controller, system = h.system] in
            system.beforeSideEffect = nil
            phase.value = controller.escapePhase
            resolution.value = controller.escape()
        }
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.events.states.last == .undoAvailable })
        #expect(phase.value == .writing)
        #expect(resolution.value == .resolveWriteThenOfferUndo)
        #expect(!h.events.stateNames.contains("cancelled"), "never claims a cancellation")
        #expect(h.store.entry(id)?.stage == .landed)
        #expect(h.store.entry(id)?.record.outcome == .delivered(verified: true, method: "ax"))
        #expect(h.field == Self.original + info.text)
        let order = h.events.events.filter { $0 == .landed || $0 == .present("undoAvailable") }
        #expect(order == [.landed, .present("undoAvailable")], "outcome first, then Undo")

        #expect(TurnWiring.route(.undo, shown: .undoAvailable, to: h.controller, finishLatch: nil))
        #expect(h.field == Self.original, "Undo removed exactly the inserted text")
        #expect(h.store.entry(id)?.stage == .resolved)
        #expect(!h.controller.isUndoAvailable)
    }

    @Test("Undo is range-safe: a changed range is left alone (D10); the offer expires after 5 s")
    func undoRangeSafety() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.system.beforeSideEffect = { [controller = h.controller, system = h.system] in
            system.beforeSideEffect = nil
            controller.escape()
        }
        h.controller.finalRendered(id)
        h.clock.advance(0.9)
        #expect(await h.wait { h.controller.isUndoAvailable })
        h.system.field.value = "Something else entirely"
        #expect(!h.controller.performUndo())
        #expect(h.field == "Something else entirely")
        #expect(h.events.notices.last == .D10)

        // Another turn's offer expires on its own.
        let h2 = Harness()
        let id2 = try #require(await h2.holdToPreview(Self.words("hello there")))
        h2.system.beforeSideEffect = { [controller = h2.controller, system = h2.system] in
            system.beforeSideEffect = nil
            controller.escape()
        }
        h2.controller.finalRendered(id2)
        h2.clock.advance(0.9)
        #expect(await h2.wait { h2.controller.isUndoAvailable })
        h2.clock.advance(5)
        #expect(!h2.controller.isUndoAvailable)
        #expect(h2.events.events.last == .retract)
    }

    // MARK: - Latch

    @Test("latch segments are serialized through one gate: one preview at a time, spoken order kept")
    func latchSerialization() async throws {
        let h = Harness()
        // The latched session's own turn (its trailing audio lands when the session stops).
        guard case .began(let session) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(session)
        h.controller.noteLatched(true)

        let first = Task { await h.lander.land(Self.words("one"), startedAt: Date(), focus: Self.textEdit) }
        #expect(await h.wait { h.controller.previewInfo != nil })
        let second = Task { await h.lander.land(Self.words("two"), startedAt: Date(), focus: Self.textEdit) }
        #expect(await h.wait { h.store.recent().count == 3 })
        let entries = h.store.recent()
        #expect(entries.filter { $0.stage == .finalPreview }.count == 1, "never two payloads on screen")
        #expect(entries.filter { $0.stage == .finishing }.count == 1, "the second waits for the gate")
        #expect(h.system.postCount == 0, "nothing is inserted before its own preview")

        // The tap that stops the latch: its trailing words queue behind the segments.
        #expect(h.controller.keyUp(session))
        await h.controller.finalize(session, spans: Self.words("three"))
        #expect(h.controller.stage(of: session) == .finishing)
        #expect(h.controller.isGateBusy)

        var inserted: [String] = []
        for _ in 0..<3 {
            #expect(await h.wait { h.controller.previewInfo.map { !inserted.contains($0.text) } ?? false })
            let text = try #require(h.controller.previewInfo?.text)
            #expect(h.store.recent().filter { $0.stage == .finalPreview }.count == 1)
            h.controller.finalRendered(text: text)
            h.clock.advance(0.9)
            #expect(await h.wait { h.field.hasSuffix(text) })
            inserted.append(text)
        }
        let one = await first.value
        let two = await second.value
        #expect(one.landed && two.landed)
        #expect(await h.wait { h.events.landed.count == 1 }, "the session turn's outcome goes to onLanded")
        #expect(h.field == Self.original + inserted.joined())
        let spoken = inserted.map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: .punctuationCharacters) }
        #expect(spoken == ["one", "two", "three"])
        #expect(h.system.postCount == 3)
    }

    @Test("lock during the preview keeps the payload as held text (K02); mute cancels it")
    func interruptions() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        h.controller.interrupt(holdPreview: true)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.events.notices == [.K02])
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.focusGuard.heldText(turn: id) != nil)
        #expect(h.system.postCount == 0)

        let muted = Harness()
        let other = try #require(await muted.holdToPreview(Self.words("hello there")))
        muted.controller.interrupt(holdPreview: false)
        muted.clock.advance(5)
        #expect(muted.store.entry(other)?.stage == .cancelled)
        #expect(muted.system.postCount == 0)
        #expect(muted.focusGuard.held.isEmpty)
    }

    @Test("display loss during preview holds the payload and never follows the moved destination")
    func displayLossDuringPreview() async throws {
        let h = Harness()
        let id = try #require(await h.holdToPreview(Self.words("hello there")))
        let previewedText = try #require(h.controller.previewInfo?.text)
        h.controller.finalRendered(id)
        h.controller.pinnedDisplayWasLost()
        h.clock.advance(5)
        #expect(await h.wait { h.events.landed.count == 1 })

        #expect(h.system.postCount == 0)
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.store.entry(id)?.record.writeAttempted == false)
        #expect(h.focusGuard.heldText(turn: id)?.text == previewedText)
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.destinationChanged))
    }

    @Test("display loss while capture is open defers safe recovery until final text exists")
    func displayLossDuringCapture() async throws {
        let h = Harness()
        guard case .began(let id) = h.controller.keyDown() else {
            Issue.record("turn did not begin")
            return
        }
        h.controller.captureOpened(id)
        h.controller.pinnedDisplayWasLost()
        #expect(h.controller.keyUp(id))
        await h.controller.finalize(id, spans: Self.words("preserve this"))
        #expect(await h.wait { h.events.landed.count == 1 })

        #expect(h.system.postCount == 0)
        #expect(h.store.entry(id)?.stage == .held)
        #expect(h.focusGuard.heldText(turn: id)?.text.contains("preserve this") == true)
        #expect(h.events.landed.first?.delivery == .held(reason: DeliveryReason.destinationChanged))
    }

    // MARK: - The record

    @Test("the turn record is written at key down and updated at every transition")
    func recordAtEveryTransition() async throws {
        let h = Harness()
        let seen = Box<[(TurnStage, TurnRecord)]>([])
        h.store.onChange = { entry in seen.value.append((entry.stage, entry.record)) }
        let spans = Self.words("please sign the") + Self.words("contract", confidence: 0.3)
        let id = try #require(await h.holdToPreview(spans))
        h.controller.finalRendered(id)
        h.clock.advance(1.8)
        #expect(await h.wait { h.events.landed.count == 1 })

        let stages = seen.value.map(\.0)
        #expect(stages == [.starting, .starting, .listening, .finishing, .finishing, .finalPreview, .finalPreview,
                           .inserting, .landed])
        let records = seen.value.map(\.1)
        #expect(records.allSatisfy { $0.turnID == id })
        #expect(records[0].destination.bundleID == nil, "written at key down, before the AX read")
        let destination = records[1].destination
        #expect(destination.bundleID == "com.apple.TextEdit" && destination.appName == "TextEdit")
        #expect(destination.role == "AXTextArea" && destination.displayID == 7 && destination.elementHash != nil)
        #expect(destination.selection == 11..<11 && destination.textVersion == TargetRevision.version(of: Self.original))
        #expect(!destination.isSecure)
        #expect(records[2].capture.captureOpened != nil && records[2].captureOpenLatency != nil)
        #expect(records[3].capture.captureClosed != nil)
        #expect(records[4].rawText == spans.joinedText)
        #expect(!records[5].finalText.isEmpty && records[5].capture.finalPublished != nil)
        #expect(records[5].uncertainSpans.count == 1)
        #expect(records[5].capture.finalRendered == nil && records[6].capture.finalRendered != nil)
        #expect(!records[6].writeAttempted && records[7].writeAttempted && records[7].capture.writeDispatched != nil)
        #expect(records[7].outcome == nil, "dispatched is not verified")
        #expect(records[8].outcome == .delivered(verified: true, method: "ax"))
        #expect(h.store.entry(id)?.evidence == .toReview(1))
    }

    // MARK: - Wiring helpers

    @Test("the pill's turn buttons route to the controller; other buttons do not")
    func routing() {
        let h = Harness()
        let preview = PillState.finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0.9))
        #expect(TurnWiring.route(.review, shown: preview, to: h.controller, finishLatch: nil))
        #expect(TurnWiring.route(.cancel, shown: preview, to: h.controller, finishLatch: nil))
        #expect(TurnWiring.route(.useAvailable, shown: .finishing(elapsedWarning: true), to: h.controller, finishLatch: nil))
        var finished = false
        #expect(TurnWiring.route(.finish, shown: .latched(elapsed: 3), to: h.controller, finishLatch: { finished = true }))
        #expect(finished)
        #expect(!TurnWiring.route(.finish, shown: .latched(elapsed: 3), to: h.controller, finishLatch: nil))
        #expect(!TurnWiring.route(.undo, shown: .undoAvailable, to: h.controller, finishLatch: nil), "no offer, not ours")
        #expect(!TurnWiring.route(.check, shown: .landed(LandedPillInfo(text: "x", verified: false)), to: h.controller, finishLatch: nil))
        #expect(!TurnWiring.route(.copy, shown: .error(message: "x"), to: h.controller, finishLatch: nil))
    }

    @Test("a quiet end only takes down the turn's own rows")
    func retractableRows() {
        #expect(TurnWiring.isTurnRow(.starting, captureOpen: false))
        #expect(TurnWiring.isTurnRow(.finishing(elapsedWarning: true), captureOpen: false))
        #expect(TurnWiring.isTurnRow(.cancelled, captureOpen: false))
        #expect(TurnWiring.isTurnRow(.preview(text: "live"), captureOpen: true))
        #expect(!TurnWiring.isTurnRow(.preview(text: "Dictation stopped"), captureOpen: false), "a notice")
        #expect(TurnWiring.isTurnRow(.error(message: RecoveryCatalog.entry(.K04).headline), captureOpen: false))
        #expect(!TurnWiring.isTurnRow(.error(message: "No speech detected"), captureOpen: false))
        #expect(!TurnWiring.isTurnRow(.latched(elapsed: 2), captureOpen: true))
        #expect(!TurnWiring.isTurnRow(.held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed")),
                                      captureOpen: false))
    }
}
