import AppKit
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 L1 — three ambient settings replacing the R8.1 on/off switch.
@Suite("V5 L1 AmbientMode")
struct AmbientModeTests {
    @Test("default Off; R8.1 'on' migrates to Listen & note (never act); writes mirror the legacy key")
    func migration() {
        let s = InMemorySettingsStore()
        #expect(AmbientModeSettings.mode(s) == .off)
        #expect(AmbientModeSettings.mode(nil) == .off)
        s.set(true, for: AmbientModeSettings.legacyEnabledKey)
        #expect(AmbientModeSettings.mode(s) == .listenAndNote)
        AmbientModeSettings.set(.listenAndAct, store: s)
        #expect(AmbientModeSettings.mode(s) == .listenAndAct)
        #expect(s.bool(AmbientModeSettings.legacyEnabledKey) == true)
        #expect(AmbientCaptureSettings.isEnabled(s))
        AmbientModeSettings.set(.off, store: s)
        #expect(s.bool(AmbientModeSettings.legacyEnabledKey) == false)
        #expect(!AmbientCaptureSettings.isEnabled(s))
    }

    @Test("the old on/off API never escalates to act and Off really is off")
    func legacyAPI() {
        let s = InMemorySettingsStore()
        AmbientCaptureSettings.setEnabled(true, store: s)
        #expect(AmbientModeSettings.mode(s) == .listenAndNote)
        AmbientModeSettings.set(.listenAndAct, store: s)
        AmbientCaptureSettings.setEnabled(true, store: s)
        #expect(AmbientModeSettings.mode(s) == .listenAndAct)
        AmbientCaptureSettings.setEnabled(false, store: s)
        #expect(AmbientModeSettings.mode(s) == .off)
    }

    @Test("voice: stop listening / just take notes / you can act again — whole phrases only")
    func voice() {
        #expect(AmbientModeVoiceCommand.parse("Stop listening.") == .off)
        #expect(AmbientModeVoiceCommand.parse("okay, just take notes") == .listenAndNote)
        #expect(AmbientModeVoiceCommand.parse("You can act again!") == .listenAndAct)
        #expect(AmbientModeVoiceCommand.parse("stop listening please") == .off)
        #expect(AmbientModeVoiceCommand.parse("he told me to stop listening to podcasts") == nil)
        #expect(AmbientModeVoiceCommand.parse("") == nil)
    }

    @Test("controller: observers, voice apply, explainer exactly once on first enable")
    func controller() {
        let s = InMemorySettingsStore()
        let c = AmbientModeController(settings: s)
        var seen: [AmbientMode] = []
        var explained: [AmbientMode] = []
        c.observe { seen.append($0) }
        c.presentExplainer = { explained.append($0) }
        c.set(.listenAndNote)
        c.set(.listenAndNote)          // no-op
        #expect(c.applyVoice("you can act again") == .listenAndAct)
        #expect(c.applyVoice("stop listening") == .off)
        c.set(.listenAndAct)
        #expect(c.applyVoice("what's the weather") == nil)
        #expect(seen == [.listenAndNote, .listenAndAct, .off, .listenAndAct])
        #expect(explained == [.listenAndNote])
    }

    @Test("Settings › Privacy: the segmented mode writes ambient.mode, never directedSpeech")
    @MainActor func privacy() {
        let s = InMemorySettingsStore()
        let flags = FeatureFlagService.inMemory()
        let model = PrivacySectionViewModel(settings: s, flags: flags)
        var explained = 0
        AmbientModeController.presentFirstEnable = { _ in explained += 1 }
        defer { AmbientModeController.presentFirstEnable = nil }
        #expect(model.ambientMode == .off)
        model.ambientMode = .listenAndAct
        #expect(s.string(AmbientModeSettings.key) == "listenAndAct")
        #expect(model.ambientCapture)
        #expect(flags.isEnabled(.directedSpeech) == false)
        model.ambientMode = .off
        model.ambientMode = .listenAndNote
        #expect(explained == 1)
    }

    @Test("menu: the one menu (menu bar + notch) carries the mode row; the segmented control switches it")
    @MainActor func menu() throws {
        let s = InMemorySettingsStore()
        let c = AmbientModeController(settings: s)
        let item = AmbientModeMenu.item(controller: c)
        #expect(item.title == "Ambient · Off")
        let view = try #require(item.view as? AmbientModeMenuView)
        #expect(view.segmented.segmentCount == 3)
        view.segmented.selectedSegment = 1
        view.changed(view.segmented)
        #expect(c.mode == .listenAndNote)
        #expect(view.label.stringValue == "Ambient · Listen & note")
        #expect(AmbientMode.listenAndAct.symbol != nil && AmbientMode.off.symbol == nil)
    }
}
