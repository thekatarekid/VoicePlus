import AppKit
import Engine
import Foundation
import GRDB
import Injection
import Lab
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

// W3H — the wave-2 gate's open hand-offs (build doc §1 row "3 | c", `.v4handoff/wave2.md` › wave2
// gate): Double-tap to latch on the live key, sound cues at the design's cue points (design §11), the
// saved theme at launch, "Save dictation history" off in every writer, LabWiring opening the
// Benchmarks / Diagnostics disclosures, the pill's Review → the recovery sheet, and S12's transform
// before/after rows drawn in the pill. Everything runs on stubs, in-memory stores and pure models; no
// key, speaker, window server or real destination is touched.

@Suite("W3H — wave-2 gate hand-offs")
@MainActor
struct W3HHandoffTests {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func appDelegateSource() throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
    }

    // MARK: - (1) Double-tap to latch

    @Test("latch on: the second quick tap latches, nothing is reset")
    func latchOnPassesTheGesture() {
        let forwarded = Box<[HotkeyStateMachine.Action]>([])
        let resets = Box(0)
        let hook = LatchGestureHook(isEnabled: { true }, resetGesture: { resets.value += 1 },
                                    forward: { forwarded.value.append($0) })
        [.startCapture, .cancelCapture, .startCapture, .enterLatch].forEach(hook.handle)
        #expect(forwarded.value == [.startCapture, .cancelCapture, .startCapture, .enterLatch])
        #expect(resets.value == 0)
    }

    @Test("latch off: the second quick tap is one more short tap, and the key's machine is reset")
    func latchOffIsTwoShortTaps() {
        let forwarded = Box<[HotkeyStateMachine.Action]>([])
        let resets = Box(0)
        let hook = LatchGestureHook(isEnabled: { false }, resetGesture: { resets.value += 1 },
                                    forward: { forwarded.value.append($0) })
        [.startCapture, .cancelCapture, .startCapture, .enterLatch, .startCapture, .finalize].forEach(hook.handle)
        #expect(forwarded.value == [.startCapture, .cancelCapture, .startCapture, .cancelCapture, .startCapture, .finalize])
        #expect(!forwarded.value.contains(.enterLatch), "nothing latches with the switch off")
        #expect(resets.value == 1)
    }

    /// fn / 🌐 edges through a real `HotkeyService`, the hook installed exactly as AppDelegate's W3H
    /// block installs it. Timing: tap guard 180 ms, double-tap window 350 ms, hold 250 ms.
    func driveDoubleTapThenHold(latch: Bool) -> [HotkeyStateMachine.Action] {
        let store = InMemorySettingsStore()
        LatchGestureSettings.setEnabled(latch, store: store)
        let service = HotkeyService(defaults: UserDefaults(suiteName: "vp.w3h.\(UUID().uuidString)")!)
        let actions = Box<[HotkeyStateMachine.Action]>([])
        let downstream: (HotkeyStateMachine.Action) -> Void = { actions.value.append($0) }
        let hook = LatchGestureHook(isEnabled: { LatchGestureSettings.isEnabled(store) },
                                    resetGesture: { [weak service] in service?.resetGesture() },
                                    forward: downstream)
        service.onAction = { hook.handle($0) }
        let fn: Int64 = 63, down: UInt64 = 0x0080_0000
        service.handle(keyCode: fn, flags: down, timestamp: 10.00)
        service.handle(keyCode: fn, flags: 0, timestamp: 10.05)
        service.handle(keyCode: fn, flags: down, timestamp: 10.15)
        service.handle(keyCode: fn, flags: 0, timestamp: 10.20)   // second quick tap
        service.handle(keyCode: fn, flags: down, timestamp: 12.00) // the next press…
        service.handle(keyCode: fn, flags: 0, timestamp: 12.60)    // …held and released
        return actions.value
    }

    @Test("live key, latch off: a double tap then a hold dictates normally — no stray finish")
    func liveKeyLatchOff() {
        #expect(driveDoubleTapThenHold(latch: false)
                == [.startCapture, .cancelCapture, .startCapture, .cancelCapture, .startCapture, .finalize])
    }

    @Test("live key, latch on: a double tap latches and the next press finishes it")
    func liveKeyLatchOn() {
        #expect(driveDoubleTapThenHold(latch: true)
                == [.startCapture, .cancelCapture, .startCapture, .enterLatch, .finalize])
    }

    @Test("the chin's hint names the double tap only while it exists (design §5)")
    func readyHintFollowsTheSwitch() {
        let store = InMemorySettingsStore()
        let fn = HotkeyBinding(kind: .fn)
        #expect(LatchGestureHook.readyHint(binding: fn, settings: store) == "Hold or Double Tap fn / 🌐 to dictate")
        LatchGestureSettings.setEnabled(false, store: store)
        #expect(LatchGestureHook.readyHint(binding: fn, settings: store) == "Hold fn / 🌐 to dictate")
    }

    // MARK: - (2) Sound cues

    static func entry(_ id: TurnID, _ stage: TurnStage, outcome: DeliveryOutcome? = nil) -> TurnEntry {
        TurnEntry(record: TurnRecord(turnID: id, finalText: "hello there", outcome: outcome), stage: stage,
                  updatedAt: Date(), persisted: false)
    }

    @Test("cue points: capture really open, capture closed, and a delivery only once it is known")
    func cuePoints() {
        let cues = TurnSoundCues()
        let id = TurnID()
        #expect(cues.events(for: Self.entry(id, .starting)).isEmpty, "Starting is not listening")
        #expect(cues.events(for: Self.entry(id, .listening)) == [.captureOpened])
        #expect(cues.events(for: Self.entry(id, .listeningQuiet)).isEmpty, "quiet is still the same open capture")
        #expect(cues.events(for: Self.entry(id, .finishing)) == [.captureClosed])
        #expect(cues.events(for: Self.entry(id, .finalPreview)).isEmpty)
        #expect(cues.events(for: Self.entry(id, .inserting)).isEmpty, "no success cue while the write is in flight")
        let landed = Self.entry(id, .landed, outcome: .delivered(verified: true, method: "ax"))
        #expect(cues.events(for: landed) == [.delivered(verified: true)])
        #expect(cues.events(for: landed).isEmpty, "the database write landing is not a second delivery")

        let cancelled = TurnID()
        _ = cues.events(for: Self.entry(cancelled, .starting))
        #expect(cues.events(for: Self.entry(cancelled, .cancelled)) == [.notDelivered], "no stop cue for a mic that never opened")
        let escaped = TurnID()
        _ = cues.events(for: Self.entry(escaped, .listening))
        #expect(cues.events(for: Self.entry(escaped, .cancelled)) == [.captureClosed, .notDelivered])
    }

    static func hold(_ store: TurnStore, outcome: DeliveryOutcome) -> TurnID {
        let id = TurnID()
        let record = TurnRecord(turnID: id, finalText: "hello there")
        store.save(record, stage: .starting)
        store.update(id, stage: .listening)
        store.update(id, stage: .finishing)
        store.update(id, stage: .finalPreview)
        store.update(id, stage: .inserting)
        store.update(id, stage: outcome.isHeld ? .held : .landed) { $0.outcome = outcome }
        return id
    }

    @Test("with cues on: start, stop, and success only after a verified insertion")
    func successOnlyWhenVerified() {
        let settings = InMemorySettingsStore()
        SoundCueSettings.setEnabled(true, store: settings)
        let store = TurnStore(database: nil)
        let played = Box<[SoundCue]>([])
        TurnSoundCues().attach(to: store, settings: settings, sink: { played.value.append($0) }, perform: { $0() })

        _ = Self.hold(store, outcome: .delivered(verified: true, method: "ax"))
        #expect(played.value == [.start, .stop, .success])

        played.value = []
        _ = Self.hold(store, outcome: .delivered(verified: false, method: "paste"))
        #expect(played.value == [.start, .stop], "an unconfirmed insertion never sounds like success")

        played.value = []
        _ = Self.hold(store, outcome: .partial(method: "keystroke"))
        #expect(played.value == [.start, .stop], "a partial insertion makes no success sound")

        played.value = []
        let held = Self.hold(store, outcome: .held(reason: "destination changed"))
        #expect(played.value == [.start, .stop])
        // Insert here later, verified: that is when the success sound belongs.
        store.update(held, stage: .landed) { $0.outcome = .delivered(verified: true, method: "ax") }
        #expect(played.value == [.start, .stop, .success])
    }

    @Test("cues are off by default: nothing plays")
    func cuesOffByDefault() {
        let store = TurnStore(database: nil)
        let played = Box<[SoundCue]>([])
        TurnSoundCues().attach(to: store, settings: InMemorySettingsStore(), sink: { played.value.append($0) }, perform: { $0() })
        _ = Self.hold(store, outcome: .delivered(verified: true, method: "ax"))
        #expect(played.value.isEmpty)
    }

    @Test("a persisted row reported again does not replay its cue; earlier listeners still hear every change")
    func persistedRowsDoNotReplay() throws {
        let settings = InMemorySettingsStore()
        SoundCueSettings.setEnabled(true, store: settings)
        let store = TurnStore(database: try AppDatabase.inMemory())
        let earlier = Box(0)
        store.onChange = { _ in earlier.value += 1 }
        let played = Box<[SoundCue]>([])
        TurnSoundCues().attach(to: store, settings: settings, sink: { played.value.append($0) }, perform: { $0() })
        _ = Self.hold(store, outcome: .delivered(verified: true, method: "ax"))
        store.flush()
        #expect(played.value == [.start, .stop, .success])
        #expect(earlier.value >= 6, "the listener that was there first is chained, not replaced")
    }

    // MARK: - (3) The theme at launch

    @Test("the saved theme is what launch applies; nothing saved follows the system")
    func themeAtLaunch() {
        let store = InMemorySettingsStore()
        let applied = Box<[WindowTheme]>([])
        #expect(LaunchAppearance.apply(settings: store, apply: { applied.value.append($0) }) == .system)
        AppearanceSettings.setTheme(.dark, store: store)
        #expect(LaunchAppearance.apply(settings: store, apply: { applied.value.append($0) }) == .dark)
        AppearanceSettings.setTheme(.light, store: store)
        LaunchAppearance.apply(settings: store, apply: { applied.value.append($0) })
        #expect(applied.value == [.system, .dark, .light])
        #expect(WindowTheme.dark.appearanceName == .darkAqua && WindowTheme.system.appearanceName == nil)
    }

    @Test("AppDelegate applies the theme before the first window, and wires every W3H hook once")
    func appDelegateWiring() throws {
        let source = try Self.appDelegateSource()
        let block = try #require(source.range(of: "// ── W3H"))
        let end = try #require(source.range(of: "// ── end W3H"))
        let firstWindow = try #require(source.range(of: "OnboardingWindowController.isNeeded"))
        #expect(block.lowerBound < firstWindow.lowerBound, "the theme is applied before onboarding can open")
        let hooks = String(source[block.lowerBound..<end.upperBound])
        for call in ["LaunchAppearance.apply(settings:", "LatchGestureHook(", "hotkey.onAction = { latchGesture.handle($0) }",
                     "presence.readyHint", "DictationHistoryGate.attach(", "TurnSoundCues().attach(",
                     "TransformRowsFeed.attach(", "PillReviewWiring.install(", "confirmPreview()", "cancelPreview()"] {
            #expect(hooks.contains(call), "W3H block is missing \(call)")
        }
        // The latch hook wraps the deixis key controller, so it must come after it is installed.
        let deixisKeys = try #require(source.range(of: "hotkey.onAction = { action in deixisKeys.handle(action) }"))
        #expect(deixisKeys.lowerBound < block.lowerBound)
    }

    // MARK: - (4) "Save dictation history" off

    static func rowCount(_ db: AppDatabase) throws -> Int {
        try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(TurnStore.table)") } ?? 0
    }

    @Test("history off: settled turns stay in memory only; held and partial rows are still saved")
    func historyOffKeepsOnlyRecoverableRows() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        store.historyEnabled = { false }
        let landed = Self.hold(store, outcome: .delivered(verified: true, method: "ax"))
        let held = Self.hold(store, outcome: .held(reason: "destination changed"))
        let partial = Self.hold(store, outcome: .partial(method: "keystroke"))
        store.flush()

        #expect(try Self.rowCount(db) == 2, "only the held and the partial turn reach the database")
        let reopened = TurnStore(database: db)
        #expect(reopened.entry(landed) == nil, "the inserted dictation was not saved")
        #expect(reopened.entry(held)?.stage == .held)
        #expect(reopened.entry(partial)?.record.outcome == .partial(method: "keystroke"))
        // This session still has the turn (the controller's record, the turn detail).
        let memory = try #require(store.entry(landed))
        #expect(memory.stage == .landed && !memory.persisted, "never claims a save that did not happen")
        let recoverable: Set<TurnID> = Set(store.recoverable().map(\.id))
        #expect(recoverable == Set([held, partial]), "held and partial stay recoverable")
    }

    @Test("history off: a held row leaves the database once it is resolved")
    func historyOffForgetsResolvedRows() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        store.historyEnabled = { false }
        let held = Self.hold(store, outcome: .held(reason: "destination changed"))
        store.flush()
        #expect(try Self.rowCount(db) == 1)
        store.update(held, stage: .landed) { $0.outcome = .delivered(verified: true, method: "ax") }
        store.flush()
        #expect(try Self.rowCount(db) == 0, "resolved, it is history — and history is off")
        #expect(store.entry(held)?.persisted == false)
        #expect(store.entry(held)?.stage == .landed)
    }

    @Test("history on: every turn is saved, as before")
    func historyOnSavesEverything() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        _ = Self.hold(store, outcome: .delivered(verified: true, method: "ax"))
        _ = Self.hold(store, outcome: .held(reason: "destination changed"))
        store.flush()
        #expect(try Self.rowCount(db) == 2)
    }

    static func lander(_ db: AppDatabase, system: MockSystemAccess) -> UtteranceLander {
        UtteranceLander(pipeline: PipelineRunner(stages: []), injector: TextInjector(system: system), system: system,
                        repair: nil, flags: FeatureFlagService.inMemory(), database: db)
    }

    @Test("history off: the lander inserts but writes nothing to dictation history")
    func landerHonoursTheSwitch() async throws {
        let spans = [TranscriptSpan(text: "hello there", confidence: 0.9, audioRange: 0...0.5)]
        let on = try AppDatabase.inMemory()
        let system = MockSystemAccess()
        system.field = .init(value: "")
        let saving = Self.lander(on, system: system)
        let first = await saving.land(spans, startedAt: Date(), focus: system.frontmost)
        #expect(first.landed)
        #expect(try on.recentDictations().count == 1)

        let off = try AppDatabase.inMemory()
        let quiet = MockSystemAccess()
        quiet.field = .init(value: "")
        let notSaving = Self.lander(off, system: quiet)
        let settings = InMemorySettingsStore()
        TodayHistorySettings.setEnabled(false, store: settings)
        DictationHistoryGate.attach(settings: settings, lander: notSaving, coordinator: nil, store: nil)
        let second = await notSaving.land(spans, startedAt: Date(), focus: quiet.frontmost)
        #expect(second.landed, "the dictation still lands")
        #expect(quiet.field.value.contains("hello"))
        #expect(try off.recentDictations().isEmpty, "nothing reached dictation history")
    }

    @Test("the gate reads the switch on every write, for the lander, the coordinator and the turn store")
    func gateReadsPerWrite() throws {
        let settings = InMemorySettingsStore()
        let system = MockSystemAccess()
        let lander = Self.lander(try AppDatabase.inMemory(), system: system)
        let coordinator = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                               pill: PillPanelController())
        let store = TurnStore(database: nil)
        #expect(lander.recordsHistory() && coordinator.recordsHistory() && store.historyEnabled(), "on by default")
        DictationHistoryGate.attach(settings: settings, lander: lander, coordinator: coordinator, store: store)
        #expect(lander.recordsHistory() && coordinator.recordsHistory() && store.historyEnabled())
        TodayHistorySettings.setEnabled(false, store: settings)
        #expect(!lander.recordsHistory() && !coordinator.recordsHistory() && !store.historyEnabled(),
                "turning it off applies to the next dictation, no relaunch")
    }

    // MARK: - (5) LabWiring opens the disclosures

    @Test("the menu's Lab and Data Panel open Voice › Benchmarks and Privacy › Diagnostics, expanded")
    func labWiringOpensDisclosures() {
        #expect(LabWindowController.labRoute == WindowRoute(.voice, disclosure: .benchmarks))
        #expect(LabWindowController.dataPanelRoute == WindowRoute(.privacy, disclosure: .diagnostics))
        #expect(LabWindowController.labRoute.isValid && LabWindowController.dataPanelRoute.isValid)

        let saved = MainWindowController.environment
        defer { MainWindowController.environment = saved }
        var opened: [WindowRoute] = []
        LabWindowController.showLab(registry: .mocks, database: nil, open: { opened.append($0) })
        LabWindowController.showDataPanel(database: nil, gate: EgressGate(defaults: UserDefaults(suiteName: "vp.w3h.\(UUID().uuidString)")!),
                                          open: { opened.append($0) })
        #expect(opened == [LabWindowController.labRoute, LabWindowController.dataPanelRoute])

        let window = MainWindowShellS7aTests.window()
        window.apply(LabWindowController.labRoute)
        #expect(window.selection == .voice && window.navigation(.voice).isExpanded(.benchmarks))
        window.apply(LabWindowController.dataPanelRoute)
        #expect(window.selection == .privacy && window.navigation(.privacy).isExpanded(.diagnostics))
    }

    // MARK: - (6) The pill's Review → the recovery sheet

    @Test("Review / Check on a delivery or error row is this routing's; the preview's Review and Review word are not")
    func reviewOwnership() {
        #expect(PillReviewRoute.owns(.check, shown: .landedPartial(text: "a")))
        #expect(PillReviewRoute.owns(.review, shown: .error(message: "Couldn't finish this dictation")))
        #expect(PillReviewRoute.owns(.check, shown: .landed(LandedPillInfo(text: "a", verified: false))))
        #expect(!PillReviewRoute.owns(.check, shown: .landed(LandedPillInfo(text: "a", verified: true))))
        #expect(!PillReviewRoute.owns(.review, shown: .correcting), "Review word belongs to the correction surface")
        #expect(!PillReviewRoute.owns(.voice, shown: .landedPartial(text: "a")))
        #expect(!PillReviewRoute.owns(.review, shown: .finalPreview(FinalPreviewInfo(text: "a", dwellRemaining: 0.9))),
                "Review on the final preview pauses the dwell (S3)")
    }

    @Test("a draft wins (by held item, then by its words); an unconfirmed turn opens its detail; else Today")
    func resolveOrder() {
        let heldID = UUID()
        let held = TodayDraft(heldID: heldID, text: "Held words", destination: "Mail")
        let partial = TodayDraft(turnID: TurnID(), kind: .partial, text: "Half of this landed.", destination: "Slack")
        let unconfirmed = S7bRig.entry(S7bRig.record("Open the configuration file.",
                                                     outcome: .delivered(verified: false, method: "keystroke")), .landed)
        let drafts = [held, partial]
        #expect(PillReviewRoute.resolve(shown: .held(HeldPillInfo(id: heldID, text: "other text", destination: "Mail", reason: "x")),
                                        text: "other text", drafts: drafts, turns: []) == .recovery(held))
        #expect(PillReviewRoute.resolve(shown: .landedPartial(text: "Half of this  landed."), text: "Half of this  landed.",
                                        drafts: drafts, turns: [unconfirmed]) == .recovery(partial))
        #expect(PillReviewRoute.resolve(shown: .landed(LandedPillInfo(text: "Open the configuration file.", verified: false)),
                                        text: "Open the configuration file.", drafts: drafts, turns: [unconfirmed])
                == .turn(unconfirmed.id))
        #expect(PillReviewRoute.resolve(shown: .error(message: "x"), text: "", drafts: drafts, turns: [unconfirmed]) == .today)
        #expect(PillReviewRoute.resolve(shown: .error(message: "x"), text: "never said", drafts: drafts, turns: []) == .today)
    }

    @Test("Review result on the pill's partial row opens Today's recovery sheet for that draft")
    func pillReviewOpensTheRecoverySheet() async throws {
        let partial = S7bRig.entry(S7bRig.record("Half of this landed.", app: "Slack", outcome: .partial(method: "keystroke")), .landed)
        let rig = S7bRig([partial])
        await rig.model.reloadHistory()
        let pill = PillViewModel()
        let passed = Box<[PillActionKind]>([])
        pill.onAction = { action, _ in passed.value.append(action) }
        let opened = Box(0)
        PillReviewWiring.install(on: pill, openToday: { opened.value += 1; return rig.model }, transform: { _ in })

        pill.present(delivery: .partial(method: "keystroke"), text: "Half of this landed.", destination: "Slack")
        let content = pill.content()
        #expect(content.buttons.map(\.action) == [.check], "the design's partial row: Review result")
        pill.perform(.check)

        #expect(opened.value == 1, "Today is opened")
        let sheet = try #require(rig.model.recovery, "…and the recovery sheet on it")
        #expect(sheet.draft?.text == "Half of this landed.")
        #expect(sheet.draft?.kind == .partial)
        #expect(passed.value.isEmpty, "the old 'open Today' route did not also run")
    }

    @Test("Check text on an unconfirmed row opens that turn's detail (delivery evidence), not a sheet")
    func checkTextOpensTheTurnDetail() async throws {
        let unconfirmed = S7bRig.entry(S7bRig.record("Open the configuration file.", app: "Editor",
                                                     outcome: .delivered(verified: false, method: "keystroke")), .landed)
        let rig = S7bRig([unconfirmed])
        await rig.model.reloadHistory()
        let pill = PillViewModel()
        PillReviewWiring.install(on: pill, openToday: { rig.model }, transform: { _ in })
        pill.present(delivery: .delivered(verified: false, method: "keystroke"), text: "Open the configuration file.",
                     destination: "Editor")
        pill.perform(.check)
        #expect(rig.model.recovery == nil)
        #expect(rig.model.detail?.turnID == unconfirmed.id)
    }

    @Test("everything else goes where it went before; the transform preview's buttons reach the landing")
    func otherButtonsPassThrough() {
        let pill = PillViewModel()
        let passed = Box<[PillActionKind]>([])
        let transform = Box<[PillTransformButton]>([])
        let opened = Box(0)
        pill.onAction = { action, _ in passed.value.append(action) }
        PillReviewWiring.install(on: pill, openToday: { opened.value += 1; return nil },
                                 transform: { transform.value.append($0) })
        pill.onAction?(.voice, .warning(.unknownGood))
        pill.onAction?(.review, .finalPreview(FinalPreviewInfo(text: "a", dwellRemaining: 0.9)))
        pill.onAction?(.commit, .finalPreview(FinalPreviewInfo(text: "a", dwellRemaining: 0.9)))
        #expect(passed.value == [.voice, .review, .commit])
        let preview = PillState.transform(TransformPillInfo(editingWords: 4, stage: .notice("Preview · a → b")))
        pill.onAction?(.commit, preview)
        pill.onAction?(.cancel, preview)
        #expect(transform.value == [.confirm, .cancel])
        #expect(passed.value == [.voice, .review, .commit], "Replace text / Cancel never reach the dictation turn")
        #expect(opened.value == 0)
        #expect(PillTransformButton.route(.commit, shown: .finalPreview(FinalPreviewInfo(text: "a", dwellRemaining: 0.9))) == nil)
    }

    // MARK: - (7) The transform's before / after rows in the pill

    static let original = "Can we meet Friday"
    static let edited = "Can we meet on Friday?"
    static var preview: TransformPreview { TransformPreview(instruction: "fix the friday question", before: original,
                                                            after: edited, destination: "Mail") }

    @Test("rows are drawn only over the stage they describe")
    func rowsMatchTheirStage() {
        let editing = TransformPreviewRows.editing(words: 4, instruction: "fix the friday question")
        let previewRows = TransformPreviewRows.preview(Self.preview, manual: false)
        let updated = TransformPreviewRows.updated(Self.preview)
        let editingState = PillState.transform(TransformPillInfo(editingWords: 4, stage: .editing))
        let previewState = PillState.transform(TransformPillInfo(editingWords: 4, stage: .notice("Preview · Friday → on Friday?")))
        let doneState = PillState.transform(TransformPillInfo(editingWords: 5, stage: .done(changed: 2)))
        let warmState = PillState.transform(TransformPillInfo(editingWords: 5, stage: .warm(remaining: 5)))

        #expect(PillTransformRows.drawn(for: editingState, rows: editing) == editing)
        #expect(PillTransformRows.drawn(for: previewState, rows: previewRows) == previewRows)
        #expect(PillTransformRows.drawn(for: doneState, rows: updated) == updated)
        #expect(PillTransformRows.drawn(for: editingState, rows: updated) == nil, "the previous edit's rows are stale")
        #expect(PillTransformRows.drawn(for: previewState, rows: updated) == nil, "an undo-refused notice is not a preview")
        #expect(PillTransformRows.drawn(for: editingState, rows: previewRows) == nil)
        #expect(PillTransformRows.drawn(for: warmState, rows: updated) == nil)
        #expect(PillTransformRows.drawn(for: .landedPartial(text: "a"), rows: previewRows) == nil)
        #expect(PillTransformRows.drawn(for: previewState, rows: nil) == nil)
    }

    @Test("the edited preview draws S12's status, both texts and helper — and its buttons only in manual review")
    func previewContent() throws {
        let pill = PillViewModel()
        pill.transformRows = .preview(Self.preview, manual: false)
        pill.present(.transform(TransformPillInfo(editingWords: 4, stage: .notice(TransformPreviewCopy.compactLine(Self.preview)))))
        let auto = pill.content()
        #expect(auto.status == "Ready for Mail", "F1's words, not the one-line summary")
        #expect(auto.helper == "Microphone closed · original text unchanged")
        #expect(auto.words == .live(Self.edited))
        #expect(auto.buttons.isEmpty, "an automatic preview replaces after its dwell and revalidation")
        #expect(auto.spoolKey == "editing", "R1's pose while the edit is previewed")
        let lane = try #require(PillTransformLane.Model(rows: pill.drawnTransformRows, lineCount: 2))
        #expect(lane.before == "…we meet Friday", "the original, struck through, from the change")
        #expect(lane.after == "…we meet on Friday?")

        pill.transformRows = .preview(Self.preview, manual: true)
        let manual = pill.content()
        #expect(manual.buttons == [PillButton("Replace text", .commit, primary: true), PillButton("Cancel", .cancel)])
        #expect(manual.hasActions, "the 204 pt actionable pill, so the buttons have their row")
    }

    @Test("R1 editing shows the instruction; R2 shows the edited text with Undo")
    func editingAndUpdatedContent() {
        let pill = PillViewModel()
        pill.transformRows = .editing(words: 4, instruction: "make it a question")
        pill.present(.transform(TransformPillInfo(editingWords: 4, stage: .editing)))
        let editing = pill.content()
        #expect(editing.status == "Editing 4 words…")
        #expect(editing.words == .live("make it a question"))
        #expect(editing.helper == "Microphone closed · original text unchanged")
        #expect(PillTransformLane.Model(rows: pill.drawnTransformRows, lineCount: 2) == nil, "one text: the ordinary lane")

        pill.transformRows = .updated(Self.preview)
        pill.present(.transform(TransformPillInfo(editingWords: 5, stage: .done(changed: 2))))
        let updated = pill.content()
        #expect(updated.status == "✓ Updated in Mail")
        #expect(updated.words == .live(Self.edited))
        #expect(updated.helper == "Undo only while the edited range still matches")
        #expect(updated.buttons == [PillButton("Undo", .undo, primary: true)])
    }

    @Test("without rows the pill is exactly S2's; with a chip row only the edited text is drawn")
    func fallbacks() {
        let pill = PillViewModel()
        let state = PillState.transform(TransformPillInfo(editingWords: 4, stage: .editing))
        pill.present(state)
        #expect(pill.content() == PillContent.make(state, context: pill.context()))
        let lane = PillTransformLane.Model(rows: .preview(Self.preview, manual: false), lineCount: 1)
        #expect(lane?.before == nil && lane?.after == "…we meet on Friday?")
        let short = PillTransformLane.Model.excerpt(before: "hello", after: "goodbye")
        #expect(short.before == "hello" && short.after == "goodbye", "a change at the first word needs no ellipsis")
    }

    @Test("the landing's rows reach the pill at each event: the preview, then Updated")
    func feedPublishesTheLandingRows() async throws {
        let h = TransformPreviewGateTests.harness()
        let published = Box<[TransformPreviewRows?]>([])
        TransformRowsFeed.attach(to: h.landing, publish: { published.value.append($0) }, sleep: { await Task.yield() })
        _ = await TransformPreviewGateTests.instruct(h.landing)
        #expect(TransformPreviewGateTests.kinds(h.events.value).contains("previewing"), "earlier listeners still get every event")
        let rows = published.value.compactMap { $0 }
        let previewRows = try #require(rows.first { $0.before != nil })
        #expect(previewRows.before == TransformPreviewGateTests.original)
        #expect(previewRows.text == TransformPreviewGateTests.edited)
        #expect(previewRows.designStateKey == "editing")
        let updated = try #require(rows.last)
        #expect(updated.designStateKey == "undo" && updated.text == TransformPreviewGateTests.edited)
    }

    @Test("after .began the feed waits for R1's editing rows and publishes them once")
    func feedFollowsEditing() async {
        let editing = TransformPreviewRows.editing(words: 4, instruction: "fix it")
        let reads = Box<[TransformPreviewRows?]>([nil, .updated(Self.preview), editing, editing])
        let published = Box<[TransformPreviewRows?]>([])
        let feed = TransformRowsFeed(read: { reads.value.isEmpty ? nil : reads.value.removeFirst() },
                                     publish: { published.value.append($0) }, sleep: {}, attempts: 8)
        await feed.followEditing()
        #expect(published.value == [editing])

        let never = TransformRowsFeed(read: { .preview(Self.preview, manual: false) },
                                      publish: { published.value.append($0) }, sleep: {}, attempts: 3)
        published.value = []
        await never.followEditing()
        #expect(published.value.isEmpty, "a preview is published by its own event, never by the follow-up")
    }
}
