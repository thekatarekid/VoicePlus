import SwiftUI

// S7a — the window's type and colour plumbing for `App/UI/Components/`. Every component reads the G0.3
// tokens (`Tokens.Typography`, `Tokens.Role`, `Tokens.Spacing`, `Tokens.Radius`) through these few
// helpers, so no component writes a size, a colour or a spacing of its own (`DESIGN.md` §1–§3, §12.4).

/// Settings › Appearance › Larger Text (S7g sets it at the window root; S10 audits it). Window text
/// scales by this factor; the pill keeps its sizes (`Tokens.TypeRole.font(scale:)`).
struct WindowTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var windowTextScale: CGFloat {
        get { self[WindowTextScaleKey.self] }
        set { self[WindowTextScaleKey.self] = newValue }
    }
}

/// A type role at the window's current text scale, with the role's line height.
struct WindowFont: ViewModifier {
    let role: Tokens.TypeRole
    @Environment(\.windowTextScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(role.font(scale: scale))
            .lineSpacing(role.lineSpacing(scale: scale))
    }
}

extension View {
    /// `Text("…").windowFont(Tokens.Typography.body)`.
    func windowFont(_ role: Tokens.TypeRole) -> some View { modifier(WindowFont(role: role)) }
}

/// Call-site names for the window's colours as SwiftUI `Color`s (`Tokens.Role`, dynamic per
/// appearance and Increase Contrast).
enum WindowColor {
    static var canvas: Color { Tokens.Role.canvas.color }
    static var sidebar: Color { Tokens.Role.sidebar.color }
    static var surface: Color { Tokens.Role.surface.color }
    static var elevated: Color { Tokens.Role.elevated.color }
    static var ink: Color { Tokens.Role.ink.color }
    static var secondaryInk: Color { Tokens.Role.secondaryInk.color }
    static var separator: Color { Tokens.Role.separator.color }
    static var controlBorder: Color { Tokens.Role.controlBorder.color }
    static var accent: Color { Tokens.Role.accent.color }
    static var onAccent: Color { Tokens.Role.onAccent.color }
    static var ready: Color { Tokens.Role.ready.color }
    static var attention: Color { Tokens.Role.attention.color }
    static var uncertainty: Color { Tokens.Role.uncertainty.color }
}

/// One action on a page: the header's primary action, an empty state's call to action, a banner's
/// recovery. Buttons are system buttons (`DESIGN.md` §12.4: no custom control where one exists).
struct PageAction {
    var title: String
    var isPrimary: Bool = true
    /// False while the scope it belongs to is retrying (design §9) or otherwise unavailable.
    var isEnabled: Bool = true
    var identifier: String?
    var perform: () -> Void

    init(_ title: String, isPrimary: Bool = true, isEnabled: Bool = true, identifier: String? = nil,
         perform: @escaping () -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.isEnabled = isEnabled
        self.identifier = identifier
        self.perform = perform
    }
}

/// A `PageAction` as a system button: primary = bordered prominent in the accent, secondary =
/// bordered. Main-control height (32 pt) via the large control size.
struct PageActionButton: View {
    let action: PageAction

    var body: some View {
        styled
            .controlSize(.large)
            .disabled(!action.isEnabled)
            .accessibilityIdentifier(action.identifier ?? "page.action")
    }

    @ViewBuilder private var styled: some View {
        if action.isPrimary {
            Button(action.title, action: action.perform)
                .buttonStyle(.borderedProminent)
                .tint(WindowColor.accent)
        } else {
            Button(action.title, action: action.perform)
                .buttonStyle(.bordered)
        }
    }
}
