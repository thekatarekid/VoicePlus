import AppKit
import Engine
import SwiftUI

/// P5.5 — notch prompt: "Meeting? Join & Record / Record / Ignore". Borderless panel under the
/// notch of the active screen; one button per `MeetingPrompt.choices`.
@MainActor
public final class MeetingPromptPanel {
    private var panel: NSPanel?
    public var onChoice: ((MeetingPrompt.Choice) -> Void)?

    public init() {}

    public func show(_ prompt: MeetingPrompt) {
        dismiss()
        let view = MeetingPromptView(prompt: prompt) { [weak self] choice in
            self?.onChoice?(choice)
            self?.dismiss()
        }
        let size = NSSize(width: 380, height: 66)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct MeetingPromptView: View {
    let prompt: MeetingPrompt
    let choose: (MeetingPrompt.Choice) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.fill").foregroundStyle(.teal)
            Text(prompt.title).font(.callout).lineLimit(1)
            Spacer(minLength: 6)
            ForEach(prompt.choices, id: \.rawValue) { choice in
                Button(label(for: choice)) { choose(choice) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(choice == .ignore ? nil : .teal)
                    .accessibilityIdentifier("meeting.choice.\(choice.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("meeting.prompt")
    }

    private func label(for choice: MeetingPrompt.Choice) -> String {
        switch choice {
        case .joinAndRecord: return "Join & Record"
        case .record: return "Record"
        case .ignore: return "Ignore"
        }
    }
}
