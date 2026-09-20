import Actions
import AppKit
import Engine
import Foundation
import Lab
import Pipeline
import Providers
import Shared
import Sync
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S7g — Settings' seven subpages (design §8.6, `DESIGN.md` §9.6): General, Shortcuts, Appearance,
/// Models, Providers, Sync, Updates, with the V4 rows the owner added (preview dwell, spacing,
/// unknown-caret style, latch pause, the fn system-action prompt, draw-without-key, the
/// speaker-embedding model). No SwiftUI `body` can be driven on this toolchain, so every page's
/// behaviour is asserted through its model and the pure rules the page renders, its copy is held to
/// the verified prototype (`design/design_v1.html`) and `design_copy.json`, and each page gets an
/// `ImageRenderer` smoke render.
@Suite("S7g · Settings subpages")
@MainActor
struct SettingsSubpagesS7gTests {

    // MARK: - Helpers

    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func prototype() throws -> String {
        try String(contentsOf: root.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
    }

    /// The prototype's `case'<screen>':out=…;break;` source for one screen.
    static func prototypeScreen(_ key: String) throws -> String {
        let html = try prototype()
        let start = try #require(html.range(of: "case'\(key)':out="))
        let end = try #require(html.range(of: "break;", range: start.upperBound..<html.endIndex))
        return String(html[start.upperBound..<end.lowerBound])
    }

    static func general(_ store: InMemorySettingsStore = InMemorySettingsStore(),
                        fn: FnKeyConflict? = nil,
                        opened: (() -> Void)? = nil,
                        themes: ((WindowTheme) -> Void)? = nil) -> GeneralSettingsViewModel {
        GeneralSettingsViewModel(store: store,
                                 fnConflict: { $0 == .fn ? fn : nil },
                                 openKeyboardSettings: { opened?() },
                                 applyTheme: { themes?($0) })
    }

    static func eventually(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: - Hand-off: the key every hint names (wave 1 I1)

    @Test("Settings' default dictation key is fn / 🌐, the key the service listens on")
    func defaultKeyIsFn() {
        #expect(HotkeyChoice.default == .fn)
        #expect(HotkeyChoice.default.binding == HotkeyService.defaultBinding.kind)
        #expect(HotkeyChoice.default.label == "fn / 🌐")
        let general = Self.general()
        #expect(general.hotkey == .fn)
        #expect(general.hotkeyLabel == "fn / 🌐")
        // A stored choice still wins.
        let store = InMemorySettingsStore()
        store.set(HotkeyChoice.rightOption.rawValue, for: HotkeyService.bindingDefaultsKey)
        #expect(Self.general(store).hotkey == .rightOption)
    }

    // MARK: - General

    @Test("General reads every row's default from the setting its consumer reads")
    func generalDefaults() {
        let general = Self.general()
        #expect(general.previewDwell == .standard)
        #expect(general.soundCues == false, "sound cues are off by default (design §8.6)")
        #expect(general.spacing == .automatic)
        #expect(general.unknownCaretStyle == .sentence)
        #expect(general.latchDoubleTap)
        #expect(general.latchPauseSeconds == LatchSettings.defaultPauseSeconds)
        #expect(general.drawWithoutKey == false)
        #expect(general.theme == .system)
        #expect(general.reduceMotion == false)
        #expect(general.textSize == .standard)
    }

    @Test("each General / Shortcuts / Appearance row writes the key its consumer reads")
    func rowsWriteTheirConsumersKeys() {
        let store = InMemorySettingsStore()
        let general = Self.general(store)
        general.previewDwell = .manual
        general.soundCues = true
        general.spacing = .never
        general.unknownCaretStyle = .asSpoken
        general.latchDoubleTap = false
        general.drawWithoutKey = true
        general.theme = .light
        general.reduceMotion = true
        general.textSize = .larger

        #expect(TurnSettings.previewDwell(store) == .manual)
        #expect(SoundCueSettings.isEnabled(store))
        #expect(FormattingSettings.preferences(store) == FormattingPreferences(spacing: .never, unknownCaretStyle: .asSpoken))
        #expect(LatchGestureSettings.isEnabled(store) == false)
        #expect(DeixisSettings.drawsWithoutKey(store))
        #expect(AppearanceSettings.theme(store) == .light)
        #expect(AppearanceSettings.reducesMotion(store))
        #expect(AppearanceSettings.textSize(store) == .larger)

        // Read back by a fresh model (the window rebuilt): the choices survive.
        let reopened = Self.general(store)
        #expect(reopened.previewDwell == .manual && reopened.spacing == .never && reopened.unknownCaretStyle == .asSpoken)
        #expect(reopened.latchDoubleTap == false && reopened.drawWithoutKey && reopened.textSize == .larger)
    }

    @Test("the V3 final-preview select is 600 ms, 1200 ms, Manual review")
    func previewSelectMatchesPrototype() throws {
        let expected = SettingsCopy.dwellOrder.map(SettingsCopy.dwellTitle)
        #expect(expected == ["600 ms · default", "1200 ms", "Manual review"])
        #expect(SettingsCopy.dwellOrder.map(\.seconds) == [0.6, 1.2, nil])
        // Low confidence extends a timed dwell to 1800 ms and leaves manual review manual.
        #expect(PreviewDwell.standard.seconds(lowConfidence: true) == 0.6)
        #expect(PreviewDwell.manual.seconds(lowConfidence: true) == nil)
    }

    @Test("General rows use the prototype's words")
    func generalCopyIsThePrototypes() throws {
        let settings = try Self.prototypeScreen("settings")
        for text in [SettingsCopy.shortcutTitle, SettingsCopy.shortcutDetail, SettingsCopy.previewTitle,
                     SettingsCopy.previewDetail, SettingsCopy.lowConfidenceTitle, SettingsCopy.lowConfidenceDetail,
                     SettingsCopy.reviewable, SettingsCopy.soundCuesTitle, SettingsCopy.launchTitle,
                     SettingsCopy.launchDetail, SettingsCopy.moreSettings] {
            #expect(settings.contains(text), "“\(text)” is not in the prototype's Settings screen")
        }
        #expect(SettingsCopy.soundCuesDetail.hasPrefix("Subtle start and stop feedback."))
        #expect(settings.contains("Subtle start and stop feedback."))
    }

    // MARK: - Sound cues

    @Test("sound cues: off by default, and never a success sound before a verified insertion")
    func soundCuePolicy() {
        for event: SoundCueEvent in [.captureOpened, .captureClosed, .delivered(verified: true)] {
            #expect(SoundCuePolicy.cue(for: event, enabled: false) == nil)
        }
        #expect(SoundCuePolicy.cue(for: .captureOpened, enabled: true) == .start)
        #expect(SoundCuePolicy.cue(for: .captureClosed, enabled: true) == .stop)
        #expect(SoundCuePolicy.cue(for: .delivered(verified: true), enabled: true) == .success)
        #expect(SoundCuePolicy.cue(for: .delivered(verified: false), enabled: true) == nil,
                "“Inserted · not confirmed” never sounds like success")
        #expect(SoundCuePolicy.cue(for: .notDelivered, enabled: true) == nil)

        let store = InMemorySettingsStore()
        var played: [SoundCue] = []
        #expect(SoundCuePlayer.play(.captureOpened, store: store, sink: { played.append($0) }) == nil)
        SoundCueSettings.setEnabled(true, store: store)
        SoundCuePlayer.play(.captureOpened, store: store, sink: { played.append($0) })
        SoundCuePlayer.play(.delivered(verified: false), store: store, sink: { played.append($0) })
        SoundCuePlayer.play(.delivered(verified: true), store: store, sink: { played.append($0) })
        #expect(played == [.start, .success])
        for cue in SoundCue.allCases { #expect(NSSound(named: NSSound.Name(cue.systemSoundName)) != nil) }
    }

    // MARK: - Shortcuts · latch rows (B2, G1)

    @Test("latch pause: 1–5 s, clamped, written through LatchSettings with its change notification")
    func latchPause() async {
        let store = InMemorySettingsStore()
        let general = Self.general(store)
        let center = NotificationCenter.default
        var notified = 0
        let token = center.addObserver(forName: LatchSettings.didChangeNotification, object: nil, queue: nil) { _ in notified += 1 }
        defer { center.removeObserver(token) }
        general.latchPauseSeconds = 3.5
        #expect(LatchSettings.pauseSeconds(store) == 3.5)
        #expect(notified >= 1, "a latched session re-times without a restart")
        general.latchPauseSeconds = 9
        #expect(general.latchPauseSeconds == LatchSettings.pauseRange.upperBound)
        #expect(LatchSettings.pauseSeconds(store) == 5)
        general.latchPauseSeconds = 0.2
        #expect(general.latchPauseSeconds == 1)
        #expect(LatchSettings.pauseSeconds(store) == 1)
    }

    @Test("Double-tap to latch off: a double tap is two taps, nothing latches")
    func latchGestureFilter() {
        #expect(LatchGestureSettings.filter([.enterLatch], enabled: true) == [.enterLatch])
        #expect(LatchGestureSettings.filter([.enterLatch], enabled: false) == [.cancelCapture])
        #expect(LatchGestureSettings.filter([.startCapture, .finalize], enabled: false) == [.startCapture, .finalize])
        #expect(LatchGestureSettings.isEnabled(InMemorySettingsStore()), "on by default (prototype toggle('Latch',true))")
    }

    @Test("Shortcuts rows use the prototype's words")
    func shortcutsCopyIsThePrototypes() throws {
        let screen = try Self.prototypeScreen("shortcuts")
        for text in [ShortcutCopy.holdToTalk, ShortcutCopy.holdExplanation, ShortcutCopy.escapeCancels,
                     ShortcutCopy.changeShortcut, ShortcutCopy.latchTitle, ShortcutCopy.latchDetail,
                     ShortcutCopy.testTitle, ShortcutCopy.testDetail, ShortcutCopy.footnote] {
            #expect(screen.contains(text), "“\(text)” is not in the prototype's Shortcuts screen")
        }
    }

    // MARK: - Shortcuts · recorder and conflict result

    @Test("recorder: bindable modifiers by their own key code, only on press; left and right are distinct")
    func recorderCapturesModifiers() {
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 61, flags: 0x0008_0000) == .key(.rightOption))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 61, flags: 0) == nil, "the release is not a choice")
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 63, flags: 0x0080_0000) == .key(.fn))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 62, flags: 0x0004_0000) == .key(.rightControl))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 58, flags: 0x0008_0000) == .key(.leftOption))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 55, flags: 0x0010_0000) == .unsupported("Left Command"))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 56, flags: 0x0002_0000) == .unsupported("Left Shift"))
        #expect(ShortcutRecorder.capture(flagsChangedKeyCode: 55, flags: 0) == nil)
    }

    @Test("recorder: Escape cancels, ⌃⌥D and ⌃⌥A are chords, a typing key is refused")
    func recorderCapturesKeys() {
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 53, flags: 0) == .cancelled)
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 2, flags: 0x0004_0000 | 0x0008_0000) == .key(.controlOptionD))
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 0, flags: 0x0004_0000 | 0x0008_0000) == .key(.controlOptionA))
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 2, flags: 0x0004_0000) == .unsupported("⌃"))
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 0, flags: 0, characters: "a") == .unsupported("A"))
        #expect(ShortcutRecorder.capture(keyDownKeyCode: 2, flags: 0x0010_0000, characters: "d") == .unsupported("⌘D"))
    }

    @Test("recording: a modifier counts on release, so ⌃ ⌥ D records the chord, not ⌃")
    func recordingWaitsForRelease() {
        var recording = ShortcutRecording()
        #expect(recording.flagsChanged(keyCode: 59, flags: 0x0004_0000) == nil, "Left Control pressed: waiting")
        #expect(recording.flagsChanged(keyCode: 58, flags: 0x0004_0000 | 0x0008_0000) == nil)
        #expect(recording.keyDown(keyCode: 2, flags: 0x0004_0000 | 0x0008_0000) == .key(.controlOptionD))
        #expect(recording.pending == nil)

        var alone = ShortcutRecording()
        #expect(alone.flagsChanged(keyCode: 61, flags: 0x0008_0000) == nil)
        #expect(alone.flagsChanged(keyCode: 61, flags: 0) == .key(.rightOption), "released with nothing typed")
        var left = ShortcutRecording()
        _ = left.flagsChanged(keyCode: 55, flags: 0x0010_0000)
        #expect(left.flagsChanged(keyCode: 55, flags: 0) == .unsupported("Left Command"))
        #expect(ShortcutRecorder.isRelease(flagsChangedKeyCode: 63, flags: 0))
        #expect(!ShortcutRecorder.isRelease(flagsChangedKeyCode: 63, flags: 0x0080_0000))
    }

    @Test("a conflict keeps your previous shortcut active (K01), and says why")
    func conflictKeepsThePreviousShortcut() {
        let store = InMemorySettingsStore()
        let general = Self.general(store)
        general.actKey = .key(.rightCommand)
        let change = general.apply(.key(.rightCommand))
        #expect(change == .conflict(attempted: .rightCommand, kept: .fn, reason: "Right Command is your Actions key."))
        #expect(general.hotkey == .fn, "the previous shortcut stays active")
        #expect(store.string(HotkeyService.bindingDefaultsKey) == nil, "nothing was written")
        let banner = try? #require(change?.banner)
        #expect(banner?.headline == "This shortcut is already in use")
        #expect(banner?.body?.hasSuffix("Your previous shortcut stays active.") == true)
        #expect(banner?.recoveryID == .K01)

        let refused = general.apply(.unsupported("Left Command"))
        #expect(refused == .unsupported(name: "Left Command", kept: .fn))
        #expect(refused?.banner?.headline == "Left Command can’t be held for dictation")
        #expect(refused?.banner?.body?.contains("Left and right modifiers are distinct.") == true)
        #expect(general.apply(.cancelled) == nil)
        #expect(general.apply(.key(.fn)) == .unchanged(.fn))
    }

    @Test("a recorded key becomes the binding HotkeyService reads, live")
    func recordedKeyIsBound() {
        let store = InMemorySettingsStore()
        let general = Self.general(store)
        let change = general.apply(.key(.rightOption))
        #expect(change == .changed(from: .fn, to: .rightOption))
        #expect(change?.confirmation == "Right Option is now your dictation key.")
        #expect(store.string(HotkeyService.bindingDefaultsKey) == "rightOption")
        #expect(store.string(SettingsKeys.hotkey) == "rightOption")
        #expect(general.hotkeyLabel == "Right Option")
    }

    @Test("the recorder's local monitor exists only while recording or testing")
    func recorderMonitorLifecycle() {
        let general = Self.general()
        var installed = 0
        var removed = 0
        let shortcuts = ShortcutsPageModel(general: general, clock: { 0 },
                                           installMonitor: { _ in installed += 1; return NSObject() },
                                           removeMonitor: { _ in removed += 1 })
        shortcuts.startRecording()
        #expect(shortcuts.isRecording && installed == 1)
        shortcuts.record(.key(.rightControl))
        #expect(!shortcuts.isRecording && removed == 1)
        #expect(shortcuts.lastChange == .changed(from: .fn, to: .rightControl))
        #expect(general.hotkey == .rightControl)
        shortcuts.record(.key(.fn))
        #expect(general.hotkey == .rightControl, "a capture outside recording changes nothing")

        shortcuts.startTesting()
        #expect(shortcuts.isTesting && installed == 2)
        shortcuts.startRecording()
        #expect(!shortcuts.isTesting && shortcuts.isRecording && installed == 2, "one monitor, handed over")
        shortcuts.stopAll()
        #expect(removed == 2)
    }

    @Test("the key picker beside the recorder obeys the same conflict rule")
    func pickerObeysTheConflictRule() {
        let general = Self.general()
        general.actKey = .key(.controlOptionA)
        let shortcuts = ShortcutsPageModel(general: general, clock: { 0 },
                                           installMonitor: { _ in NSObject() }, removeMonitor: { _ in })
        shortcuts.choose(.controlOptionA)
        #expect(general.hotkey == .fn)
        #expect(shortcuts.lastChange?.banner?.recoveryID == .K01)
        shortcuts.choose(.controlOptionD)
        #expect(general.hotkey == .controlOptionD)
        #expect(shortcuts.lastChange == .changed(from: .fn, to: .controlOptionD))
    }

    // MARK: - Shortcuts · test area

    @Test("shortcut test: hold, too short, double tap into Latch, tap out — the real timings")
    func shortcutTestProbe() {
        var probe = ShortcutTestProbe()
        #expect(probe.message(key: "fn / 🌐") ==
                "Hold fn / 🌐 here, then let go. While this test runs, the key doesn’t start a dictation in this window.")
        #expect(probe.message(key: "fn / 🌐", mode: .sharedWithEventTap).contains("a dictation starts as well"),
                "the legacy event tap reads keys before the page can keep them")
        probe.edge(.down, at: 0, latchEnabled: true)
        #expect(probe.result == .pressed)
        probe.edge(.up, at: 0.8, latchEnabled: true)
        #expect(probe.result == .hold(seconds: 0.8))
        #expect(probe.message(key: "fn / 🌐").contains("a hold"))

        probe.edge(.down, at: 2.0, latchEnabled: true)
        probe.edge(.up, at: 2.1, latchEnabled: true)
        #expect(probe.result == .tooShort)
        #expect(probe.message(key: "fn / 🌐") == "Hold fn / 🌐 a little longer", "K03, with the configured key")
        probe.edge(.down, at: 2.2, latchEnabled: true)
        probe.edge(.up, at: 2.3, latchEnabled: true)
        #expect(probe.result == .latched)
        probe.edge(.down, at: 4.0, latchEnabled: true)
        #expect(probe.result == .latchFinished)
        probe.edge(.up, at: 4.1, latchEnabled: true)

        var off = ShortcutTestProbe()
        off.edge(.down, at: 0, latchEnabled: false)
        off.edge(.up, at: 0.1, latchEnabled: false)
        off.edge(.down, at: 0.2, latchEnabled: false)
        off.edge(.up, at: 0.3, latchEnabled: false)
        #expect(off.result == .tooShort, "with Double-tap to latch off, a double tap never latches")
        off.edge(.down, at: 1.0, latchEnabled: false)
        #expect(off.result == .pressed, "and the next press starts fresh")
    }

    @Test("test mode: bare modifiers are read in the page; a chord cannot be; the event tap also dictates")
    func shortcutTestMode() {
        #expect(ShortcutTestMode.resolve(.fn, forceEventTap: false) == .isolated)
        #expect(ShortcutTestMode.resolve(.rightOption, forceEventTap: true) == .sharedWithEventTap)
        #expect(ShortcutTestMode.resolve(.controlOptionD, forceEventTap: false) == .chord)
        #expect(!ShortcutTestMode.chord.canProbe && ShortcutTestMode.isolated.canProbe)

        let general = Self.general()
        general.hotkey = .controlOptionD
        let shortcuts = ShortcutsPageModel(general: general, clock: { 0 },
                                           installMonitor: { _ in NSObject() }, removeMonitor: { _ in })
        shortcuts.startTesting()
        #expect(!shortcuts.isTesting, "a chord is never offered a test it cannot run")
        #expect(shortcuts.testLine == ShortcutCopy.chordTestNote("Control + Option + D"))
        #expect(shortcuts.testLine.contains("watch the pill"))
        general.hotkey = .fn
        #expect(shortcuts.testLine == ShortcutCopy.testDetail)
        shortcuts.startTesting()
        #expect(shortcuts.testLine.hasPrefix("Hold fn / 🌐 here, then let go."))
        shortcuts.choose(.controlOptionD)
        #expect(!shortcuts.isTesting, "picking a key ends the test")
    }

    @Test("key isolation: a release is kept only when its press was")
    func keyIsolation() {
        var isolation = KeyIsolation()
        #expect(isolation.swallow(.up) == false, "a press the dictation key saw must reach it released")
        #expect(isolation.swallow(.down) && isolation.holdsPress)
        #expect(isolation.swallow(.up) && !isolation.holdsPress)
        #expect(isolation.swallow(.up) == false)
    }

    /// A `flagsChanged` event for `keyCode` with `flags` set (a press) or clear (a release).
    static func flagsEvent(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test("testing on the default listener: the page reads the bound key and keeps it from the dictation key")
    func testAreaKeepsTheKeyToItself() throws {
        let general = Self.general()
        var now: TimeInterval = 10
        let shortcuts = ShortcutsPageModel(general: general, clock: { now },
                                           installMonitor: { _ in NSObject() }, removeMonitor: { _ in })
        let fnDown = try Self.flagsEvent(63, .function)
        let fnUp = try Self.flagsEvent(63, [])
        let optionDown = try Self.flagsEvent(61, .option)
        shortcuts.startTesting()
        #expect(shortcuts.handle(fnDown) == false, "swallowed: the service's older local monitor never sees it")
        #expect(shortcuts.probe.result == .pressed)
        now = 10.5
        #expect(shortcuts.handle(fnUp) == false)
        #expect(shortcuts.probe.result == .hold(seconds: 0.5))
        #expect(shortcuts.handle(optionDown), "any other key passes through untouched")

        // A release whose press arrived before the test began reaches the dictation key.
        shortcuts.stopTesting()
        shortcuts.startTesting()
        #expect(shortcuts.handle(fnUp), "never strand a press the service already saw")

        // With the legacy event tap the service reads keys first, so the page only watches.
        general.forceEventTap = true
        #expect(shortcuts.handle(fnDown) && shortcuts.probe.result == .pressed)
        #expect(shortcuts.handle(fnUp))
    }

    @Test("recording: pressing the current key again neither dictates nor strands it")
    func recordingKeepsTheCurrentKey() throws {
        let general = Self.general()
        let shortcuts = ShortcutsPageModel(general: general, clock: { 0 },
                                           installMonitor: { _ in NSObject() }, removeMonitor: { _ in })
        shortcuts.startRecording()
        #expect(shortcuts.handle(try Self.flagsEvent(63, .function)) == false)
        #expect(shortcuts.handle(try Self.flagsEvent(63, [])) == false)
        #expect(shortcuts.lastChange == .unchanged(.fn) && !shortcuts.isRecording)
        shortcuts.startRecording()
        #expect(shortcuts.handle(try Self.flagsEvent(61, .option)), "another modifier is not the dictation key's")
        #expect(shortcuts.handle(try Self.flagsEvent(61, [])))
        #expect(shortcuts.lastChange == .changed(from: .fn, to: .rightOption))
        #expect(general.hotkey == .rightOption)
    }

    @Test("the test area feeds the page model's probe while testing, with the latch setting in force")
    func shortcutTestThroughTheModel() {
        let general = Self.general()
        general.latchDoubleTap = false
        let shortcuts = ShortcutsPageModel(general: general, clock: { 0 },
                                           installMonitor: { _ in NSObject() }, removeMonitor: { _ in })
        shortcuts.testEdge(.down, at: 0)
        #expect(shortcuts.probe.result == .waiting, "not testing: nothing is read")
        shortcuts.startTesting()
        for (edge, t) in [(HotkeyBinding.Edge.down, 0.0), (.up, 0.1), (.down, 0.2), (.up, 0.3)] {
            shortcuts.testEdge(edge, at: t)
        }
        #expect(shortcuts.probe.result == .tooShort)
    }

    // MARK: - Shortcuts · fn / 🌐 system action (I1)

    @Test("fn with a macOS 🌐 action shows the prompt with Open Keyboard settings; other keys never do")
    func fnConflictPrompt() throws {
        let conflict = try #require(FnKeyConflict(.showEmojiAndSymbols))
        var opened = 0
        let general = Self.general(fn: conflict, opened: { opened += 1 })
        #expect(general.fnConflict == conflict)
        #expect(general.fnConflict?.headline == "The 🌐 key also shows Emoji & Symbols")
        #expect(FnKeyConflict.actionTitle == "Open Keyboard settings")
        general.openKeyboardSettings()
        #expect(opened == 1)
        general.hotkey = .rightOption
        #expect(general.fnConflict == nil)
        general.hotkey = .fn
        #expect(general.fnConflict == conflict, "re-read on every key change")
        #expect(FnKeyConflict(.doNothing) == nil)
    }

    // MARK: - Appearance

    @Test("appearance: windows only, the theme is applied at open and on change; text size and motion")
    func appearance() {
        let store = InMemorySettingsStore()
        AppearanceSettings.setTheme(.dark, store: store)
        var applied: [WindowTheme] = []
        let general = Self.general(store, themes: { applied.append($0) })
        #expect(applied == [.dark], "a remembered theme reaches the window when it opens")
        general.theme = .system
        #expect(applied == [.dark, .system])
        #expect(WindowTheme.system.appearanceName == nil)
        #expect(WindowTheme.light.appearanceName == .aqua)
        #expect(WindowTheme.dark.appearanceName == .darkAqua)
        #expect(WindowTheme.allCases.map(\.title) == ["Follow system", "Light", "Dark"])
        #expect(WindowTextSize.allCases.map(\.scale) == [1, 1.15, 1.3])
        // Never less motion reduction than macOS asks for.
        #expect(AppearanceSettings.effectiveReduceMotion(store, system: true))
        #expect(!AppearanceSettings.effectiveReduceMotion(store, system: false))
        AppearanceSettings.setReducesMotion(true, store: store)
        #expect(AppearanceSettings.effectiveReduceMotion(store, system: false))
        // The pill's colours are fixed dark; nothing here can reach them.
        #expect(Tokens.Role.pill.usage == .fixedDark)
    }

    // MARK: - Models

    /// A model manager whose download the test drives step by step.
    final class ScriptedModels: ModelManaging, @unchecked Sendable {
        var installed: Set<ModelID>
        var failWith: Error?
        var progressSteps: [Double] = [0.25, 1.0]
        var gate: (@Sendable () async -> Void)?
        init(installed: Set<ModelID> = []) { self.installed = installed }
        var isStackInstalled: Bool { ModelStack.models.allSatisfy(installed.contains) }
        var remainingStackBytes: Int64 {
            ModelStack.models.filter { !installed.contains($0) }.reduce(0) { $0 + ModelCatalog.descriptor($1).approxBytes }
        }
        func downloadStack(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
            let total = max(remainingStackBytes, 1)
            for fraction in progressSteps {
                try Task.checkCancellation()
                progress(ModelDownloadProgress(fraction: fraction, bytesReceived: Int64(Double(total) * fraction),
                                               bytesExpected: total, modelName: "Parakeet TDT v3"))
                if let gate { await gate() }
            }
            if let failWith { throw failWith }
            installed.formUnion(ModelStack.models)
        }
        var stackReadiness: RecognizerReadiness {
            isStackInstalled ? .ready(name: "Parakeet TDT v3") : .fallback(name: "Apple Speech (on-device)", awaiting: nil)
        }
    }

    struct ScriptedInventory: ModelInventoryReading {
        let models: ScriptedModels
        func read() async -> [ModelID: ModelInventoryEntry] {
            Dictionary(uniqueKeysWithValues: ModelStack.models.map {
                ($0, ModelInventoryEntry(installed: models.installed.contains($0), bytesOnDisk: 1_000_000))
            })
        }
    }

    /// A loader the test resolves by hand, so "Loading" can be observed before "Ready".
    final class ScriptedLoader: @unchecked Sendable {
        var calls = 0
        var outcomes: [OnboardingStateMachine.ModelLoadOutcome] = []
        var release: CheckedContinuation<Void, Never>?
        var holds = false
        @MainActor func load() async -> OnboardingStateMachine.ModelLoadOutcome {
            calls += 1
            if holds { await withCheckedContinuation { release = $0 } }
            return outcomes.isEmpty ? .loaded(name: "Parakeet TDT v3") : outcomes.removeFirst()
        }
    }

    @Test("Models: the first read is loading (never empty), nothing installed is the design's empty state")
    func modelsEmptyAndLoading() async {
        let models = ScriptedModels()
        let loader = ScriptedLoader()
        let store = InMemorySettingsStore()
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models), store: store,
                                   load: { await loader.load() })
        let loading = page.state(hotkey: "fn / 🌐")
        #expect(loading.rendering == .loading)
        #expect(loading.headline == "Verifying the speech model…")
        #expect(loading.isWellFormed)
        await page.refresh()
        #expect(page.phase == .notInstalled)
        let empty = page.state(hotkey: "fn / 🌐")
        #expect(empty.rendering == .empty && empty.isWellFormed)
        #expect(empty.headline == "Install a speech model")
        #expect(empty.actionTitle == "Choose a model")
        #expect(loader.calls == 0, "nothing to load")
        #expect(page.rows.map(\.id) == ModelStack.models)
        #expect(page.rows.allSatisfy { !$0.installed })
    }

    @Test("Models: real byte progress → Verifying → Loading → Ready, and Ready only after the load")
    func modelsInstallSequence() async throws {
        let models = ScriptedModels()
        let loader = ScriptedLoader()
        loader.holds = true
        let store = InMemorySettingsStore()
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models), store: store,
                                   load: { await loader.load() })
        await page.refresh()
        let step = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        models.gate = {
            step.continuation.yield()
            for await _ in proceed.stream { break }
        }
        page.install()
        #expect(page.phase == .starting)
        var steps = step.stream.makeAsyncIterator()
        _ = await steps.next()
        #expect(await Self.eventually { if case .downloading = page.phase { return true }; return false })
        if case .downloading(let p) = page.phase {
            #expect(page.phase.statusLine.contains("\(p.percent)%"))
            #expect(page.phase.statusLine.contains(ByteText.short(p.bytesExpected)), "real bytes, with a true denominator")
        }
        #expect(page.state(hotkey: "fn") == .content, "a download in progress is content, not empty")
        proceed.continuation.yield()
        _ = await steps.next()
        #expect(await Self.eventually { page.phase == .verifying }, "every byte in: verifying, not ready")
        proceed.continuation.yield()
        #expect(await Self.eventually { page.phase == .loading })
        #expect(!page.phase.isReady, "download completion is never Ready before loading")
        #expect(await Self.eventually { loader.release != nil })
        #expect(page.phase == .loading, "still loading while the load runs")
        loader.release?.resume()
        #expect(await Self.eventually { page.phase == .ready(name: "Parakeet TDT v3") })
        #expect(page.phase.tag.text == "Ready" && page.phase.tag.kind == .good)
        #expect(page.lastWorking == "Parakeet TDT v3")
        #expect(store.string(SettingsKeys.lastWorkingModel) == "Parakeet TDT v3")
        #expect(page.rows.allSatisfy { $0.installed })
        #expect(page.missing.isEmpty)
    }

    @Test("Models: a failed download is a scoped banner over readable rows; the last working model stays")
    func modelsDownloadFailure() async {
        let models = ScriptedModels()
        models.failWith = URLError(.notConnectedToInternet)
        let store = InMemorySettingsStore()
        store.set("Parakeet TDT v3", for: SettingsKeys.lastWorkingModel)
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models), store: store,
                                   load: { .loaded(name: "Parakeet TDT v3") })
        await page.refresh()
        page.install()
        #expect(await Self.eventually { if case .downloadFailed = page.phase { return true }; return false })
        guard case .downloadFailed(let id) = page.phase else { return }
        #expect([RecoveryID.M02, .M03, .M04, .M05, .M06].contains(id))
        #expect(page.state(hotkey: "fn") == .content)
        let banner = page.banner
        #expect(banner?.headline == RecoveryCatalog.entry(id).headline)
        #expect(banner?.body?.hasSuffix("Available content stays readable.") == true)
        #expect(page.lastWorking == "Parakeet TDT v3")
        // Retry is the banner's one action: it starts the download again.
        models.failWith = nil
        page.retry()
        #expect(await Self.eventually { page.phase == .ready(name: "Parakeet TDT v3") })
    }

    @Test("Models: a load failure is M07 with Retry loading; retry loads again")
    func modelsLoadFailure() async {
        let models = ScriptedModels(installed: Set(ModelStack.models))
        let loader = ScriptedLoader()
        loader.outcomes = [.failed("x"), .loaded(name: "Parakeet TDT v3")]
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models),
                                   store: InMemorySettingsStore(), load: { await loader.load() })
        await page.refresh()
        #expect(page.phase == .loadFailed(.M07))
        #expect(page.banner?.headline == "The speech model isn’t ready")
        #expect(page.banner?.actionTitle == "Retry loading")
        page.retry()
        #expect(await Self.eventually { page.phase == .ready(name: "Parakeet TDT v3") })
        #expect(loader.calls == 2)
    }

    @Test("Models: cancel returns to not installed")
    func modelsCancel() async {
        let models = ScriptedModels()
        let hold = AsyncStream<Void>.makeStream()
        models.gate = { for await _ in hold.stream { break } }
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models),
                                   store: InMemorySettingsStore(), load: { .loaded(name: "x") })
        await page.refresh()
        page.install()
        #expect(await Self.eventually { if case .downloading = page.phase { return true }; return false })
        page.cancel()
        hold.continuation.finish()
        #expect(page.phase == .notInstalled)
        #expect(await Self.eventually { page.phase == .notInstalled })
    }

    @Test("Models: the H3 speaker-embedding row says what is missing; the speech model alone is not empty")
    func speakerEmbeddingRow() async {
        let models = ScriptedModels(installed: [.parakeetTDTv3, .parakeetEOU160])
        let page = ModelsPageModel(models: models, inventory: ScriptedInventory(models: models),
                                   store: InMemorySettingsStore(), load: { .loaded(name: "Parakeet TDT v3") })
        await page.refresh()
        #expect(page.phase == .ready(name: "Parakeet TDT v3"), "dictation works without the speaker model")
        let speaker = try? #require(page.speakerRow)
        #expect(speaker?.installed == false)
        #expect(speaker?.name == ModelCatalog.descriptor(.speakerEmbedding).displayName)
        #expect(ModelsPage.speakerNote(installed: false)?.hasPrefix("Voice filtering unavailable") == true)
        #expect(ModelsPage.speakerNote(installed: true) == nil)
        #expect(page.missing == [.speakerEmbedding])
        #expect(speaker?.detail.contains("to download") == true)
    }

    // MARK: - Providers

    struct KeychainRefused: Error {}

    final class FailingSecrets: SecretStore, @unchecked Sendable {
        func get(_ key: String) throws -> String? { nil }
        func set(_ value: String, for key: String) throws { throw KeychainRefused() }
        func delete(_ key: String) throws {}
    }

    struct FixedProbe: ProviderConnectivityProbing {
        let answer: ProviderServiceStatus
        func test(_ endpoint: APIEndpoint, key: String) async -> ProviderServiceStatus { answer }
    }

    @Test("Providers: a key is saved to the Keychain slot the provider table reads, and never shown again")
    func providerKeySaved() async throws {
        let secrets = InMemorySecretStore()
        let credentials = ProviderCredentialsModel(secrets: secrets, probe: FixedProbe(answer: .reachable))
        let openRouter = try #require(credentials.services.first { $0.endpoint == .openRouter })
        #expect(credentials.status(openRouter) == .noKey && !credentials.hasAnyKey)
        credentials.entered[openRouter.id] = "  sk-or-secret-123  "
        credentials.save(openRouter)
        #expect(try secrets.get(SecretKey.apiKey(APIEndpoint.openRouter.providerID)) == "sk-or-secret-123")
        #expect(credentials.entered[openRouter.id] == "", "the field is cleared once the Keychain has it")
        #expect(credentials.status(openRouter) == .saved && credentials.hasAnyKey)
        await credentials.test(openRouter)
        #expect(credentials.status(openRouter) == .reachable)
        credentials.remove(openRouter)
        #expect(credentials.status(openRouter) == .noKey)
        #expect(try secrets.get(openRouter.secretKey) == nil)
    }

    @Test("Providers: a failed save keeps the typed key in the field, and no error names it")
    func providerSaveFailureKeepsTheEntry() throws {
        let credentials = ProviderCredentialsModel(secrets: FailingSecrets(), probe: FixedProbe(answer: .reachable))
        let service = try #require(credentials.services.first)
        credentials.entered[service.id] = "sk-live-do-not-show"
        credentials.save(service)
        #expect(credentials.entered[service.id] == "sk-live-do-not-show")
        let banner = try #require(credentials.saveFailures[service.id])
        #expect(banner.recoveryID == .S02)
        #expect(banner.headline == "Changes weren’t saved")
        let said = [banner.headline, banner.body ?? "", banner.actionTitle ?? "", banner.diagnostics ?? ""].joined()
        #expect(!said.contains("sk-live-do-not-show"))
        #expect(credentials.status(service) == .noKey)
    }

    @Test("Providers: connectivity answers are the catalogue's N01–N04, never the response")
    func providerConnectivity() async throws {
        #expect(LiveProviderConnectivityProbe.status(forHTTP: 200) == .reachable)
        #expect(LiveProviderConnectivityProbe.status(forHTTP: 401) == .failed(.N02))
        #expect(LiveProviderConnectivityProbe.status(forHTTP: 429) == .failed(.N03))
        #expect(LiveProviderConnectivityProbe.status(forHTTP: 503) == .failed(.N01))
        #expect(LiveProviderConnectivityProbe.status(forHTTP: 404) == .failed(.N04))
        #expect(ProviderServiceStatus.failed(.N02).line == "Reconnect this service")
        #expect(ProviderServiceStatus.testing.line == "Testing connection…", "design §9 Providers loading")

        // The kill switch refuses the test before anything leaves this Mac.
        let defaults = try #require(UserDefaults(suiteName: "vp.s7g.gate.\(UUID().uuidString)"))
        defaults.set(true, forKey: EgressGate.killSwitchKey)
        let probe = LiveProviderConnectivityProbe(gate: EgressGate(defaults: defaults))
        #expect(await probe.test(.openAI, key: "sk-test") == .failed(.N04))

        let secrets = InMemorySecretStore([SecretKey.apiKey(APIEndpoint.groq.providerID): "gsk-secret"])
        let credentials = ProviderCredentialsModel(secrets: secrets, probe: FixedProbe(answer: .failed(.N02)))
        let groq = try #require(credentials.services.first { $0.endpoint == .groq })
        #expect(credentials.status(groq) == .saved)
        await credentials.test(groq)
        #expect(credentials.status(groq).line == "Reconnect this service")
        #expect(!credentials.status(groq).line.contains("gsk-secret"))
    }

    @Test("Providers: the selected route per stage; transcription is always local")
    func providerRoute() {
        let local = ProviderRoute.rows(routing: [:])
        #expect(local.first?.title == "Speech recognition" && local.first?.isLocal == true)
        #expect(local.first?.detail == "Current route is on device.")
        let meetings = local.first { $0.id == "meetings" }
        #expect(meetings?.title == "Meeting notes / Ask" && meetings?.isLocal == true,
                "the prototype's row: notes are extractive and local; Ask needs a service")
        #expect(ExtractiveNotesProvider().name == "extractive-local")
        let email = StageID.formatterEmail
        let pinned = ProviderRoute.rows(routing: [email: .provider("openrouter")])
        let row = pinned.first { $0.id == email.rawValue }
        #expect(row?.isLocal == false && row?.detail == "Sent to openrouter when used.")
        let planner = pinned.first { $0.id == ProviderPlanner.stage.rawValue }
        #expect(planner?.isLocal == false && planner?.detail == "No provider pinned, so this stays off.")
        #expect(!pinned.contains { $0.id == StageID.asr.rawValue }, "transcription cannot be routed")
    }

    @Test("Providers: “Nothing connected” only when nothing is, and Explore options shows the page")
    func providersEmptyState() {
        let empty = ProvidersPage.state(hasKey: false, discovered: [], connectorsSignedIn: false, exploring: false, hotkey: "fn")
        #expect(empty.rendering == .empty && empty.isWellFormed)
        #expect(empty.headline == "Nothing connected")
        #expect(empty.actionTitle == "Explore options")
        #expect(ProvidersPage.state(hasKey: false, discovered: [], connectorsSignedIn: false, exploring: true, hotkey: "fn") == .content)
        #expect(ProvidersPage.state(hasKey: true, discovered: [], connectorsSignedIn: false, exploring: false, hotkey: "fn") == .content)
        #expect(ProvidersPage.state(hasKey: false, discovered: ["claude-cli"], connectorsSignedIn: false, exploring: false, hotkey: "fn") == .content)
    }

    @Test("connectors: a failure is its catalogue entry, never the error's text")
    func connectorFailureHidesTheError() {
        let connectors = ConnectorsSettingsViewModel(hub: nil)
        connectors.note(ConnectorError.http(500, "token=ghp_supersecret"))
        #expect(connectors.failure?.headline == "The service isn’t responding")
        let said = [connectors.failure?.headline, connectors.failure?.body, connectors.failure?.actionTitle]
            .compactMap { $0 }.joined()
        #expect(!said.contains("ghp_supersecret"))
        connectors.note(ConnectorError.unauthorized)
        #expect(connectors.failure?.headline == "Reconnect this service")
    }

    // MARK: - Sync

    static func syncService(settings: InMemorySettingsStore = InMemorySettingsStore(),
                            database: AppDatabase? = nil, keys: InMemorySyncKeyStore = InMemorySyncKeyStore()) -> SyncService {
        SyncService(database: database, snippets: InMemorySnippetStore(), settings: settings, keyStore: keys)
    }

    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-s7g-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Sync: off until something is paired; pairing compares both codes before connecting")
    func syncPairingComparison() throws {
        let store = InMemorySettingsStore()
        let sync = SyncSettingsViewModel(service: Self.syncService(settings: store), store: store)
        let off = sync.state(showingSetup: false)
        #expect(off.rendering == .empty && off.isWellFormed)
        #expect(off.headline == "Sync is off" && off.actionTitle == "Pair a device")
        #expect(sync.syncStatus == .off)

        sync.startPairing()
        let comparison = try #require(sync.comparison)
        #expect(comparison.match == .waiting)
        #expect(sync.state(showingSetup: false) == .content)

        let other = PairingSession(deviceID: "peer-ipad", deviceName: "Aditya’s iPad")
        sync.scannedPeer = other.payload.qrString
        #expect(sync.comparison?.peerName == "Aditya’s iPad")
        #expect(sync.comparison?.peerCode == other.shortCode)
        sync.peerCode = other.shortCode == "000000" ? "111111" : "000000"
        #expect(sync.comparison?.match == .differs)
        sync.peerCode = PairingComparison.grouped(other.shortCode)
        #expect(sync.comparison?.match == .matches, "grouped digits compare the same")

        sync.completePairing()
        #expect(sync.failure == nil)
        #expect(sync.devices.map(\.name) == ["Aditya’s iPad"])
        #expect(SyncSettings.devices(store).map(\.id) == ["peer-ipad"], "remembered")
        #expect(sync.status?.hasPrefix("Paired with Aditya’s iPad.") == true)
        #expect(sync.syncStatus == .idle(lastRound: nil))
        #expect(sync.comparison == nil)
    }

    @Test("Sync: a pairing mismatch is X05 — nothing applied, pair again")
    func syncPairingMismatch() {
        let sync = SyncSettingsViewModel(service: Self.syncService(), store: InMemorySettingsStore())
        sync.startPairing()
        let other = PairingSession(deviceID: "peer", deviceName: "Peer")
        sync.scannedPeer = other.payload.qrString
        sync.peerCode = other.shortCode == "123456" ? "654321" : "123456"
        sync.completePairing()
        #expect(sync.failure?.recoveryID == .X05)
        #expect(sync.failure?.headline == "Devices couldn’t be paired safely")
        #expect(sync.failure?.body == "Nothing from this transfer was applied.")
        #expect(sync.devices.isEmpty)
        sync.bannerAction()
        #expect(sync.comparison != nil, "Pair again restarts pairing")
    }

    @Test("Sync: paused stops Sync now; an unreachable folder is offline (X06) and never blocks dictation")
    func syncPausedAndOffline() throws {
        let store = InMemorySettingsStore()
        let service = Self.syncService(settings: store)
        let folder = try Self.tempFolder()
        service.folderURL = folder
        var reachable = true
        let sync = SyncSettingsViewModel(service: service, store: store, folderReachable: { _ in reachable })
        #expect(sync.syncStatus == .idle(lastRound: nil) && sync.canSyncNow)
        sync.setPaused(true)
        #expect(sync.syncStatus == .paused && !sync.canSyncNow)
        #expect(SyncSettings.isPaused(store))
        sync.setPaused(false)
        reachable = false
        #expect(sync.syncStatus == .offline && !sync.canSyncNow)
        #expect(sync.banner?.recoveryID == .X06)
        #expect(sync.banner?.body?.hasPrefix("Local dictation continues.") == true)
        #expect(SyncStatus.offline.line.contains("local dictation continues"))
    }

    @Test("Sync: a round lists what another device replaced, and Keep this Mac’s puts it back")
    func syncConflictReview() throws {
        let folder = try Self.tempFolder()
        let keysA = InMemorySyncKeyStore(), keysB = InMemorySyncKeyStore()
        let dbA = try AppDatabase.inMemory(), dbB = try AppDatabase.inMemory()
        let storeA = InMemorySettingsStore()
        let a = Self.syncService(settings: storeA, database: dbA, keys: keysA)
        let b = Self.syncService(database: dbB, keys: keysB)
        try a.key().save(to: keysB)
        a.folderURL = folder
        b.folderURL = folder
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try dbA.save(DictionaryRecord(id: "w1", term: "Mira", spokenForms: "mee rah", createdAt: t0))
        try dbB.save(DictionaryRecord(id: "w1", term: "Meera", createdAt: t0.addingTimeInterval(60)))
        try b.syncNow()

        let now = Date(timeIntervalSince1970: 2_000_000)
        let sync = SyncSettingsViewModel(service: a, store: storeA, now: { now })
        sync.syncNow()
        #expect(sync.failure == nil)
        #expect(sync.lastRound == now && SyncSettings.lastRound(storeA) == now)
        #expect(sync.conflicts == [SyncConflict(id: "w1", kind: "Dictionary word", mine: "Mira (“mee rah”)", theirs: "Meera")])
        #expect(sync.banner?.recoveryID == .X06, "edits to review")
        #expect(sync.devices.count == 1, "the device that shares the key is listed")
        #expect(try dbA.dictionaryTerms().first?.term == "Meera")

        sync.keepMine(try #require(sync.conflicts.first), database: dbA)
        let restored = try #require(try dbA.dictionaryTerms().first)
        #expect(restored.term == "Mira" && restored.spokenForms == "mee rah" && restored.createdAt == now)
        #expect(sync.conflicts.isEmpty && sync.banner == nil)
    }

    @Test("Sync: a payload that fails verification is rejected and named (X05)")
    func syncRejectsInvalidPayloads() throws {
        let folder = try Self.tempFolder()
        let service = Self.syncService()
        service.folderURL = folder
        try Data("not a sealed payload".utf8).write(to: folder.appendingPathComponent("intruder").appendingPathExtension("vpsync"))
        let sync = SyncSettingsViewModel(service: service, store: InMemorySettingsStore())
        sync.syncNow()
        #expect(sync.rejectedPeers == ["intruder"])
        #expect(sync.failure?.recoveryID == .X05)
        #expect(sync.devices.isEmpty, "a rejected peer is not a connected device")
    }

    @Test("Sync: with no service the page says so, and still offers nothing that cannot work")
    func syncUnavailable() {
        let sync = SyncSettingsViewModel(service: nil)
        let state = sync.state(showingSetup: false)
        #expect(state.rendering == .empty && state.isWellFormed && state.actionTitle == nil)
        #expect(state.detail?.contains("Local dictation is unaffected.") == true)
    }

    // MARK: - Updates

    final class ScriptedUpdater: UpdaterProtocol, UpdateStatusReporting {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = false
        var feedURL: URL? = nil
        var checks = 0, downloads = 0, installs = 0
        var updatePhase: UpdatePhase = .idle(lastChecked: nil) { didSet { onUpdatePhaseChange?(updatePhase) } }
        var onUpdatePhaseChange: ((UpdatePhase) -> Void)?
        func checkForUpdates() { checks += 1; updatePhase = .checking }
        func downloadUpdate() { downloads += 1 }
        func installAndRelaunch() { installs += 1 }
    }

    @Test("Updates: this build's no-op updater is named as such, with the installed version")
    func updatesWithoutAnUpdater() {
        let updates = UpdatesPageModel(updater: NoopUpdater(), version: "1.11.0",
                                       captureActive: { false }, heldDrafts: { 0 }, draftsPersisted: { true })
        #expect(!updates.canUpdate)
        #expect(updates.statusLine == "This build has no updater wired, so it will never update itself.")
        #expect(UpdatesCopy.installed(updates.version) == "VoicePlus 1.11.0")
        updates.check()
        #expect(updates.phase == .idle(lastChecked: nil), "no check that would do nothing")
    }

    @Test("Updates: checking, available, downloading, install-ready and failure (X07)")
    func updatesPhases() {
        let updater = ScriptedUpdater()
        let updates = UpdatesPageModel(updater: updater, version: "1.11.0",
                                       captureActive: { false }, heldDrafts: { 0 }, draftsPersisted: { true })
        updates.check()
        #expect(updater.checks == 1 && updates.phase == .checking)
        #expect(updates.statusLine == "Checking for updates…")
        updater.updatePhase = .available(version: "1.12.0")
        #expect(updates.statusLine == "VoicePlus 1.12.0 is available.")
        updates.download()
        #expect(updater.downloads == 1)
        updater.updatePhase = .downloading(version: "1.12.0", fraction: 0.4)
        #expect(updates.statusLine == "Downloading VoicePlus 1.12.0…")
        updater.updatePhase = .readyToInstall(version: "1.12.0")
        #expect(updates.statusLine == "VoicePlus 1.12.0 is ready to install.")
        updater.updatePhase = .failed
        #expect(updates.banner?.headline == "The update didn’t finish")
        #expect(updates.banner?.body == "Keep using the installed version.")
        updates.retry()
        #expect(updater.checks == 2)
        updates.automaticChecks = true
        #expect(updater.automaticallyChecksForUpdates)
    }

    @Test("Updates: installing never cuts off a capture, and held drafts are confirmed first")
    func updatesProtectCaptureAndDrafts() {
        let updater = ScriptedUpdater()
        updater.updatePhase = .readyToInstall(version: "1.12.0")
        var capturing = true
        var held = 2
        var persisted = false
        let updates = UpdatesPageModel(updater: updater, version: "1.11.0", captureActive: { capturing },
                                       heldDrafts: { held }, draftsPersisted: { persisted })
        updates.install()
        #expect(updates.pendingRestart == .waitForCapture && updater.installs == 0)
        #expect(UpdateRestartGuard.message(.waitForCapture) == "Finish your dictation or meeting first — installing restarts VoicePlus.")
        updates.confirmRestart()
        #expect(updater.installs == 0, "confirm never overrides a running capture")

        capturing = false
        updates.install()
        #expect(updates.pendingRestart == .confirmDrafts(count: 2, kept: false))
        #expect(UpdateRestartGuard.message(.confirmDrafts(count: 2, kept: false)) ==
                "2 held dictations are kept for this session only. Copy them before restarting.")
        persisted = true
        #expect(UpdateRestartGuard.message(.confirmDrafts(count: 1, kept: true)) == "1 held dictation will still be here after the restart.")
        updates.confirmRestart()
        #expect(updater.installs == 1 && updates.pendingRestart == nil)

        held = 0
        updates.install()
        #expect(updater.installs == 2, "nothing to protect: install goes straight through")
        #expect(UpdateRestartGuard.decide(captureActive: false, heldDrafts: 0, draftsPersisted: false) == .proceed)
    }

    // MARK: - Every page renders

    @Test("every subpage renders in the window (smoke), and Settings has exactly the seven")
    func everySubpageRenders() throws {
        #expect(SettingsSubpage.allCases.count == 7)
        let store = InMemorySettingsStore()
        let window = MainWindowShellS7aTests.window(store: store, section: .settings)
        for subpage in SettingsSubpage.allCases {
            window.settingsSubpage = subpage
            let credentials = ProviderCredentialsModel(secrets: InMemorySecretStore(), probe: FixedProbe(answer: .reachable))
            let view = SettingsScreen(context: SectionContext(window: window, section: .settings),
                                      credentials: credentials, inventory: StaticModelInventory([:]))
                .frame(width: 760, height: 900)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            #expect(renderer.cgImage != nil, "\(subpage.title) did not render")
        }
    }
}
