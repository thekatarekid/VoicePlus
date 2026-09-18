import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// I1 (V4.51) — fn / 🌐 is the default dictation key; a stored binding wins; every hint names the
/// configured key; macOS's own 🌐 action is surfaced as a conflict.
@Suite("I1 — fn default, labels and the 🌐 conflict")
struct HotkeyFnDefaultTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "AppTests.fnDefault.\(UUID())")! }

    // MARK: Default resolution

    @Test func theDefaultIsFn() {
        #expect(HotkeyService.defaultBinding.kind == .fn)
        #expect(HotkeyBinding.default == HotkeyService.defaultBinding)
        #expect(HotkeyBinding().kind == .fn)
    }

    @Test func aFreshInstallResolvesToFnAtNoPermissionCost() {
        let d = defaults()
        let service = HotkeyService(defaults: d)
        #expect(service.binding.kind == .fn)
        #expect(service.backendKind == .globalMonitor)
        #expect(service.requiredPermission == nil)
        #expect(HotkeyService.currentRequiredPermission(defaults: d) == nil)
        #expect(d.string(forKey: HotkeyService.bindingDefaultsKey) == nil, "resolving the default writes nothing")
    }

    @Test func aFreshServiceAnswersFnEdgesAndIgnoresRightOption() {
        let service = HotkeyService(defaults: defaults())
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        service.handle(keyCode: 61, flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
        service.handle(keyCode: 61, flags: 0, timestamp: 0.5)
        #expect(actions.isEmpty, "Right ⌥ is no longer the default")
        service.handle(keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue, timestamp: 1)
        service.handle(keyCode: 63, flags: 0, timestamp: 1.4)
        #expect(actions == [.startCapture, .finalize])
    }

    /// The act key keeps its own default; only the dictation key moved.
    @Test func theActKeyKeepsItsOwnDefault() {
        let act = HotkeyService(defaults: defaults(), bindingKey: HotkeyService.actBindingDefaultsKey,
                                defaultBinding: HotkeyBinding(kind: .rightCommand))
        #expect(act.binding.kind == .rightCommand)
    }

    // MARK: Stored binding precedence

    @Test(arguments: HotkeyBinding.Kind.allCases)
    func aStoredBindingWinsOverTheDefault(kind: HotkeyBinding.Kind) {
        let d = defaults()
        d.set(kind.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        #expect(HotkeyService(defaults: d).binding.kind == kind)
    }

    /// A 1.10 user who picked Right ⌥ keeps it after the upgrade.
    @Test func anExplicitRightOptionSurvivesTheNewDefault() {
        let d = defaults()
        let old = HotkeyService(defaults: d)
        old.setBinding(.rightOption)
        let upgraded = HotkeyService(defaults: d)
        #expect(upgraded.binding.kind == .rightOption)
        #expect(upgraded.label == "Right Option")
    }

    @Test func anUnreadableStoredValueFallsBackToFn() {
        let d = defaults()
        d.set("someFutureKey", forKey: HotkeyService.bindingDefaultsKey)
        #expect(HotkeyService(defaults: d).binding.kind == .fn)
    }

    // MARK: Label interpolation

    @Test func theHintNamesFn() {
        #expect(HotkeyBinding.default.label == "fn / 🌐")
        #expect(HotkeyBinding.default.readyHint() == "Hold or Double Tap fn / 🌐 to dictate")
        #expect(HotkeyBinding.default.readyHint(latchEnabled: false) == "Hold fn / 🌐 to dictate")
        let service = HotkeyService(defaults: defaults())
        #expect(service.label == "fn / 🌐")
        #expect(service.readyHint() == "Hold or Double Tap fn / 🌐 to dictate")
        #expect(service.readyHint(latchEnabled: false) == "Hold fn / 🌐 to dictate")
    }

    @Test func theHintFollowsTheStoredKey() {
        let d = defaults()
        d.set(HotkeyBinding.Kind.controlOptionD.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        let service = HotkeyService(defaults: d)
        #expect(service.readyHint() == "Hold or Double Tap Control + Option + D to dictate")
        service.setBinding(.rightCommand)
        #expect(service.readyHint(latchEnabled: false) == "Hold Right Command to dictate")
    }

    @Test func everyKeyHasItsOwnReadableLabel() {
        let labels = HotkeyBinding.Kind.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        for kind in HotkeyBinding.Kind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(!kind.label.contains(kind.rawValue) || kind == .fn, "no raw enum token in copy: \(kind.label)")
        }
    }

    /// Fixture-verified: every prototype sentence naming "Right Control" renders with the key's label
    /// and nothing else changes; the design's own key renders the fixture verbatim.
    @Test func everyRightControlSentenceInTheCopyFixtureRendersWithTheConfiguredKey() throws {
        let sentences = try Self.fixtureSentences(containing: PillCopy.prototypeHotkey)
        #expect(sentences.count >= 6)
        #expect(sentences.contains("Hold or Double Tap Right Control to dictate"))
        for sentence in sentences {
            #expect(HotkeyBinding(kind: .rightControl).rendering(sentence) == sentence)
            let fn = HotkeyBinding.default.rendering(sentence)
            #expect(!fn.contains("Right Control"))
            #expect(fn == sentence.replacingOccurrences(of: "Right Control", with: "fn / 🌐"))
        }
        #expect(HotkeyBinding.default.rendering("Hold or Double Tap Right Control to dictate")
                == HotkeyBinding.default.readyHint())
    }

    private static func fixtureSentences(containing needle: String) throws -> Set<String> {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        var found = Set<String>()
        func walk(_ value: Any) {
            switch value {
            case let s as String where s.contains(needle): found.insert(s)
            case let array as [Any]: array.forEach(walk)
            case let dict as [String: Any]: dict.values.forEach(walk)
            default: break
            }
        }
        walk(try JSONSerialization.jsonObject(with: data))
        return found
    }

    // MARK: The 🌐 system-action conflict, from a fake defaults domain

    private func fnDefaults(_ value: Any?) -> UserDefaults {
        let d = defaults()
        if let value { d.set(value, forKey: FnKeySystemAction.defaultsKey) }
        return d
    }

    @Test func doNothingIsTheOnlyValueWithoutAConflict() {
        let service = HotkeyService(defaults: defaults())
        service.fnUsage = .defaults(fnDefaults(0))
        #expect(service.fnSystemAction == .doNothing)
        #expect(!service.fnSystemActionConflict)
        #expect(service.fnConflict == nil)
    }

    @Test(arguments: [(1, FnKeySystemAction.changeInputSource), (2, .showEmojiAndSymbols),
                      (3, .startDictation), (7, .unrecognised(7))])
    func anyOtherValueIsAConflict(value: Int, action: FnKeySystemAction) throws {
        let service = HotkeyService(defaults: defaults())
        service.fnUsage = .defaults(fnDefaults(value))
        #expect(service.fnSystemAction == action)
        #expect(service.fnSystemActionConflict)
        let conflict = try #require(service.fnConflict)
        #expect(conflict.systemAction == action)
        #expect(action.usageType == value)
    }

    /// No value stored means macOS's own default, which is an action — still a conflict.
    @Test func aMissingValueIsAConflict() {
        let service = HotkeyService(defaults: defaults())
        service.fnUsage = .defaults(fnDefaults(nil))
        #expect(service.fnSystemAction == .systemDefault)
        #expect(service.fnSystemActionConflict)
    }

    @Test func aStringValueIsReadToo() {
        #expect(FnKeySystemAction(usageType: FnUsageReader.defaults(fnDefaults("0")).read()) == .doNothing)
        #expect(FnKeySystemAction(usageType: FnUsageReader.defaults(fnDefaults("2")).read()) == .showEmojiAndSymbols)
    }

    /// The conflict is about fn only: with another key bound, 🌐's own action is none of our business.
    @Test func noConflictWhenTheKeyIsNotFn() {
        let d = defaults()
        d.set(HotkeyBinding.Kind.rightOption.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        let service = HotkeyService(defaults: d)
        service.fnUsage = .defaults(fnDefaults(2))
        #expect(!service.fnSystemActionConflict)
        #expect(HotkeyService.fnConflict(for: HotkeyBinding(kind: .rightOption), reader: .defaults(fnDefaults(2))) == nil)
        #expect(HotkeyService.fnConflict(for: .default, reader: .defaults(fnDefaults(2))) != nil)
    }

    /// Read fresh every time: the user changes it in System Settings while the app runs.
    @Test func theFlagFollowsALiveChange() {
        let store = fnDefaults(2)
        let service = HotkeyService(defaults: defaults())
        service.fnUsage = .defaults(store)
        #expect(service.fnSystemActionConflict)
        store.set(0, forKey: FnKeySystemAction.defaultsKey)
        #expect(!service.fnSystemActionConflict)
    }

    @Test func theConflictPromptIsProblemThenAction() throws {
        let conflict = try #require(FnKeyConflict(.showEmojiAndSymbols))
        #expect(conflict.headline == "The 🌐 key also shows Emoji & Symbols")
        #expect(conflict.detail.contains("Do Nothing"))
        #expect(FnKeyConflict.actionTitle == "Open Keyboard settings")
        #expect(FnKeyConflict.keyboardSettingsURL.scheme == "x-apple.systempreferences")
        #expect(FnKeyConflict(.doNothing) == nil)
        for action in [FnKeySystemAction.changeInputSource, .startDictation, .systemDefault, .unrecognised(9)] {
            let headline = try #require(FnKeyConflict(action)).headline
            #expect(headline.hasPrefix("The 🌐 key also "))
            #expect(!headline.contains("unrecognised") && !headline.contains("systemDefault"))
        }
    }

    /// The production reader touches only the preferences API; whatever this machine has set, it
    /// must answer without crashing and agree with the domain it names.
    @Test func theSystemReaderReadsTheHIToolboxDomain() {
        let value = FnUsageReader.system.read()
        let direct = UserDefaults(suiteName: FnKeySystemAction.defaultsDomain)?.object(forKey: FnKeySystemAction.defaultsKey)
        #expect(value == FnUsageReader.integer(direct))
    }

    // MARK: No fn event → offer Right ⌥ (S8's key test)

    @Test func threePressesWithoutAnFnEventOfferRightOption() {
        var probe = FnKeyProbe()
        #expect(probe.verdict == .waiting(attempts: 0))
        #expect(probe.notePromptedPress() == .waiting(attempts: 1))
        #expect(probe.notePromptedPress() == .waiting(attempts: 2))
        #expect(probe.notePromptedPress() == .offerFallback(.rightOption))
        #expect(probe.notePromptedPress() == .offerFallback(.rightOption), "the count stops at the offer")
        #expect(probe.attempts == FnKeyProbe.attemptsBeforeFallback)
    }

    @Test func oneFnEventConfirmsTheKey() {
        var probe = FnKeyProbe()
        probe.notePromptedPress()
        probe.notePromptedPress()
        #expect(probe.noteFnEvent() == .confirmed)
        #expect(probe.notePromptedPress() == .confirmed)
        probe.reset()
        #expect(probe.verdict == .confirmed, "a confirmation survives Try again")

        var late = FnKeyProbe()
        (0..<3).forEach { _ in late.notePromptedPress() }
        #expect(late.noteFnEvent() == .confirmed, "an fn event after the offer still confirms fn")
    }

    @Test func tryAgainForgetsTheAttempts() {
        var probe = FnKeyProbe()
        (0..<3).forEach { _ in probe.notePromptedPress() }
        probe.reset()
        #expect(probe.verdict == .waiting(attempts: 0))
    }

    /// The service counts fn edges whatever key is bound, so the key test has a signal.
    @MainActor
    @Test func theServiceCountsFnEdgesFromItsSource() throws {
        let stub = StubEventTap()
        let d = defaults()
        d.set(HotkeyBinding.Kind.rightOption.rawValue, forKey: HotkeyService.bindingDefaultsKey)
        let service = HotkeyService(defaults: d)
        service.installer = stub.installer
        var callbacks = 0
        service.onFnEvent = { callbacks += 1 }
        #expect(service.start())
        let token = try #require(service.tapToken)
        HotkeyService.deliver(token: token, keyCode: 61, flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
        #expect(service.fnEventsSeen == 0)
        HotkeyService.deliver(token: token, keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue, timestamp: 1)
        HotkeyService.deliver(token: token, keyCode: 63, flags: 0, timestamp: 1.1)
        #expect(service.fnEventsSeen == 2)
        #expect(callbacks == 2)
        var probe = FnKeyProbe()
        if service.fnEventsSeen > 0 { probe.noteFnEvent() }
        #expect(probe.verdict == .confirmed)
        service.stop()
    }
}
