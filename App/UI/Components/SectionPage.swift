import Engine
import SwiftUI

/// S7a — what one page of the window shows, top to bottom, as data: the testable snapshot of
/// `SectionPage`. The view renders exactly these blocks in this order, so asserting the blocks is
/// asserting the page (this toolchain has no UI testing).
///
/// The rules are the prototype's `renderScreen` (design §9):
/// - **content** — [Spool note] · [partial banner] · page header · the section's content
/// - **empty** — the empty state only: still `ready` cameo, headline, body, one action (no header)
/// - **loading** — header titled with the screen name · still `ready` cameo, "Loading <name>…", the
///   no-empty-claim note (never the empty copy, never an action)
/// - **error** — header titled with the screen name, "Your existing data has not been cleared." ·
///   the catalogue entry as a banner with its one action · "Data kept" + the entry's data policy ·
///   the diagnostics footnote
enum PageBlock: Equatable {
    case spoolNote(SpoolStateKey, String)
    /// The partial rendering's scoped banner, above the header.
    case banner(SectionBanner)
    case header(title: String, subtitle: String, action: String?)
    case emptyState(SpoolStateKey, headline: String, message: String?, action: String?)
    case recovery(SectionBanner, dataKept: String?, footnote: String)
    case content

    /// One line per block, for snapshots and failure messages.
    var snapshot: String {
        switch self {
        case let .spoolNote(pose, text):
            return "spool-note[\(pose.rawValue)] \(text)"
        case let .banner(banner):
            return "banner ⚠ \(banner.headline) — \(banner.body ?? "") [\(banner.actionTitle ?? "")]"
        case let .header(title, subtitle, action):
            return "header \(title)" + (subtitle.isEmpty ? "" : " / \(subtitle)") + (action.map { " [\($0)]" } ?? "")
        case let .emptyState(pose, headline, message, action):
            return "empty-state[\(pose.rawValue)] \(headline) / \(message ?? "")" + (action.map { " [\($0)]" } ?? "")
        case let .recovery(banner, dataKept, footnote):
            return "recovery ⚠ \(banner.headline) — \(banner.body ?? "") [\(banner.actionTitle ?? "")]"
                + " · \(SectionCopy.dataKept): \(dataKept ?? "—") · \(footnote)"
        case .content:
            return "content"
        }
    }
}

enum SectionPageAnatomy {
    /// The blocks a page shows for one rendering. `banner` is drawn only over content (a partial
    /// failure keeps readable content); an empty, loading or error page has no content to keep.
    static func blocks(copy: PageCopy,
                       state: SectionState,
                       banner: SectionBanner? = nil,
                       headerAction: String? = nil,
                       spoolNote: (pose: SpoolStateKey, text: String)? = nil,
                       hotkey: String) -> [PageBlock] {
        switch state.rendering {
        case .content:
            var blocks: [PageBlock] = []
            if let spoolNote { blocks.append(.spoolNote(spoolNote.pose, spoolNote.text)) }
            if let banner { blocks.append(.banner(banner)) }
            blocks.append(.header(title: copy.title, subtitle: copy.subtitle, action: headerAction))
            blocks.append(.content)
            return blocks
        case .empty:
            return [.emptyState(.ready, headline: state.headline, message: state.detail, action: state.actionTitle)]
        case .loading:
            return [.header(title: copy.name, subtitle: "", action: nil),
                    .emptyState(.ready, headline: state.headline, message: state.detail, action: nil)]
        case .error:
            let entry = state.recoveryID.map { RecoveryCatalog.entry($0).rendered(hotkey: hotkey) }
            let recovery = SectionBanner(headline: state.headline, actionTitle: state.actionTitle,
                                         body: state.detail, recoveryID: state.recoveryID)
            return [.header(title: copy.name, subtitle: SectionCopy.errorSubtitle, action: nil),
                    .recovery(recovery, dataKept: entry?.dataPolicy, footnote: SectionCopy.errorFootnote)]
        }
    }

    /// The whole page as text.
    static func snapshot(_ blocks: [PageBlock]) -> String { blocks.map(\.snapshot).joined(separator: "\n") }
}

/// S7a — one page of the window: the frame every section screen (S7b–S7g) draws itself in. It picks
/// exactly one of content / empty / loading / error from the section's `SectionState`, puts a partial
/// failure in a scoped banner over content that stays readable, and applies the window's 24 pt outer
/// padding and 24 pt gaps. No `body` elsewhere decides a rendering.
struct SectionPage<Content: View>: View {
    var copy: PageCopy
    var state: SectionState
    var banner: SectionBanner?
    var headerAction: PageAction?
    /// The empty state's call to action, or the error's recovery action.
    var onStateAction: (() -> Void)?
    /// The partial banner's recovery action.
    var onBannerAction: (() -> Void)?
    /// True while the failed scope retries: the recovery action is disabled (design §9).
    var isRetrying: Bool
    var spoolNote: (pose: SpoolStateKey, text: String)?
    var hotkey: String
    /// False for content that scrolls itself (a `List`, a split list/detail); the empty, loading and
    /// error renderings are then laid out unscrolled (each fits the 560 pt minimum window).
    var scrolls: Bool
    private let content: Content

    init(_ copy: PageCopy, state: SectionState, banner: SectionBanner? = nil, headerAction: PageAction? = nil,
         onStateAction: (() -> Void)? = nil, onBannerAction: (() -> Void)? = nil, isRetrying: Bool = false,
         spoolNote: (pose: SpoolStateKey, text: String)? = nil, hotkey: String, scrolls: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.copy = copy
        self.state = state
        self.banner = banner
        self.headerAction = headerAction
        self.onStateAction = onStateAction
        self.onBannerAction = onBannerAction
        self.isRetrying = isRetrying
        self.spoolNote = spoolNote
        self.hotkey = hotkey
        self.scrolls = scrolls
        self.content = content()
    }

    var blocks: [PageBlock] {
        SectionPageAnatomy.blocks(copy: copy, state: state, banner: banner, headerAction: headerAction?.title,
                                  spoolNote: spoolNote, hotkey: hotkey)
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { stack }
            } else {
                stack
            }
        }
        .background(WindowColor.canvas)
        .accessibilityIdentifier("section.page.\(state.rendering.rawValue)")
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .padding(MainWindowLayout.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func render(_ block: PageBlock) -> some View {
        switch block {
        case let .spoolNote(pose, text):
            SpoolNote(pose, text)
        case let .banner(banner):
            ScopedBanner(banner, isRetrying: isRetrying, onAction: onBannerAction)
        case let .header(title, subtitle, _):
            PageHeader(title, subtitle: subtitle, action: state.isContent ? headerAction : nil)
        case let .emptyState(pose, headline, message, action):
            EmptyState(pose: pose, headline: headline, message: message,
                       action: action.flatMap { title in
                           onStateAction.map { PageAction(title, identifier: "section.state.action", perform: $0) }
                       })
                .accessibilityIdentifier("section.state.\(state.rendering.rawValue)")
        case let .recovery(banner, dataKept, footnote):
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                ScopedBanner(banner, isRetrying: isRetrying, onAction: onStateAction)
                if let dataKept {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text(SectionCopy.dataKept.uppercased())
                            .windowFont(Tokens.Typography.key)
                            .foregroundStyle(WindowColor.secondaryInk)
                        Text(dataKept)
                            .windowFont(Tokens.Typography.body)
                            .foregroundStyle(WindowColor.ink)
                    }
                    .padding(Tokens.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.group).fill(WindowColor.surface))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group).strokeBorder(WindowColor.separator, lineWidth: 1))
                    .accessibilityElement(children: .combine)
                }
                Text(footnote)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            .accessibilityIdentifier("section.state.error")
        case .content:
            content
        }
    }
}
