import Foundation
import SwiftUI

/// V5 W1 settings rows (Lane 1b): the two insertion switches, stored in `UserDefaults` under the
/// keys their readers use.
///
/// - Q2 "Expose text in Chromium browsers" — `Injection` reads `injection.exposeChromiumText`
///   (`InjectionSettingsKeys.exposeChromiumText`, default **on**). Electron apps are always exposed.
/// - Q14 "Confirm in apps that hide their text (uses Screen Recording)" — the opt-in OCR caret band
///   reads `injection.confirmHiddenTextWithScreenRecording` (default **off**). Q14 (W4) is the reader;
///   until it lands the switch is stored and shown but changes nothing.
public enum InsertionSettings {
    public static let exposeChromiumTextKey = "injection.exposeChromiumText"
    public static let confirmHiddenTextKey = "injection.confirmHiddenTextWithScreenRecording"

    public static let exposeChromiumTextDefault = true
    public static let confirmHiddenTextDefault = false

    public static func exposeChromiumText(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: exposeChromiumTextKey) == nil ? exposeChromiumTextDefault : defaults.bool(forKey: exposeChromiumTextKey)
    }

    public static func confirmHiddenText(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: confirmHiddenTextKey) == nil ? confirmHiddenTextDefault : defaults.bool(forKey: confirmHiddenTextKey)
    }

    // MARK: Copy
    public static let groupTitle = "Insertion"
    public static let exposeChromiumTitle = "Expose text in Chromium browsers"
    public static let exposeChromiumDetail = "Asks Chrome, Brave, Edge and Arc to publish their text fields so VoicePlus can confirm what it typed. Apps built on Electron are always asked."
    public static let confirmHiddenTitle = "Confirm in apps that hide their text (uses Screen Recording)"
    public static let confirmHiddenDetail = "When a field exposes nothing to read back, VoicePlus reads a thin band around the caret on screen, on this Mac only, to confirm the text landed. Off by default."
}

/// The two rows, bound to `UserDefaults` (the readers are in other modules).
struct InsertionSettingsRows: View {
    @AppStorage(InsertionSettings.exposeChromiumTextKey) private var exposeChromium = InsertionSettings.exposeChromiumTextDefault
    @AppStorage(InsertionSettings.confirmHiddenTextKey) private var confirmHidden = InsertionSettings.confirmHiddenTextDefault
    let chromiumIdentifier: String
    let confirmIdentifier: String

    var body: some View {
        GroupBox(InsertionSettings.groupTitle, layout: .rows) {
            SettingsToggleRow(title: InsertionSettings.exposeChromiumTitle, detail: InsertionSettings.exposeChromiumDetail,
                              isOn: $exposeChromium, identifier: chromiumIdentifier)
            SettingsToggleRow(title: InsertionSettings.confirmHiddenTitle, detail: InsertionSettings.confirmHiddenDetail,
                              isOn: $confirmHidden, identifier: confirmIdentifier)
        }
    }
}
