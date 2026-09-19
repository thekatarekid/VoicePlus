import SwiftUI

/// S7a — the still Spool cameo for window surfaces, wrapping S1's port of the prototype's `cameo()`
/// (`SpoolScene.cameo`: the character alone at t = 1.4, reels parked, in the −76 −72 152 132 viewBox).
///
/// It draws one frame with a `Canvas` and no timeline, so it cannot move: empty and loading screens
/// never spin (design §8.9). A surface that should move with real capture (Voice test, meeting
/// capture) uses `SpoolView` itself; which surface may do what is S12's `SpoolSurfacePolicy`.
/// The art is decoration and hidden from accessibility — the text beside it carries the meaning.
struct SpoolCameo: View {
    /// The prototype's three cameo sizes.
    enum Size: Equatable, Sendable {
        /// `.spool-surface-note .spool-cameo` — 53 pt, beside a one-line status.
        case note
        /// `.spool-cameo` — 76 pt.
        case standard
        /// `.empty-icon svg` — 88 pt, above an empty or loading headline.
        case emptyState

        var width: CGFloat {
            switch self {
            case .note: return 53
            case .standard: return 76
            case .emptyState: return 88
            }
        }

        /// Keeps the cameo viewBox's 152 : 132 aspect.
        var height: CGFloat {
            (width * CGFloat(SpoolScene.cameoViewBox[3] / SpoolScene.cameoViewBox[2])).rounded()
        }
    }

    var pose: SpoolStateKey
    var size: Size

    init(_ pose: SpoolStateKey = .ready, size: Size = .standard) {
        self.pose = pose
        self.size = size
    }

    var body: some View {
        let drawing = SpoolScene.cameo(pose).drawing
        Canvas { context, canvasSize in
            SpoolCanvas.draw(drawing, in: &context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// The prototype's Spool surface note (`.spool-surface-note`): the 53 pt still cameo beside one line —
/// "Spool · Ready when you are. Microphone closed." on Today and Privacy, "Your text stays held until
/// you resolve it." on Turn detail and Recovery — over a hairline. The section decides whether the
/// line is true right now (S12 policy); the note never animates.
struct SpoolNote: View {
    var pose: SpoolStateKey
    var text: String

    init(_ pose: SpoolStateKey, _ text: String) {
        self.pose = pose
        self.text = text
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.l) {
            SpoolCameo(pose, size: .note)
            Text(text)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, Tokens.Spacing.l)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WindowColor.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
