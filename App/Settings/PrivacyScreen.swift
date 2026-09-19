import SwiftUI

// S7a entry point — owned by S7f from here on (build doc §3: `App/Settings/Privacy*.swift`).
//
// The shell builds `PrivacyScreen(context:)` and nothing else for this section, so S7f replaces this
// body with the design's Privacy (design §8.5) drawn in `SectionPage` with `App/UI/Components/`,
// without touching the shell. Until then it hosts the R7 Privacy pane unchanged, plus the one thing
// routing needs today: the **Diagnostics** disclosure that the old Flags and Data tabs re-home to
// (design §8.5, build doc S7a). Its open state is `context.navigation.isExpanded(.diagnostics)`, so a
// deep link to either tab opens it. S7f moves the data panel into it and folds it into the page.
struct PrivacyScreen: SectionScreen {
    static let section: MainWindowSection = .privacy

    let context: SectionContext
    @ObservedObject private var navigation: SectionNavigation
    @ObservedObject private var flags: FlagsViewModel

    init(context: SectionContext) {
        self.context = context
        _navigation = ObservedObject(wrappedValue: context.navigation)
        _flags = ObservedObject(wrappedValue: context.window.flags)
    }

    var body: some View {
        VStack(spacing: 0) {
            PrivacySectionView(model: context.window.privacy)
            DisclosureGroup(SectionDisclosure.diagnostics.title, isExpanded: Binding(
                get: { navigation.isExpanded(.diagnostics) },
                set: { navigation.setExpanded(.diagnostics, $0) }
            )) {
                ScrollView { featureFlags.padding(.vertical, Tokens.Spacing.s) }
                    .frame(maxHeight: 280)
            }
            .windowFont(Tokens.Typography.body)
            .padding(.horizontal, MainWindowLayout.outerPadding)
            .padding(.vertical, Tokens.Spacing.m)
            .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
            .accessibilityIdentifier("privacy.diagnostics")
        }
        .onAppear { flags.reload() }
    }

    /// Feature flags, re-homed from the old Flags tab: the same toggles and reset, the same service.
    private var featureFlags: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Risky bets ship behind flags the Lab measures. Flip one to compare on your own audio.")
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            ForEach(flags.rows) { row in
                Toggle(isOn: Binding(get: { row.enabled }, set: { flags.set($0, for: row.flag) })) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        HStack(spacing: Tokens.Spacing.s) {
                            Text(row.flag.id)
                            if row.overridden { StatusTag("overridden", kind: .warn) }
                        }
                        Text(row.flag.description)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                    }
                }
                .accessibilityIdentifier("privacy.diagnostics.flag.\(row.flag.id)")
            }
            Button("Reset to defaults") { flags.resetAll() }
                .accessibilityIdentifier("privacy.diagnostics.flagsReset")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
