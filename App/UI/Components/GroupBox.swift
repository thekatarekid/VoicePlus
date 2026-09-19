import SwiftUI

/// S7a — the design's group (prototype `h3` + `.group`): an optional heading in the `section` role,
/// then a box with a 1 pt hairline (`separator`, which Increase Contrast raises to `controlBorder`)
/// and 10 pt corners. One hairline per boundary: rows draw the lines between themselves
/// (`RowView`), the box draws the outline.
///
/// Named like SwiftUI's `GroupBox` on purpose: inside the app module this one shadows it, so every
/// window section — including the R7 panes S7b–S7g are about to replace — draws the design's group,
/// not the system's. The two `init`s cover every form the app used with the system type.
struct GroupBox<Content: View>: View {
    enum Layout: Equatable {
        /// Free content, inset by 16 pt (a form, a paragraph, a legacy pane).
        case padded
        /// `RowView`s edge to edge; each row carries its own insets and separator.
        case rows
    }

    var title: String?
    var layout: Layout
    private var label: AnyView?
    private let content: Content

    init(_ title: String? = nil, layout: Layout = .padded, @ViewBuilder content: () -> Content) {
        self.title = title
        self.layout = layout
        self.label = nil
        self.content = content()
    }

    /// SwiftUI's `GroupBox { … } label: { … }` form.
    init<Label: View>(layout: Layout = .padded, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.title = nil
        self.layout = layout
        self.label = AnyView(label())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if let title, !title.isEmpty {
                Text(title)
                    .windowFont(Tokens.Typography.section)
                    .foregroundStyle(WindowColor.ink)
                    .accessibilityAddTraits(.isHeader)
            } else if let label {
                label
                    .windowFont(Tokens.Typography.section)
                    .foregroundStyle(WindowColor.ink)
            }
            box
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) { content }
            .padding(layout == .padded ? Tokens.Spacing.l : 0)
            // The first row's top hairline sits on the outline; pull it under the clip.
            .padding(.top, layout == .rows ? -1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .overlay(shape.strokeBorder(WindowColor.separator, lineWidth: 1))
            .accessibilityElement(children: .contain)
    }
}

/// S7a — one row of a group (prototype `.row`): title in `body` medium, optional detail in `meta`
/// secondary ink, trailing control. 12 pt × 16 pt insets, a top hairline between rows. The trailing
/// control keeps its own accessibility; the row never merges it into a single element.
struct RowView<Trailing: View>: View {
    var title: String
    var detail: String?
    private let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        // S10 — under Larger Text the trailing control moves under the text when both no longer fit.
        ReflowingRow(spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(title)
                    .windowFont(Tokens.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(WindowColor.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                }
            }
        } trailing: {
            self.trailing
        }
        .padding(.vertical, Tokens.Spacing.m)
        .padding(.horizontal, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(WindowColor.separator).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension RowView where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}
