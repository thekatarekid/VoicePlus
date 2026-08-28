import AppKit
import Engine
import Shared
import SwiftUI

/// P5.5 — notch prompt: "Meeting? Join & Record / Record / Ignore". Borderless panel under the
/// notch of the active screen; one button per `MeetingPrompt.choices`.
@MainActor
public final class MeetingPromptPanel {
    private var panel: NSPanel?
    public var onChoice: ((MeetingPrompt.Choice) -> Void)?

    /// Requested size; the notch rule may clamp it on a narrow display.
    nonisolated public static let panelSize = CGSize(width: 380, height: 66)

    /// Where the prompt goes on a given display. Same rule as the pill (`NotchGeometry.topBand`):
    /// the top edge sits at the bottom of the forbidden band, so on a notched MacBook the panel is
    /// never drawn behind the camera housing. The old code used `screen.frame.maxY - height - 8`,
    /// which put its top ~30 pt behind the housing.
    nonisolated public static func frame(on metrics: ScreenMetrics) -> CGRect {
        NotchGeometry.layout(for: metrics, size: panelSize).shown
    }

    public init() {}

    public func show(_ prompt: MeetingPrompt) {
        dismiss()
        let view = MeetingPromptView(prompt: prompt) { [weak self] choice in
            self?.onChoice?(choice)
            self?.dismiss()
        }
        // Host screen rule, like the pill: the display under the mouse, falling back to main.
        let rect = PillPanelController.currentMetrics().map(Self.frame(on:))
            ?? CGRect(origin: .zero, size: Self.panelSize)
        let size = rect.size
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
        panel.setFrame(rect, display: true)
        Log.app.info("meeting prompt placement: frame=\(NSStringFromRect(rect))")
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
