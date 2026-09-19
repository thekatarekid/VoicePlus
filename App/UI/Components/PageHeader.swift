import SwiftUI

/// S7a — the one page title (design §8 "Use one clear page title"; prototype `.app-title`): the title
/// in the `title` role (24/30 semibold), the page's primary action at the trailing edge, and the
/// subtitle underneath in secondary ink. A page has exactly one; the window's title bar says only
/// "VoicePlus".
struct PageHeader: View {
    var title: String
    var subtitle: String?
    var action: PageAction?

    init(_ title: String, subtitle: String? = nil, action: PageAction? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    init(_ copy: PageCopy, action: PageAction? = nil) {
        self.init(copy.title, subtitle: copy.subtitle, action: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .center, spacing: Tokens.Spacing.l) {
                Text(title)
                    .windowFont(Tokens.Typography.title)
                    .foregroundStyle(WindowColor.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page.title")
                Spacer(minLength: Tokens.Spacing.l)
                if let action { PageActionButton(action: action) }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("page.subtitle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page's words: the title and subtitle its content rendering shows, and the name its loading and
/// error renderings title themselves with (the prototype's screen name). Defaults come from the
/// design screen (`design_copy.json`); a section overrides them only with real data (turn detail's
/// title is the turn's, not the prototype's sample).
struct PageCopy: Equatable {
    var screen: DesignScreen
    var title: String
    var subtitle: String
    var name: String

    init(_ screen: DesignScreen, title: String? = nil, subtitle: String? = nil, name: String? = nil) {
        self.screen = screen
        self.title = title ?? screen.page?.title ?? screen.name
        self.subtitle = subtitle ?? screen.page?.subtitle ?? ""
        self.name = name ?? screen.name
    }

    /// A sidebar section's page.
    static func section(_ section: MainWindowSection) -> PageCopy {
        PageCopy(section.screen, title: section.detailTitle, subtitle: section.subtitle)
    }

    /// A Settings subpage's page. Appearance and Updates are named for themselves in every rendering.
    static func settings(_ subpage: SettingsSubpage) -> PageCopy {
        switch subpage {
        case .appearance, .updates:
            return PageCopy(subpage.screen, title: subpage.pageTitle, subtitle: subpage.pageSubtitle, name: subpage.title)
        default:
            return PageCopy(subpage.screen, title: subpage.pageTitle, subtitle: subpage.pageSubtitle)
        }
    }
}
