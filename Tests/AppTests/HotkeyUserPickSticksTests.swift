import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// Owner report 2026-10-03: picked fn / 🌐 in Settings › Shortcuts, Option kept dictating.
///
/// 1.15.1 ran the X1 fn→Option migration lazily inside `storedBinding`, behind a guard that
/// returned early when nothing was stored. An install that never stored a key kept the migration
/// flag unset, so the owner's own fn write (the first value ever stored) was taken for a legacy fn
/// and rewritten to Option by the `didChangeNotification` reload, while Settings kept saying
/// "fn / 🌐 is now your dictation key". Log: "binding changed externally to fn / 🌐" →
/// "dictation key moves from fn to Option" → "binding changed externally to ⌥ Option".
@Suite("Hotkey — a user's key pick sticks (X1 migration is eager and one-shot)", .serialized)
struct HotkeyUserPickSticksTests {
    private static let alt = CGEventFlags.maskAlternate.rawValue
    private static let fnFlag = CGEventFlags.maskSecondaryFn.rawValue

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "AppTests.userPick.\(UUID())")! }

    // MARK: The owner's exact sequence

    @Test("fresh install (nothing stored), then the user picks fn: the service binds fn and the store keeps fn")
    func aUserPickOfFnAfterAFreshInstallSticks() {
        let d = defaults()
        let service = HotkeyService(defaults: d)
        #expect(service.binding.kind == .option, "nothing stored → the Option default")
        // Settings › Shortcuts writes the binding key; the running service reloads it.
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn", "the user's write is never rewritten")
        // A relaunch keeps it too.
        #expect(HotkeyService(defaults: d).binding.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn")
    }

    @Test("the same pick through the live didChangeNotification path sticks")
    @MainActor
    func aUserPickThroughTheObserverSticks() async {
        let d = defaults()
        let service = HotkeyService(defaults: d)
        service.observeDefaults()
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        // The observer is on the main queue; let it run if it was not delivered inline.
        for _ in 0..<50 where service.binding.kind != .fn { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(service.binding.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn")
    }

    @Test("after picking fn, Option no longer dictates and fn does")
    func onlyTheBoundKeyStartsDictation() {
        let d = defaults()
        let service = HotkeyService(defaults: d)
        service.otherInputWithin = { _ in false }
        service.surfaceShowing = { false }
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()

        // Left and right Option holds: not the bound key any more.
        service.handle(keyCode: 58, flags: Self.alt | HotkeyBinding.Kind.deviceLeftAltMask, timestamp: 0)
        service.handle(keyCode: 58, flags: 0, timestamp: 0.6)
        service.handle(keyCode: 61, flags: Self.alt | HotkeyBinding.Kind.deviceRightAltMask, timestamp: 1)
        service.handle(keyCode: 61, flags: 0, timestamp: 1.6)
        #expect(actions.isEmpty, "Option must not dictate once fn is bound")

        service.handle(keyCode: 63, flags: Self.fnFlag, timestamp: 2)
        service.handle(keyCode: 63, flags: 0, timestamp: 2.6)
        #expect(actions == [.startCapture, .finalize])
    }

    @Test("a running service switched Option → fn → Option at runtime follows every pick, and the Option-tap wait is dropped while fn is bound")
    func runtimeSwitchBackAndForth() {
        let d = defaults()
        let stub = StubEventTap()
        let service = HotkeyService(defaults: d)
        service.installer = stub.installer
        service.otherInputWithin = { _ in false }
        service.surfaceShowing = { false }
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        #expect(service.start())
        // The Option tap is waiting for Accessibility (the state a fresh install arms in).
        service.record(.untrusted)
        #expect(service.awaitingAccessibilityForOptionTap)

        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .fn)
        #expect(!service.awaitingAccessibilityForOptionTap, "fn bound: no Option tap may arm later")
        #expect(!service.tapFeeds, "fn bound: the passive monitors feed the key, nothing drops Option")
        service.retryOptionTapIfWaiting()
        #expect(service.optionTap == nil)
        service.handle(keyCode: 58, flags: Self.alt | HotkeyBinding.Kind.deviceLeftAltMask, timestamp: 0)
        service.handle(keyCode: 58, flags: 0, timestamp: 0.6)
        #expect(actions.isEmpty)

        d.set(HotkeyBinding.Kind.option.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .option)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "option")
        service.handle(keyCode: 63, flags: Self.fnFlag, timestamp: 2)
        service.handle(keyCode: 63, flags: 0, timestamp: 2.6)
        #expect(actions.isEmpty, "fn no longer dictates once Option is picked back")
        service.handle(keyCode: 61, flags: Self.alt | HotkeyBinding.Kind.deviceRightAltMask, timestamp: 4)
        service.handle(keyCode: 61, flags: 0, timestamp: 4.6)
        #expect(actions == [.startCapture, .finalize], "either Option dictates again")

        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn", "a second fn pick sticks too")
        #expect(stub.liveTaps.count == 1, "switching never stacks a second source")
        service.stop()
    }

    // MARK: The migration itself

    @Test("the migration sets its flag even when nothing is stored, and writes no binding")
    func migrationSetsItsFlagEvenWithNothingStored() {
        let d = defaults()
        #expect(!HotkeyService.migrateLegacyBindingIfNeeded(defaults: d))
        #expect(d.bool(forKey: HotkeyService.optionMigrationDefaultsKey))
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == nil)
    }

    @Test("constructing the dictation service runs the migration before anything can be written")
    func constructingTheServiceSetsTheFlag() {
        let d = defaults()
        _ = HotkeyService(defaults: d)
        #expect(d.bool(forKey: HotkeyService.optionMigrationDefaultsKey))
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == nil, "resolving the default writes nothing")
    }

    @Test("the act key's service does not run the dictation-key migration")
    func theActServiceLeavesTheFlagAlone() {
        let d = defaults()
        _ = HotkeyService(defaults: d, bindingKey: HotkeyService.actBindingDefaultsKey,
                          defaultBinding: HotkeyBinding(kind: .rightCommand))
        #expect(!d.bool(forKey: HotkeyService.optionMigrationDefaultsKey))
    }

    @Test("a legacy stored fn moves to Option exactly once; a later fn is kept")
    func migrationRunsOnceOnALegacyFn() {
        let d = defaults()
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        #expect(HotkeyService.migrateLegacyBindingIfNeeded(defaults: d))
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "option")
        #expect(d.bool(forKey: HotkeyService.optionMigrationDefaultsKey))

        let service = HotkeyService(defaults: d)
        #expect(service.binding.kind == .option)
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .fn)
        #expect(!HotkeyService.migrateLegacyBindingIfNeeded(defaults: d))
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn")
    }

    @Test("storedBinding is a pure read: it never writes the binding or the flag")
    func storedBindingIsAPureRead() {
        let d = defaults()
        d.set(HotkeyBinding.Kind.fn.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        #expect(HotkeyService.storedBinding(defaults: d, key: HotkeyService.bindingDefaultsKey)?.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn")
        #expect(d.object(forKey: HotkeyService.optionMigrationDefaultsKey) == nil)
        #expect(HotkeyService.currentRequiredPermission(defaults: d) == nil)
        #expect(d.object(forKey: HotkeyService.optionMigrationDefaultsKey) == nil)
    }

    @Test("the owner's install as found (choice fn, binding option, flag set): a re-pick of fn now sticks")
    func theOwnersInstallRecoversOnARePick() {
        let d = defaults()
        d.set("fn", forKey: "hotkey.choice")
        d.set("option", forKey: HotkeyService.bindingDefaultsKey)
        d.set(true, forKey: HotkeyService.optionMigrationDefaultsKey)
        let service = HotkeyService(defaults: d)
        #expect(service.binding.kind == .option, "no automatic flip of what is bound")
        d.set("fn", forKey: HotkeyService.bindingDefaultsKey)
        service.reloadBindingFromDefaults()
        #expect(service.binding.kind == .fn)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == "fn")
    }
}

/// The Settings pane shows the key the service runs, not just the key it last wrote.
@Suite("Settings — the dictation key copy follows the stored binding")
@MainActor
struct SettingsHotkeyReadBackTests {
    /// A store that rewrites a written fn binding to Option, the way 1.15.1's service did.
    final class RewritingStore: SettingsStore {
        let inner = InMemorySettingsStore()
        var rewritesFn = true
        func string(_ key: String) -> String? { inner.string(key) }
        func bool(_ key: String) -> Bool? { inner.bool(key) }
        func set(_ value: Bool, for key: String) { inner.set(value, for: key) }
        func set(_ value: String?, for key: String) {
            if rewritesFn, key == HotkeyService.bindingDefaultsKey, value == "fn" {
                inner.set("option", for: key)
            } else {
                inner.set(value, for: key)
            }
        }
    }

    private func general(_ store: SettingsStore) -> GeneralSettingsViewModel {
        GeneralSettingsViewModel(store: store, fnConflict: { _ in nil }, openKeyboardSettings: {},
                                 applyTheme: { _ in }, shellFolderPrompt: {})
    }

    @Test("a pick that does not stick is not reported as the new key")
    func applyReportsWhatIsActuallyBound() {
        let store = RewritingStore()
        let g = general(store)
        #expect(g.hotkey == .option)
        let change = g.apply(.key(.fn))
        #expect(change == .unchanged(.option), "never \"fn / 🌐 is now your dictation key\" while Option is bound")
        #expect(g.hotkey == .option)
        #expect(g.hotkeyLabel == HotkeyChoice.option.label)
        #expect(store.string(SettingsKeys.hotkey) == "option", "the choice mirror agrees with the binding")
    }

    @Test("a pick that sticks is reported as a change and both keys agree")
    func applyReportsAStickingPick() {
        let store = InMemorySettingsStore()
        let g = general(store)
        let change = g.apply(.key(.fn))
        #expect(change == .changed(from: .option, to: .fn))
        #expect(g.hotkey == .fn)
        #expect(store.string(HotkeyService.bindingDefaultsKey) == "fn")
        #expect(store.string(SettingsKeys.hotkey) == "fn")
    }

    @Test("an outside write of the binding shows up in the pane without being written back")
    func syncFollowsAnOutsideWrite() {
        let store = InMemorySettingsStore()
        let g = general(store)
        g.hotkey = .fn
        store.set("option", for: HotkeyService.bindingDefaultsKey)
        #expect(g.syncHotkeyFromStore())
        #expect(g.hotkey == .option)
        #expect(store.string(HotkeyService.bindingDefaultsKey) == "option")
        #expect(store.string(SettingsKeys.hotkey) == "option")
        #expect(!g.syncHotkeyFromStore(), "nothing left to sync")
    }

    @Test("nothing bound yet but a legacy fn mirror: the pane shows the Option default, and picking fn binds fn")
    func unsetBindingShowsTheServiceDefault() {
        let store = InMemorySettingsStore()
        store.set("fn", for: SettingsKeys.hotkey)
        let g = general(store)
        #expect(g.hotkey == .option, "the service runs Option; the pane must not claim fn")
        let change = g.apply(.key(.fn))
        #expect(change == .changed(from: .option, to: .fn), "a fn pick is a real change, never a no-op")
        #expect(store.string(HotkeyService.bindingDefaultsKey) == "fn")
        #expect(store.string(SettingsKeys.hotkey) == "fn")
    }

    @Test("the pane opens on the bound key even when the choice mirror disagrees")
    func initPrefersTheBinding() {
        let store = InMemorySettingsStore()
        store.set("fn", for: SettingsKeys.hotkey)
        store.set("option", for: HotkeyService.bindingDefaultsKey)
        #expect(general(store).hotkey == .option)
    }
}
