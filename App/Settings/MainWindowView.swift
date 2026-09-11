import AppKit
import SwiftUI
import Shared

// R7.1 — one window: sidebar + detail (`DESIGN.md` §5.1, §9). No `TabView` anywhere, no modal, no
// panel. Sidebar 200–260 pt, detail minimum 560 pt, window minimum 820 × 560.
//
// Every section's detail pane is `SectionScaffold`: title, optional subtitle, then exactly one of
// content / empty / loading / error. The scaffold is the only thing that decides which, from the
// section view model's `SectionState`, so no `body` can accidentally show a spinner over content.

public struct MainWindowView: View {
    @ObservedObject var model: MainWindowViewModel

    public init(model: MainWindowViewModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<MainWindowSection?>(
                get: { model.selection },
                set: { model.open($0 ?? model.selection) }
            )) {
                ForEach(MainWindowSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("window.sidebar.\(section.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 480)
        }
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle(model.selection.detailTitle)
        .task(id: model.selection) { await model.load(model.selection) }
        .background(sectionShortcuts)
    }

    /// `⌘1`–`⌘6` in the order of §9. Buttons rather than commands so the shortcuts work whether the
    /// window was opened from the menu bar or from `⌘,`.
    private var sectionShortcuts: some View {
        ForEach(MainWindowSection.allCases) { section in
            Button("") { model.open(section) }
                .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .today: TodaySectionView(model: model.today, open: { model.open($0) })
        case .meetings: MeetingsSectionView(model: model.meetings)
        case .dictionary: DictionaryAppsSectionView(model: model.dictionaryApps, deps: model.deps)
        case .voice: VoiceSectionView(model: model.voice)
        case .privacy: PrivacySectionView(model: model.privacy)
        case .settings: SettingsView(model: model)
        }
    }
}

/// Title, optional subtitle, and exactly one of the four renderings.
struct SectionScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var state: SectionState
    var banner: SectionBanner?
    var onAction: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let banner { SectionBannerView(banner: banner) }
            switch state.rendering {
            case .content: content()
            case .empty, .loading, .error: SectionStateView(state: state, onAction: onAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The empty / loading / error rendering. One glyph, one word, one sentence, at most one action —
/// and never an animated spinner (`DESIGN.md` §6).
struct SectionStateView: View {
    let state: SectionState
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.headline, systemImage: glyph)
                .font(.body.weight(.medium))
                .foregroundStyle(state.rendering == .error ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .accessibilityIdentifier("section.state.\(state.rendering.rawValue)")
            if let detail = state.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if let title = state.actionTitle, let onAction {
                Button(title, action: onAction)
            } else if let title = state.actionTitle {
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: String {
        switch state.rendering {
        case .content: return "checkmark"
        case .empty: return "tray"
        case .loading: return "clock"
        case .error: return "exclamationmark.triangle"
        }
    }
}

/// A failure beside content: one line, one action, raw detail only behind Copy diagnostics.
struct SectionBannerView: View {
    let banner: SectionBanner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(banner.headline, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            if let diagnostics = banner.diagnostics {
                Button(SectionCopy.copyDiagnostics) { Pasteboard.copy(diagnostics) }
                    .accessibilityIdentifier("section.banner.copyDiagnostics")
            }
        }
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .accessibilityIdentifier("section.banner")
    }
}

/// One pasteboard write, so no view needs to import AppKit for it.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

