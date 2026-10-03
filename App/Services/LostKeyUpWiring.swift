import Foundation
import Shared

// K02 — lost key-up (design §5 hotkey edge cases, §13 scenario 9; catalogue K02 "Missing key-up, lock,
// sleep or listener interruption").
//
// `HotkeyService` reads the real modifier state every 250 ms while the dictation key is down (and on
// every tap-disabled event). When the key is up but its key-up never arrived, the service ends the
// press itself: a hold past the threshold finalizes through the ordinary `.finalize` action, so the
// words are kept and go through the same final preview, revalidation and single insert as any hold;
// a shorter press cancels. Then `onLostKeyUp` reaches the turn controller here, which says so.

extension TurnController {
    /// The dictation key's release was synthesized from the modifier state (`HotkeyService`): the hold
    /// it closed has already gone to `finishing` through the ordinary key-up path. Posts K02
    /// ("Dictation stopped · Recording is closed. Start again when ready.") so an ending the user did
    /// not make is never silent. Writes nothing and holds nothing back.
    public func lostKeyUp() {
        Log.app.notice("turn: the dictation key's release was lost — capture closed from the modifier state (K02)")
        let entry = RecoveryCatalog.entry(.K02)
        ui { [weak self] in self?.onNotice?(entry) }
    }
}

extension TurnWiring {
    /// Hands `hotkey`'s lost key-ups to the live turn controller (`TurnWiring.current`, read on each
    /// call so a re-attached wiring is the one told). Chains any handler already set.
    @MainActor
    public static func wireLostKeyUp(_ hotkey: HotkeyService, controller: @escaping () -> TurnController? = { TurnWiring.current?.controller }) {
        let previous = hotkey.onLostKeyUp
        hotkey.onLostKeyUp = {
            previous?()
            controller()?.lostKeyUp()
        }
        wireOptionTapFallback(hotkey, controller: controller)
    }

    /// X2 — when the active Option tap cannot be armed, say once (ever) how to stop Claude's own
    /// double-tap-Option shortcut. A failure before this wiring existed is told now.
    @MainActor
    static func wireOptionTapFallback(_ hotkey: HotkeyService, controller: @escaping () -> TurnController?,
                                      defaults: UserDefaults = .standard) {
        let tell = {
            guard OptionTapFallbackNotice.takeOnce(defaults) else { return }
            controller()?.showNote(OptionTapFallbackNotice.text)
        }
        let previous = hotkey.onOptionTapUnavailable
        hotkey.onOptionTapUnavailable = { previous?(); tell() }
        if hotkey.optionTapUnavailable { tell() }
    }
}
