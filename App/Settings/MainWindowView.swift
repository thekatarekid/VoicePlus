import AppKit
import SwiftUI
import Shared

// R7.1 / S7a — the one window's shell (design §8, `DESIGN.md` §9): a `NavigationSplitView` with the
// design's sidebar (cassette mark, six sections, "Ready · On this Mac" footer), a toolbar that holds
// only the search field of a section that has one, and a detail pane that shows each section's
// `SectionScreen`. The shell owns the frame, sidebar, toolbar, search field and routing; S7b–S7g own
// what each section draws, and never touch this file.
//
// Keyboard (`DESIGN.md` §5.2): ⌘1–⌘6 select the sections, ⌘, opens Settings, ⌘F focuses the section's
// search. Returning to a section finds it as it was left: visited sections stay alive (hidden, inert)
// so their scroll and selection survive, and `SectionNavigation` keeps what they model explicitly.

// MARK: - The contract with S7b–S7g

/// Everything the shell hands a section. A section reads its view models from `window`, its preserved
/// navigation from `navigation`, and routes anywhere through `open`.
@MainActor
struct SectionContext {
    let window: MainWindowViewModel
    let section: MainWindowSection

    /// This section's preserved navigation: search query, selection, scroll anchor, open disclosures.
    var navigation: SectionNavigation { window.navigation(section) }

    /// The configured dictation key's label ("fn / 🌐") for every "Right Control" in design copy.
    var hotkey: String { window.hotkeyLabel }

    /// The page copy the section's current screen uses (Settings: its subpage's).
    var page: PageCopy {
        section == .settings ? .settings(window.settingsSubpage) : .section(section)
    }

    func open(_ route: WindowRoute) { window.open(route) }
    func open(_ section: MainWindowSection) { window.open(section) }
}

/// One section of the window. The shell builds `TodayScreen(context:)`, `MeetingsScreen(context:)`,
/// `DictionaryAppsScreen(context:)`, `VoiceScreen(context:)`, `PrivacyScreen(context:)` and
/// `SettingsScreen(context:)` and nothing else; each lives in its section's own file, so a section task
/// replaces its screen without touching the shell. A screen draws itself in `SectionPage` with the
/// components in `App/UI/Components/`.
@MainActor
protocol SectionScreen: View {
    /// The sidebar section this screen is.
    static var section: MainWindowSection { get }
    init(context: SectionContext)
}

// MARK: - The window

public struct MainWindowView: View {
    @ObservedObject var model: MainWindowViewModel
    @FocusState private var searchFocused: Bool

    public init(model: MainWindowViewModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            WindowSidebar(model: model, today: model.today)
                .navigationSplitViewColumnWidth(min: MainWindowLayout.sidebarWidth.lowerBound,
                                                ideal: MainWindowLayout.sidebarIdealWidth,
                                                max: MainWindowLayout.sidebarWidth.upperBound)
        } detail: {
            detail
                .frame(minWidth: MainWindowLayout.detailMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowColor.canvas)
        }
        .frame(minWidth: MainWindowLayout.minimumSize.width, minHeight: MainWindowLayout.minimumSize.height)
        .navigationTitle(model.title)
        .toolbar {
            if model.selection.hasSearchField {
                ToolbarItem(placement: .primaryAction) {
                    WindowSearchField(navigation: model.navigation(model.selection), focused: $searchFocused)
                }
            }
        }
        .background(windowShortcuts)
        .windowTextScaleRoot(model.general)   // S10: Larger Text reflows the whole window, not only Settings
    }

    /// Each visited section's screen, kept alive and stacked; only the selected one is visible,
    /// hit-testable, focusable and in the accessibility tree.
    private var detail: some View {
        ZStack {
            ForEach(model.visited) { section in
                let selected = section == model.selection
                screen(for: section)
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(selected)
                    .disabled(!selected)
                    .accessibilityHidden(!selected)
                    .zIndex(selected ? 1 : 0)
            }
        }
        .transaction { $0.animation = nil } // design §6.3: detail content replaces with no transition
    }

    @ViewBuilder private func screen(for section: MainWindowSection) -> some View {
        let context = SectionContext(window: model, section: section)
        switch section {
        case .today: TodayScreen(context: context)
        case .meetings: MeetingsScreen(context: context)
        case .dictionary: DictionaryAppsScreen(context: context)
        case .voice: VoiceScreen(context: context)
        case .privacy: PrivacyScreen(context: context)
        case .settings: SettingsShell(model: model, context: context)
        }
    }

    /// ⌘1–⌘6 in the order of design §8, ⌘, for Settings, ⌘F for the section's search. Buttons rather
    /// than commands so the shortcuts work however the window was opened (it is a menu-bar app).
    private var windowShortcuts: some View {
        ZStack {
            ForEach(MainWindowSection.allCases) { section in
                Button("") { model.open(section) }
                    .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
            }
            Button("") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("") { if model.selection.hasSearchField { searchFocused = true } }
                .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

/// The design's sidebar (prototype `.app-nav`): the cassette mark and "VoicePlus", the six sections,
/// and the footer. System list selection; under Increase Contrast the selected row also gets a
/// leading accent bar so selection is not colour alone (`DESIGN.md` §6.3).
struct WindowSidebar: View {
    @ObservedObject var model: MainWindowViewModel
    /// Observed for the footer's readiness word.
    @ObservedObject var today: TodaySectionViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        List(selection: Binding<MainWindowSection?>(
            get: { model.selection },
            set: { if let section = $0 { model.open(section) } }
        )) {
            ForEach(MainWindowSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .windowFont(Tokens.Typography.body)
                    .tag(section)
                    .overlay(alignment: .leading) {
                        if contrast == .increased && section == model.selection {
                            Rectangle().fill(WindowColor.accent).frame(width: 3).offset(x: -Tokens.Spacing.s)
                        }
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityHint("⌘\(section.shortcutIndex)")
                    .accessibilityIdentifier("window.sidebar.\(section.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .tint(WindowColor.accent)
        .scrollContentBackground(.hidden)
        .background(WindowColor.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { logo }
        .safeAreaInset(edge: .bottom, spacing: 0) { WindowFooterView(footer: model.footer) }
        .accessibilityLabel("VoicePlus sections")
    }

    /// The prototype's `.nav-logo`: the menu-bar cassette outline (S6, the one mark) and the name.
    private var logo: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(nsImage: MenuBarGlyph.image(size: NSSize(width: 25, height: 22)))
                .renderingMode(.template)
                .foregroundStyle(WindowColor.ink)
                .accessibilityHidden(true)
            Text("VoicePlus")
                .windowFont(Tokens.Typography.section)
                .foregroundStyle(WindowColor.ink)
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "● Ready · On this Mac" over "Hold fn / 🌐 to speak" (prototype `.app-nav footer`). The dot is the
/// `ready` colour only when the word is Ready; otherwise the attention colour and a glyph.
struct WindowFooterView: View {
    let footer: WindowFooter

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                if footer.status == .ready {
                    Circle().fill(WindowColor.ready).frame(width: 6, height: 6)
                } else {
                    Image(systemName: footer.status.systemImage).foregroundStyle(WindowColor.attention)
                }
                Text(footer.statusLine)
            }
            Text(footer.hintLine)
        }
        .windowFont(Tokens.Typography.meta)
        .foregroundStyle(WindowColor.secondaryInk)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("window.footer")
    }
}

// MARK: - Toolbar search

/// The one search field, in the toolbar, for the selected section only (Today, Meetings, Dictionary &
/// Apps). Its text is the section's `SectionNavigation.searchQuery`, so each section keeps its own
/// query; ⌘F focuses it; Escape clears it (`DESIGN.md` §5.2).
struct WindowSearchField: View {
    @ObservedObject var navigation: SectionNavigation
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(WindowColor.secondaryInk)
            TextField(SectionCopy.searchPrompt, text: $navigation.searchQuery)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { navigation.searchQuery = "" }
                .accessibilityIdentifier("window.search")
            if !navigation.searchQuery.isEmpty {
                Button { navigation.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WindowColor.secondaryInk)
                .accessibilityLabel(SectionCopy.clearSearch)
            }
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(width: 220, height: Tokens.ControlSize.compactMinimumHeight)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(WindowColor.canvas))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).strokeBorder(WindowColor.controlBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search \(navigation.section.title)")
    }
}

// MARK: - Settings subnav

/// Settings' seven subpages (design §8.6) as a segmented subnav over the selected subpage's
/// `SettingsScreen`. The shell owns the routing; S7g owns each subpage's rows.
struct SettingsShell: View {
    @ObservedObject var model: MainWindowViewModel
    let context: SectionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SegmentedControl("Settings pages", selection: $model.settingsSubpage,
                             identifier: "settings.subnav") { $0.title }
                .padding(.horizontal, MainWindowLayout.outerPadding)
                .padding(.top, Tokens.Spacing.l)
            SettingsScreen(context: context)
        }
        .background(WindowColor.canvas)
    }
}

// MARK: - Legacy pane helpers (kept for the R7 panes until S7b–S7g replace them)

/// The inline empty / loading / error rendering used inside a group (a sub-list that is empty while
/// the page has content). One glyph, one word, one sentence, at most one action — never a spinner.
struct SectionStateView: View {
    let state: SectionState
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label(state.headline, systemImage: glyph)
                .windowFont(Tokens.Typography.body)
                .fontWeight(.medium)
                .foregroundStyle(state.rendering == .error ? WindowColor.attention : WindowColor.ink)
                .accessibilityIdentifier("section.state.\(state.rendering.rawValue)")
            if let detail = state.detail {
                Text(detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            if let title = state.actionTitle, let onAction {
                Button(title, action: onAction)
            } else if let title = state.actionTitle {
                Text(title)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
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

/// A failure beside content, as the R7 panes call it: the design's `ScopedBanner`.
struct SectionBannerView: View {
    let banner: SectionBanner
    var onAction: (() -> Void)?

    var body: some View { ScopedBanner(banner, onAction: onAction) }
}

/// One pasteboard write, so no view needs to import AppKit for it.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
