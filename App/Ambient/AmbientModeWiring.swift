import AppKit
import Foundation

// V5 L1 · composition of the ambient mode: one controller, the menu row (menu bar + notch share one
// menu), the Settings › Privacy explainer hook, and the one-time explainer sheet.

@MainActor
public enum AmbientModeWiring {
    /// The app's controller once `install` ran (the ambient decision pipeline reads it).
    public private(set) static var controller: AmbientModeController?

    /// Builds the controller, hangs it on the status menu and installs the first-enable explainer.
    @discardableResult
    public static func install(settings: (any SettingsStore)?, status: StatusItemController) -> AmbientModeController {
        let controller = AmbientModeController(settings: settings)
        controller.presentExplainer = { mode in Task { @MainActor in showExplainer(mode) } }
        AmbientModeController.presentFirstEnable = controller.presentExplainer
        status.ambientModeController = controller
        self.controller = controller
        controller.observe { [weak status] _ in Task { @MainActor in status?.refreshIcon() } }
        return controller
    }

    /// The one-time explainer sheet (an app-modal alert: there may be no window to attach a sheet to
    /// when the mode is switched from the menu bar).
    public static func showExplainer(_ mode: AmbientMode) {
        let alert = NSAlert()
        alert.messageText = AmbientModeController.explainerTitle
        alert.informativeText = "\(mode.title): \(mode.detail)\n\n\(AmbientModeController.explainerBody)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
