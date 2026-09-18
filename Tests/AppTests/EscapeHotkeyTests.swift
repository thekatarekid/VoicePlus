import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Records Escape registrations instead of taking Escape from the whole machine.
private final class StubEscapeKey {
    var installSucceeds = true
    private(set) var installed: [Int] = []
    private(set) var invalidated: [Int] = []
    var live: [Int] { installed.filter { !invalidated.contains($0) } }

    /// Strong on purpose: the controller owns the backend and the backend owns the stub, so a test
    /// that ignores the stub still gets a working one (nothing points back, so no cycle).
    var backend: EscapeKeyBackend {
        EscapeKeyBackend { token in
            guard self.installSucceeds else { return nil }
            self.installed.append(token)
            return InstalledHotkeySource(setEnabled: { _ in }, invalidate: {
                guard !self.invalidated.contains(token) else { return }
                self.invalidated.append(token)
            })
        }
    }
}

private let quality = MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor)
private let preview = FinalPreviewInfo(text: "Can we meet with Mira on Friday?", dwellRemaining: 0.9, destination: "Mail")

/// Every `PillState` case with whether Escape is ours in it (design §5/§6; build doc I2).
private let registrationTable: [(PillState, EscapeResolution?)] = [
    // A turn is live: capture, finishing, final preview → cancel; the write → resolve, then Undo.
    (.starting, .cancel), (.listening(level: 0.4), .cancel), (.listeningQuiet, .cancel),
    (.latched(elapsed: 6), .cancel), (.warning(quality), .cancel),
    (.finishing(elapsedWarning: false), .cancel), (.finishing(elapsedWarning: true), .cancel),
    (.finalPreview(preview), .cancel),
    (.finalPreview(FinalPreviewInfo(text: "x", uncertainCount: 1, dwellRemaining: 1.8)), .cancel),
    (.inserting(text: "Can we meet?"), .resolveWriteThenOfferUndo),
    // Never ours: idle, held, error, notices, outcomes, the app's own popovers, meetings.
    (.hidden, nil), (.idle, nil), (.ready(hint: HotkeyBinding.default.readyHint()), nil), (.muted, nil),
    (.unavailable(reason: "No speech model installed"), nil), (.error(message: "Text was not typed"), nil),
    (.held(HeldPillInfo(text: "Can we meet?", destination: "Mail", reason: "destination changed")), nil),
    (.landed(LandedPillInfo(text: "Can we meet?", verified: true)), nil),
    (.landed(LandedPillInfo(text: "Can we meet?", verified: false)), nil),
    (.landedPartial(text: "Can we meet?"), nil), (.cancelled, nil), (.correcting, nil), (.editing, nil),
    (.undoAvailable, nil), (.transform(TransformPillInfo(editingWords: 3, stage: .editing)), nil),
    (.meeting(MeetingPillInfo(phase: .recording, elapsed: 5)), nil),
    (.preview(text: "Muted — mic stays closed until you unmute"), nil), (.landing, nil),
]

@Suite("I2 — Escape during a turn")
struct EscapeHotkeyTests {
    private func make() -> (EscapeHotkey, StubEscapeKey, Box) {
        let stub = StubEscapeKey()
        let escape = EscapeHotkey(backend: stub.backend)
        let box = Box()
        escape.onEscape = { box.fired.append($0) }
        return (escape, stub, box)
    }

    private final class Box { var fired: [EscapeResolution] = [] }

    // MARK: Registration lifecycle per state

    @Test func everyPillStateHasAKnownAnswer() {
        for (state, expected) in registrationTable {
            #expect(EscapeResolution(EscapeTurnPhase(state)) == expected, "\(state.caseName)")
            let (escape, stub, _) = make()
            escape.update(state)
            #expect(escape.isRegistered == (expected != nil), "\(state.caseName)")
            #expect(stub.live.count == (expected != nil ? 1 : 0))
        }
        // The table covers every case the pill has.
        let names = Set(registrationTable.map { $0.0.caseName })
        #expect(names.count >= 25)
    }

    @Test func neverRegisteredWhileIdle() {
        let (escape, stub, box) = make()
        for state: PillState in [.hidden, .idle, .ready(hint: "Hold or Double Tap fn / 🌐 to dictate"), .muted] {
            escape.update(state)
            escape.press()
        }
        #expect(!escape.isRegistered)
        #expect(stub.installed.isEmpty)
        #expect(box.fired.isEmpty)
    }

    @Test func oneRegistrationForAWholeTurnThenReleasedOnIdle() {
        let (escape, stub, _) = make()
        escape.update(.idle)
        escape.update(.starting)
        #expect(escape.isRegistered)
        for state: PillState in [.listening(level: 0.2), .listeningQuiet, .listening(level: 0.5),
                                 .finishing(elapsedWarning: false), .finalPreview(preview), .inserting(text: "x")] {
            escape.update(state)
            #expect(escape.isRegistered)
        }
        #expect(escape.registrationCount == 1, "a turn must not re-register on every state change")
        escape.update(.landed(LandedPillInfo(text: "x", verified: true)))
        #expect(!escape.isRegistered)
        escape.update(.idle)
        #expect(stub.live.isEmpty)
        #expect(stub.installed.count == 1)
    }

    @Test(arguments: [PillState.held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed")),
                      .error(message: "Text was not typed"), .idle, .cancelled])
    func leavingTheTurnReleasesEscape(to end: PillState) {
        let (escape, stub, _) = make()
        escape.update(.listening(level: 0.3))
        #expect(escape.isRegistered)
        escape.update(end)
        #expect(!escape.isRegistered)
        #expect(stub.live.isEmpty)
    }

    @Test func aMenuTakesEscapeBackAndReturnsItOnlyInsideATurn() {
        let (escape, stub, _) = make()
        escape.update(.listening(level: 0.3))
        escape.setMenuOpen(true)
        #expect(!escape.isRegistered)
        escape.setMenuOpen(false)
        #expect(escape.isRegistered)
        #expect(escape.registrationCount == 2)
        escape.setMenuOpen(true)
        escape.update(.idle)
        escape.setMenuOpen(false)
        #expect(!escape.isRegistered, "closing a menu while idle must not register Escape")
        #expect(stub.live.isEmpty)
        #expect(!EscapeHotkey.wantsRegistration(.beforeWrite, menuOpen: true))
        #expect(EscapeHotkey.wantsRegistration(.writing, menuOpen: false))
        #expect(!EscapeHotkey.wantsRegistration(.none, menuOpen: false))
    }

    /// `@MainActor`: notifications posted off the main thread are applied with a main-queue hop.
    @MainActor
    @Test func menuTrackingNotificationsDriveTheMenuState() {
        let (escape, _, _) = make()
        let center = NotificationCenter()
        escape.observeMenuTracking(center: center)
        escape.observeMenuTracking(center: center)   // idempotent
        escape.update(.finishing(elapsedWarning: false))
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)   // a submenu
        #expect(!escape.isRegistered)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(!escape.isRegistered, "still inside the outer menu")
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(escape.isRegistered)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)   // unbalanced end
        #expect(escape.isRegistered)
    }

    @Test func theEngineMappingCoversTheLegacyPath() {
        #expect(EscapeTurnPhase(EngineState.starting) == .beforeWrite)
        #expect(EscapeTurnPhase(EngineState.listening(level: 0.1)) == .beforeWrite)
        #expect(EscapeTurnPhase(EngineState.previewing(text: "um")) == .beforeWrite)
        #expect(EscapeTurnPhase(EngineState.warning(quality)) == .beforeWrite)
        #expect(EscapeTurnPhase(EngineState.finishing) == .beforeWrite)
        // Legacy finalizing includes the write: never promise a cancel there.
        #expect(EscapeTurnPhase(EngineState.finalizing) == .writing)
        for state: EngineState in [.idle, .prewarming, .landed, .error("x"), .unavailable("x"), .cancelled] {
            #expect(EscapeTurnPhase(state) == .none)
        }
        let (escape, _, box) = make()
        escape.update(engine: .listening(level: 0.2))
        escape.press()
        #expect(box.fired == [.cancel])
        escape.update(engine: .idle)
        #expect(!escape.isRegistered)
    }

    @Test func aRefusedRegistrationIsRetriedAndNeverFires() {
        let (escape, stub, box) = make()
        stub.installSucceeds = false
        escape.update(.listening(level: 0.2))
        #expect(!escape.isRegistered)
        escape.press()
        #expect(box.fired.isEmpty)
        stub.installSucceeds = true
        escape.update(.listening(level: 0.4))
        #expect(escape.isRegistered)
    }

    @Test func deinitReleasesEscape() {
        let stub = StubEscapeKey()
        var token: Int?
        do {
            let escape = EscapeHotkey(backend: stub.backend)
            escape.update(.listening(level: 0.2))
            token = stub.installed.last
            #expect(EscapeHotkeyRegistry.owner(for: token!) === escape)
        }
        #expect(stub.live.isEmpty)
        #expect(EscapeHotkeyRegistry.owner(for: token!) == nil)
    }

    // MARK: What a press means

    @Test func beforeTheWriteEscapeCancels() {
        let (escape, _, box) = make()
        escape.update(.finalPreview(preview))
        escape.press()
        #expect(box.fired == [.cancel])
        #expect(EscapeResolution.cancelledDwell == 0.8)
    }

    @Test func afterTheWriteBeginsEscapeResolvesThenOffersUndo() {
        let (escape, _, box) = make()
        escape.update(.inserting(text: "Can we meet?"))
        escape.press()
        #expect(box.fired == [.resolveWriteThenOfferUndo])
    }

    // MARK: Double Escape is idempotent

    @Test func aSecondEscapeInTheSameTurnDoesNothing() {
        let (escape, _, box) = make()
        escape.update(.listening(level: 0.4))
        escape.press()
        escape.press()
        (0..<5).forEach { _ in escape.press() }   // key repeat
        #expect(box.fired == [.cancel])
        #expect(escape.firedCount == 1)
        #expect(escape.swallowedCount == 6)
        // The state moving on inside the same turn does not re-arm it.
        escape.update(.finishing(elapsedWarning: false))
        escape.update(.inserting(text: "x"))
        escape.press()
        #expect(box.fired == [.cancel])
        // The cancel lands: Escape goes back to the frontmost app.
        escape.update(.cancelled)
        #expect(!escape.isRegistered)
        escape.press()
        #expect(box.fired == [.cancel])
    }

    @Test func theNextTurnGetsItsOwnEscape() {
        let (escape, _, box) = make()
        escape.update(.listening(level: 0.4))
        escape.press()
        escape.update(.cancelled)
        escape.update(.idle)
        escape.update(.starting)
        escape.press()
        #expect(box.fired == [.cancel, .cancel])
    }

    /// Latch: one turn per segment. A new `TurnID` without passing idle is a new turn; the same ID is not.
    @Test func aNewTurnIDInsideTurnStatesStartsAFreshTurn() {
        let (escape, _, box) = make()
        let first = TurnID()
        escape.update(.latched(elapsed: 1), turn: first)
        escape.press()
        escape.update(.latched(elapsed: 2), turn: first)
        escape.press()
        #expect(box.fired == [.cancel])
        let second = TurnID()
        escape.update(.latched(elapsed: 3), turn: second)
        #expect(escape.turn == second)
        escape.press()
        #expect(box.fired == [.cancel, .cancel])
        #expect(escape.registrationCount == 1)
    }

    @MainActor
    @Test func aBoundPillStreamDrivesRegistration() {
        let (escape, _, box) = make()
        let states = PassthroughSubject<PillState, Never>()
        escape.bind(to: states)
        states.send(.idle)
        #expect(!escape.isRegistered)
        states.send(.starting)
        #expect(escape.isRegistered)
        escape.press()
        states.send(.cancelled)
        #expect(!escape.isRegistered)
        #expect(box.fired == [.cancel])
    }

    // MARK: Carbon dispatch (handlers only; no system hot key is registered)

    /// Every Carbon hot key reaches every handler on the application target, and a handler that
    /// answers `noErr` ends the dispatch. Escape's handler and the chord handler must each answer
    /// only for their own registration — otherwise the newest one swallows the other's presses.
    @MainActor
    @Test func escapeAndTheDictationChordEachReachOnlyTheirOwnHandler() throws {
        let stub = StubEscapeKey()
        let escape = EscapeHotkey(backend: stub.backend)
        var fired: [EscapeResolution] = []
        escape.onEscape = { fired.append($0) }
        escape.update(.listening(level: 0.3))
        let escapeToken = try #require(stub.live.first)

        let chord = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.escape.chord.\(UUID())")!)
        chord.setBinding(.controlOptionD)
        var actions: [HotkeyStateMachine.Action] = []
        chord.onAction = { actions.append($0) }
        let chordToken = HotkeyTapRegistry.register(chord)
        defer { HotkeyTapRegistry.retire(chordToken) }

        let escapeHandler = try #require(EscapeHotkey.installCarbonHandler(token: escapeToken))
        defer { RemoveEventHandler(escapeHandler) }
        // Installed second, so it is asked first: the case that used to swallow Escape.
        let chordHandler = try #require(HotkeyService.installCarbonChordHandler(token: chordToken))
        defer { RemoveEventHandler(chordHandler) }

        let escapeID = EventHotKeyID(signature: EscapeHotkey.carbonSignature, id: UInt32(escapeToken))
        let chordID = EventHotKeyID(signature: HotkeyService.carbonSignature, id: UInt32(chordToken))

        #expect(try send(kEventHotKeyPressed, id: escapeID) == noErr)
        #expect(fired == [.cancel])
        #expect(actions.isEmpty, "Escape must not read as a chord press")
        #expect(try send(kEventHotKeyReleased, id: escapeID) == OSStatus(eventNotHandledErr))
        #expect(actions.isEmpty, "Escape's release must not read as a chord key-up")

        #expect(try send(kEventHotKeyPressed, id: chordID) == noErr)
        #expect(actions == [.startCapture])
        #expect(fired == [.cancel], "a chord press must not read as Escape")

        let stranger = EventHotKeyID(signature: OSType(0x5858_5858), id: UInt32(escapeToken))
        #expect(try send(kEventHotKeyPressed, id: stranger) == OSStatus(eventNotHandledErr))
        #expect(fired == [.cancel])
        #expect(actions == [.startCapture])
    }

    @Test func hotKeyIDsMatchOnSignatureAndToken() throws {
        let id = EventHotKeyID(signature: EscapeHotkey.carbonSignature, id: 7)
        #expect(CarbonHotKeyEvent.matches(id, signature: EscapeHotkey.carbonSignature, token: 7))
        #expect(!CarbonHotKeyEvent.matches(id, signature: HotkeyService.carbonSignature, token: 7))
        #expect(!CarbonHotKeyEvent.matches(id, signature: EscapeHotkey.carbonSignature, token: 8))
        #expect(!CarbonHotKeyEvent.matches(nil, signature: EscapeHotkey.carbonSignature, token: 7))
        #expect(EscapeHotkey.carbonSignature != HotkeyService.carbonSignature)
        let event = try makeEvent(kEventHotKeyPressed, id: id)
        defer { ReleaseEvent(event) }
        let read = try #require(CarbonHotKeyEvent.id(of: event))
        #expect(read.signature == id.signature && read.id == id.id)
    }

    private func makeEvent(_ kind: Int, id: EventHotKeyID) throws -> EventRef {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0,
                                  EventAttributes(kEventAttributeNone), &event)
        #expect(created == noErr)
        let made = try #require(event)
        var hotKeyID = id
        let set = SetEventParameter(made, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        #expect(set == noErr)
        return made
    }

    private func send(_ kind: Int, id: EventHotKeyID) throws -> OSStatus {
        let event = try makeEvent(kind, id: id)
        defer { ReleaseEvent(event) }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}
