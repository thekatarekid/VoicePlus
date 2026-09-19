import AppKit
import SwiftUI

// S5 — the marks as the pill draws them: dotted underlines under a line of the text lane, and the
// click / VoiceOver targets that open the correction popover on a word.

/// The 2 px dotted underlines of one drawn line. Its top edge is placed 3 px below the line's
/// baseline by the caller (`alignmentGuide(.firstTextBaseline)`).
struct PillMarkUnderlines: View {
    let fragments: [MarkFragment]

    var body: some View {
        let width = fragments.map { $0.x + $0.width }.max() ?? 0
        Canvas { context, _ in
            for fragment in fragments where fragment.width > 0 {
                var path = Path()
                path.move(to: CGPoint(x: fragment.x, y: MarkStyle.thickness / 2))
                path.addLine(to: CGPoint(x: fragment.x + fragment.width, y: MarkStyle.thickness / 2))
                context.stroke(path, with: .color(Tokens.Pill.Token.uncertainty.color),
                               style: StrokeStyle(lineWidth: MarkStyle.thickness, lineCap: .butt, dash: MarkStyle.dash))
            }
        }
        .frame(width: width, height: MarkStyle.thickness)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A click target over one fragment of a mark. Knows its own screen rect, so the popover anchors to
/// the word even when it is opened from the keyboard or VoiceOver.
struct PillMarkTarget: View {
    let mark: UncertainMark
    let width: CGFloat
    let height: CGFloat
    let open: (CGRect?) -> Void
    @State private var probe = ScreenRectProbe.Box()

    var body: some View {
        Color.clear
            .frame(width: max(width, 8), height: height)
            .contentShape(Rectangle())
            .background(ScreenRectProbe(box: probe))
            .onTapGesture { open(probe.screenRect) }
            .accessibilityElement()
            .accessibilityLabel(mark.accessibilityLabel)
            .accessibilityHint("Opens word review")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(probe.screenRect) }
            .accessibilityIdentifier("pill.mark.\(mark.id)")
    }
}

/// Reads the screen rect of the view it sits behind.
struct ScreenRectProbe: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
        var screenRect: CGRect? {
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}
