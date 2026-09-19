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

/// The prompt in the pill's own always-dark inks (`Tokens.Pill`): a notch surface, so it looks like
/// the pill it hangs beside. Record choices use the pill's primary fill; Ignore its quiet control.
struct MeetingPromptView: View {
    let prompt: MeetingPrompt
    let choose: (MeetingPrompt.Choice) -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "video.fill")
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                .accessibilityHidden(true)
            Text(prompt.title)
                .windowFont(Tokens.Typography.pillStatus)
                .fontWeight(.semibold)
                .foregroundStyle(Tokens.Pill.Token.ink.color)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.s)
            ForEach(prompt.choices, id: \.rawValue) { choice in
                Button(Self.label(for: choice)) { choose(choice) }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.isPrimary(choice) ? Tokens.Pill.Token.primary.color : Tokens.Pill.Token.control.color)
                    .foregroundStyle(Self.isPrimary(choice) ? Tokens.Pill.Token.onPrimary.color : Tokens.Pill.Token.ink.color)
                    .controlSize(.small)
                    .accessibilityIdentifier("meeting.choice.\(choice.rawValue)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.pill, style: .continuous)
            .fill(Tokens.Pill.Token.background.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.prompt")
    }

    static func label(for choice: MeetingPrompt.Choice) -> String {
        switch choice {
        case .joinAndRecord: return "Join & Record"
        case .record: return "Record"
        case .ignore: return "Ignore"
        }
    }

    /// Recording is the prompt's purpose; Ignore stays quiet.
    static func isPrimary(_ choice: MeetingPrompt.Choice) -> Bool { choice != .ignore }
}
