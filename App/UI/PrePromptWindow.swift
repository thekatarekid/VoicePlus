import AppKit
import SwiftUI

/// Plain-language pre-prompt (T5). A small floating window, not a modal; the pill is never used for this.
enum PrePromptWindow {
    private static var windows: [NSWindow] = []

    static func present(_ permission: Permission, choice: @escaping (PermissionOrchestrator.PrePromptChoice) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "VoicePlus needs \(permission.title)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        var finished = false
        let finish: (PermissionOrchestrator.PrePromptChoice) -> Void = { c in
            guard !finished else { return }
            finished = true
            window.close()
            windows.removeAll { $0 === window }
            choice(c)
        }
        window.contentView = NSHostingView(rootView: PrePromptView(permission: permission, choice: finish))
        windows.append(window)
        // Same latent dead end as onboarding: `center()` targets NSScreen.main, which may be a
        // display showing a full-screen Space.
        WindowPlacement.place(window, label: "pre-prompt (\(permission.rawValue))")
    }
}

struct PrePromptView: View {
    let permission: Permission
    let choice: (PermissionOrchestrator.PrePromptChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(permission.title, systemImage: symbol).font(.title2.weight(.semibold))
            Text(permission.rationale).font(.body).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Button("Not now") { choice(.skip) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { choice(.proceed) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420, height: 220)
    }

    private var symbol: String {
        switch permission {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }
}
