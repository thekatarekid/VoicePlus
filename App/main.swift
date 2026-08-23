import AppKit
import Shared

// VoicePlusApp entry point: AppKit menu-bar app (LSUIElement via activation policy; see Resources/Info.plist).
enum VoicePlusAppModule {
    static let name = "VoicePlusApp"
}

Log.app.info("VoicePlus starting (Shared \(SharedModule.version))")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
