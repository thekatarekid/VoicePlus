import AppKit
import SwiftUI

/// Public entry point wired by P1.1 / P1.12. One window at a time; re-showing brings it forward.
@MainActor
public enum OnboardingWindowController {
    private static var window: NSWindow?
    private static var viewModel: OnboardingViewModel?

    public static func show(dependencies: OnboardingDependencies, onFinished: ((Bool) -> Void)? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = OnboardingViewModel(dependencies: dependencies)
        model.onFinished = onFinished
        let host = NSHostingController(rootView: OnboardingView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to VoicePlus"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        viewModel = model
    }

    public static func close() {
        window?.close()
        window = nil
        viewModel = nil
    }

    /// True when onboarding has never been completed or skipped on this machine.
    public static func isNeeded(settings: SettingsStore = UserDefaultsSettingsStore()) -> Bool {
        !(settings.bool(SettingsKeys.onboardingCompleted) ?? false)
    }
}
