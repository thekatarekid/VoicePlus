import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// 1.6.8 — "why does VoicePlus need Input Monitoring when Claude, Wispr Flow and Gemini don't?"
///
/// It needed it for exactly one reason: `HotkeyService` used `CGEvent.tapCreate(options:.listenOnly)`,
/// the single global-input API gated on `kTCCServiceListenEvent`. Nothing about hold-to-talk, and
/// nothing about the bare-modifier gesture, requires that API.
///
/// The replacement was measured on this machine (macOS 26.6.2, arm64) from throwaway ad-hoc-signed
/// `LSUIElement` bundles with **no TCC record at all** — `tccutil` answers "No such bundle
/// identifier", and the process reports `AXIsProcessTrusted() == false` and
/// `CGPreflightListenEventAccess() == false`:
///
/// * `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` installs and **delivers**
///   (12 events across 6 real HID modifier transitions, 1.9–8.9 ms), while in the same process at the
///   same instant a `.listenOnly` tap reported `tapIsEnabled == false` and received none of them.
/// * `RegisterEventHotKey` for a chord returns `status = 0`, and a duplicate registration returns
///   `-9878` (`eventHotKeyExistsErr`) — so it really is system-wide, not a local no-op.
/// * `CGEvent.tapCreate(options: .defaultTap)` returns **NULL** outright.
///
/// These tests pin the decisions that follow from that, so a future edit cannot quietly put the
/// permission back.
@Suite("Hotkey backend selection — which mechanism, and what it costs")
struct HotkeyBackendSelectionTests {
    @Test func bareModifiersUseThePermissionFreeGlobalMonitor() {
        for kind in HotkeyBinding.Kind.allCases where kind.style == .bareModifier {
            let binding = HotkeyBinding(kind: kind)
            #expect(HotkeyBackendSelector.kind(for: binding) == .globalMonitor)
            #expect(HotkeyBackendSelector.requiredPermission(for: binding) == nil,
                    "\(kind.displayName) must cost no permission")
        }
    }

    @Test func chordsUseCarbonAndAlsoCostNothing() {
        for kind in HotkeyBinding.Kind.allCases where kind.style == .chord {
            let binding = HotkeyBinding(kind: kind)
            #expect(HotkeyBackendSelector.kind(for: binding) == .carbon)
            #expect(HotkeyBackendSelector.requiredPermission(for: binding) == nil)
        }
    }

    /// The escape hatch is the *only* way back to Input Monitoring — and it cannot capture a chord,
    /// which an event tap on `flagsChanged` would never see anyway.
    @Test func onlyTheForcedEventTapCostsInputMonitoring() {
        #expect(HotkeyBackendSelector.kind(for: HotkeyBinding(kind: .rightOption), forceEventTap: true) == .eventTap)
        #expect(HotkeyBackendSelector.requiredPermission(for: HotkeyBinding(kind: .rightOption), forceEventTap: true)
                == .inputMonitoring)
        #expect(HotkeyBackendSelector.kind(for: HotkeyBinding(kind: .controlOptionD), forceEventTap: true) == .carbon,
                "forcing the tap must not silently break a chord binding")
    }

    @Test func onlyTheEventTapDemandsAPermissionOrARelaunch() {
        #expect(HotkeyBackendKind.globalMonitor.requiredPermission == nil)
        #expect(HotkeyBackendKind.carbon.requiredPermission == nil)
        #expect(HotkeyBackendKind.eventTap.requiredPermission == .inputMonitoring)
        #expect(!HotkeyBackendKind.globalMonitor.needsRelaunchAfterGrant)
        #expect(!HotkeyBackendKind.carbon.needsRelaunchAfterGrant)
        // The forced quit-and-relaunch is a property of `kTCCServiceListenEvent` specifically —
        // Apple's own `PrivacyTCCServices.plist` carries `quitAllowTitleForAppName` for it and has
        // no entry for Accessibility at all. Dropping the service drops the relaunch with it.
        #expect(HotkeyBackendKind.eventTap.needsRelaunchAfterGrant)
    }

    /// The default binding — what an install with no stored choice gets — must be free.
    @Test func theShippedDefaultCostsNothing() {
        #expect(HotkeyBinding.default.kind == .rightOption)
        #expect(HotkeyBackendSelector.requiredPermission(for: .default) == nil)
    }
}

@Suite("Chord constants and the RegisterEventHotKey trap")
struct HotkeyChordTests {
    /// `App/Core` stays free of Carbon, so the modifier masks and key codes are written out by hand
    /// there. A typo would not fail to compile — it would register a hotkey that never fires. This
    /// is the test that makes that impossible.
    @Test func handWrittenCarbonConstantsMatchTheRealOnes() {
        #expect(HotkeyBinding.Chord.command == UInt32(cmdKey))
        #expect(HotkeyBinding.Chord.shift == UInt32(shiftKey))
        #expect(HotkeyBinding.Chord.option == UInt32(optionKey))
        #expect(HotkeyBinding.Chord.control == UInt32(controlKey))
        #expect(HotkeyBinding.Chord.keyD == UInt32(kVK_ANSI_D))
        #expect(HotkeyBinding.Chord.keyA == UInt32(kVK_ANSI_A))
    }

    @Test func chordBindingsCarryARegistrationAndModifiersDoNot() throws {
        let d = try #require(HotkeyBinding.Kind.controlOptionD.chord)
        #expect(d.keyCode == UInt32(kVK_ANSI_D))
        #expect(d.carbonModifiers == UInt32(controlKey | optionKey))
        let a = try #require(HotkeyBinding.Kind.controlOptionA.chord)
        #expect(a.keyCode == UInt32(kVK_ANSI_A))
        // The trap: `RegisterEventHotKey(kVK_RightOption, 0)` returns noErr with a valid ref and then
        // never fires — measured, 0 callbacks across real modifier transitions. Anything that tests
        // only the return code concludes it works. So a bare modifier must never even reach it.
        for kind in HotkeyBinding.Kind.allCases where kind.style == .bareModifier {
            #expect(kind.chord == nil, "\(kind.displayName) must never be handed to RegisterEventHotKey")
        }
    }

    /// The installer's own guard, not just the data: it refuses before touching Carbon.
    @Test func theCarbonInstallerRefusesABareModifier() {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.carbon.\(UUID())")!)
        let token = HotkeyTapRegistry.register(service)
        defer { HotkeyTapRegistry.retire(token) }
        #expect(service.binding.style == .bareModifier)
        #expect(HotkeyService.chord(for: token) == nil)
        #expect(HotkeyService.installCarbonHotKey(token: token) == nil)
    }

    /// A chord has no flags word, so the modifier classifier must decline it rather than guess.
    @Test func chordBindingsProduceNoModifierEdge() {
        let binding = HotkeyBinding(kind: .controlOptionD)
        #expect(binding.edge(keyCode: 2, flags: CGEventFlags.maskControl.rawValue) == nil)
        #expect(binding.edge(keyCode: -1, flags: 0) == nil)
    }
}

/// `@MainActor` because `HotkeyService.deliverChord` hops to the main thread the way the real Carbon
/// handler's delivery does — a test on some other thread would only ever queue the work.
@Suite("The state machine, driven by synthetic Carbon press/release")
@MainActor
struct CarbonDrivenStateMachineTests {
    private func service() -> HotkeyService {
        let s = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.chord.\(UUID())")!)
        s.setBinding(.controlOptionD)
        return s
    }

    /// `kEventHotKeyPressed` → `kEventHotKeyReleased` is exactly the down/up pair hold-to-talk needs,
    /// and the timings are the Muesli-validated ones the tap path used: hold 250 ms, tap guard
    /// 180 ms, double-tap window 350 ms. The recogniser is untouched by the backend change.
    @Test func chordHoldStartsAndFinalizes() {
        let s = service()
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        s.handleChord(down: true, timestamp: 100)
        s.handleChord(down: false, timestamp: 100.6)
        #expect(actions == [.startCapture, .finalize])
    }

    @Test func chordHoldExactlyAtThresholdStillFinalizes() {
        let s = service()
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        s.handleChord(down: true, timestamp: 5)
        s.handleChord(down: false, timestamp: 5.250)
        #expect(actions == [.startCapture, .finalize])
    }

    @Test func chordDoubleTapEntersHandsFreeAndTheNextPressFinalizes() {
        let s = service()
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        s.handleChord(down: true, timestamp: 0)
        s.handleChord(down: false, timestamp: 0.05)      // guarded tap
        s.handleChord(down: true, timestamp: 0.2)
        s.handleChord(down: false, timestamp: 0.25)      // second tap, inside the 350 ms window
        #expect(actions == [.startCapture, .cancelCapture, .startCapture, .enterHandsFree])
        #expect(s.machine.phase == .handsFree)
        s.handleChord(down: true, timestamp: 3)
        #expect(actions.last == .finalize)
    }

    @Test func pausedAndMismatchedBindingsDropChordEdges() {
        let s = service()
        var fired = false
        s.onAction = { _ in fired = true }
        s.isPaused = true
        s.handleChord(down: true, timestamp: 0)
        #expect(!fired)
        s.isPaused = false
        s.setBinding(.rightOption)      // a bare modifier must not answer Carbon edges
        s.handleChord(down: true, timestamp: 1)
        #expect(!fired)
    }

    /// The registry hop the real Carbon handler uses: a token that no longer resolves reaches
    /// nothing, exactly as on the tap path.
    @Test func deliverChordThroughTheRegistryAndThenThroughARetiredToken() {
        let s = service()
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        let token = HotkeyTapRegistry.register(s)
        HotkeyService.deliverChord(token: token, down: true, timestamp: 0)
        HotkeyService.deliverChord(token: token, down: false, timestamp: 0.5)
        #expect(actions == [.startCapture, .finalize])
        HotkeyTapRegistry.retire(token)
        HotkeyService.deliverChord(token: token, down: true, timestamp: 1)
        #expect(actions == [.startCapture, .finalize], "a retired token must reach nothing")
    }
}

@Suite("Backend lifecycle and binding migration")
struct HotkeyBackendLifecycleTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "AppTests.migrate.\(UUID())")! }

    /// Every binding a 1.6.7 install can have stored survives verbatim — and now costs nothing.
    /// A user who picked Right ⌥ keeps Right ⌥; nobody is silently moved to a chord.
    @Test func everyStoredBindingFrom167SurvivesAndBecomesFree() {
        for kind in [HotkeyBinding.Kind.rightOption, .leftOption, .rightCommand, .rightControl, .fn] {
            let d = defaults()
            d.set(kind.rawValue, forKey: HotkeyService.bindingDefaultsKey)
            let service = HotkeyService(defaults: d)
            #expect(service.binding.kind == kind)
            #expect(service.backendKind == .globalMonitor)
            #expect(service.requiredPermission == nil)
            #expect(HotkeyService.currentRequiredPermission(defaults: d) == nil)
        }
    }

    @Test func anUnreadableStoredBindingFallsBackToTheDefaultRatherThanNoBinding() {
        let d = defaults()
        d.set("someFutureKey", forKey: HotkeyService.bindingDefaultsKey)
        let service = HotkeyService(defaults: d)
        #expect(service.binding.kind == .rightOption)
        #expect(service.requiredPermission == nil)
    }

    /// The act key keeps its own stored binding and its own default.
    @Test func theActKeyMigratesIndependently() {
        let d = defaults()
        d.set(HotkeyBinding.Kind.rightCommand.rawValue, forKey: HotkeyService.actBindingDefaultsKey)
        let act = HotkeyService(defaults: d, bindingKey: HotkeyService.actBindingDefaultsKey,
                                defaultBinding: HotkeyBinding(kind: .rightCommand))
        #expect(act.binding.kind == .rightCommand)
        #expect(act.requiredPermission == nil)
        #expect(HotkeyService.currentRequiredPermission(defaults: d,
                                                        bindingKey: HotkeyService.actBindingDefaultsKey) == nil)
    }

    @Test func theEscapeHatchIsTheOnlyThingThatBringsInputMonitoringBack() {
        let d = defaults()
        #expect(HotkeyService(defaults: d).requiredPermission == nil)
        d.set(true, forKey: HotkeyService.forceEventTapDefaultsKey)
        let forced = HotkeyService(defaults: d)
        #expect(forced.forcesEventTap)
        #expect(forced.backendKind == .eventTap)
        #expect(forced.requiredPermission == .inputMonitoring)
        #expect(HotkeyService.currentRequiredPermission(defaults: d) == .inputMonitoring)
    }

    /// Moving between a modifier and a chord changes the *mechanism*, so an armed service has to
    /// re-install rather than merely re-interpret the events it already receives.
    @Test func changingStyleWhileArmedReinstallsTheSource() {
        let stub = StubEventTap()
        let service = HotkeyService(defaults: defaults())
        service.installer = stub.installer
        #expect(service.start())
        #expect(service.armCount == 1)
        service.setBinding(.rightControl)          // same style — no re-install
        #expect(service.armCount == 1)
        service.setBinding(.controlOptionD)        // modifier → chord
        #expect(service.armCount == 2)
        #expect(stub.liveTaps.count == 1, "a style change must not stack a second source")
        service.stop()
        #expect(stub.liveTaps.isEmpty)
    }

    @Test func aSettingsSideBindingChangeReachesARunningService() {
        let d = defaults()
        let stub = StubEventTap()
        let service = HotkeyService(defaults: d)
        service.installer = stub.installer
        #expect(service.start())
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        #expect(service.reloadBindingFromDefaults())
        #expect(service.binding.kind == .fn)
        #expect(!service.reloadBindingFromDefaults(), "a second read with nothing new is a no-op")
    }

    /// The Carbon backend fires only on its own chord, so "armed but no modifier events" says
    /// nothing about it and must never be read as deafness — that would produce an endless re-arm.
    @Test func chordBackendNeverReportsItselfDead() {
        let stub = StubEventTap()
        stub.kind = .carbon
        let service = HotkeyService(defaults: defaults())
        service.setBinding(.controlOptionD)
        service.installer = stub.installer
        var now = Date(timeIntervalSince1970: 1_000)
        service.clock = { now }
        service.systemModifierIdle = { 1 }          // the system saw modifiers a second ago
        #expect(service.start())
        now = now.addingTimeInterval(TapLiveness.grace + 10)
        #expect(service.livenessVerdict == .unknown)
    }
}

@Suite("What NSEvent hands us is what the tap handed us")
struct HotkeyFlagWordParityTests {
    /// The one thing that had to be true for the swap to be safe: `NSEvent.keyCode` and
    /// `NSEvent.modifierFlags.rawValue` are the same values the (production-proven) tap path read off
    /// the `CGEvent`, so `HotkeyBinding.edge(keyCode:flags:)` serves both without a translation
    /// layer.
    ///
    /// Measured at zero grants on real HID modifier transitions: 12/12 events matched on both fields
    /// (`ns.keyCode == cg.keyCode`, `ns.flags == cg.flags`, e.g. `0x10100` then `0x100`). This test
    /// pins the same equivalence headlessly, on a constructed event.
    @Test func nsEventReportsTheSameKeyCodeAndFlagWordAsTheUnderlyingCGEvent() throws {
        let cg = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true))
        cg.type = .flagsChanged
        cg.flags = [.maskAlternate]
        let ns = try #require(NSEvent(cgEvent: cg))
        #expect(Int64(ns.keyCode) == cg.getIntegerValueField(.keyboardEventKeycode))
        #expect(UInt64(ns.modifierFlags.rawValue) == cg.flags.rawValue)
        // And the classifier agrees, whichever of the two words it is handed.
        let binding = HotkeyBinding(kind: .rightOption)
        #expect(binding.edge(keyCode: Int64(ns.keyCode), flags: UInt64(ns.modifierFlags.rawValue)) == .down)
        #expect(binding.edge(keyCode: cg.getIntegerValueField(.keyboardEventKeycode), flags: cg.flags.rawValue) == .down)
    }

    /// The release edge, which is what makes hold-to-talk possible at all.
    @Test func clearingTheModifierBitIsTheUpEdge() {
        let binding = HotkeyBinding(kind: .rightOption)
        #expect(binding.edge(keyCode: 61, flags: 0x0000_0100) == .up)   // the observed "released" word
        #expect(binding.edge(keyCode: 61, flags: 0x0008_0100) == .down)
    }
}
