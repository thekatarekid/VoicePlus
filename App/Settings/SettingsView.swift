import AppKit
import Engine
import Pipeline
import Shared
import SwiftUI

// S7g — Settings' seven subpages (design §8.6, `DESIGN.md` §9.6): General, Shortcuts, Appearance,
// Models, Providers, Sync, Updates — no other page. Each is drawn in `SectionPage` with the design's
// groups, rows, tags and key caps, renders exactly one base state, and puts a partial failure in a
// scoped banner over content that stays readable. The V4 rows the owner added (§0) are ordinary rows
// here: spacing and unknown-caret style (General), latch pause, the fn / 🌐 system-action prompt and
// draw-without-key (Shortcuts), the speaker-embedding model (Models).
//
// Every setting the R7 form had is still here, on the subpage `SettingsReachability` names for it;
// the reachability test reads this file for each marker. Data and the hard mute → Privacy, flags →
// Privacy › Diagnostics, the second-pass picker → Voice, snippets and personas → Dictionary & Apps.

// MARK: - Rows

/// A row with a system switch (design `toggle`).
struct SettingsToggleRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    var identifier: String

    var body: some View {
        RowView(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// A row with a pop-up menu (design `select`).
struct SettingsPickerRow<Option: Hashable>: View {
    var title: String
    var detail: String?
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String
    var identifier: String

    var body: some View {
        RowView(title, detail: detail) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }
}

/// A footnote under a page's groups (prototype `.tiny`).
struct SettingsFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .windowFont(Tokens.Typography.meta)
            .foregroundStyle(WindowColor.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

/// Design §8.6 General: shortcut, final preview (900 ms default / 600 / 1500 / manual review),
/// low-confidence preview, sound cues, launch at login — plus D6 spacing and D3 unknown-caret style.
struct GeneralSettingsPage: View {
    @ObservedObject var general: GeneralSettingsViewModel
    var corrections: CorrectionSettingsViewModel
    var hotkey: String
    var open: (SettingsSubpage) -> Void
    var runOnboarding: () -> Void

    /// Design §9: a failed save keeps the entered value and the previous active value (S02 inline,
    /// Try again re-commits it).
    @State private var launchAtLogin = SettingDraft(LaunchAtLogin.isEnabled)

    var body: some View {
        SectionPage(.settings(.general), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(layout: .rows) {
                    RowView(SettingsCopy.shortcutTitle, detail: SettingsCopy.shortcutDetail) {
                        Button { open(.shortcuts) } label: { KeyCap(general.hotkeyLabel) }
                            .accessibilityLabel(SettingsCopy.shortcutButtonLabel(general.hotkeyLabel))
                            .accessibilityIdentifier("settings.general.shortcut")
                    }
                    SettingsPickerRow(title: SettingsCopy.previewTitle, detail: SettingsCopy.previewDetail,
                                      selection: $general.previewDwell, options: SettingsCopy.dwellOrder,
                                      label: SettingsCopy.dwellTitle, identifier: "settings.previewDwell")
                    RowView(SettingsCopy.lowConfidenceTitle, detail: SettingsCopy.lowConfidenceDetail) {
                        StatusTag(SettingsCopy.reviewable)
                    }
                    SettingsToggleRow(title: SettingsCopy.soundCuesTitle, detail: SettingsCopy.soundCuesDetail,
                                      isOn: $general.soundCues, identifier: "settings.soundCues")
                    RowView(SettingsCopy.launchTitle,
                            detail: LaunchAtLogin.isAvailable ? SettingsCopy.launchDetail : SettingsCopy.launchUnavailable) {
                        Toggle(SettingsCopy.launchTitle, isOn: Binding(
                            get: { launchAtLogin.entered },
                            set: { on in
                                launchAtLogin.entered = on
                                commitLaunchAtLogin()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LaunchAtLogin.isAvailable)
                        .accessibilityIdentifier("settings.launchAtLogin")
                    }
                }
                if let failure = launchAtLogin.failureBanner {
                    ScopedBanner(failure, onAction: { commitLaunchAtLogin() })
                        .accessibilityIdentifier("settings.rowError.settings.launchAtLogin")
                }

                GroupBox(SettingsCopy.formattingTitle, layout: .rows) {
                    SettingsPickerRow(title: SettingsCopy.spacingTitle, detail: SettingsCopy.spacingDetail(general.spacing),
                                      selection: $general.spacing, options: SpacingPreference.allCases,
                                      label: SettingsCopy.spacingOption, identifier: "settings.formattingSpacing")
                    SettingsPickerRow(title: SettingsCopy.caretTitle, detail: SettingsCopy.caretDetail(general.unknownCaretStyle),
                                      selection: $general.unknownCaretStyle, options: UnknownCaretStyle.allCases,
                                      label: SettingsCopy.caretOption, identifier: "settings.unknownCaretStyle")
                }

                GroupBox(SettingsCopy.behaviourTitle, layout: .rows) {
                    RowView(SettingsCopy.onboardingTitle, detail: SettingsCopy.onboardingDetail) {
                        Button(SettingsCopy.onboardingAction, action: runOnboarding)
                            .accessibilityIdentifier("settings.runOnboardingAgain")
                    }
                }
                GroupBox(layout: .padded) {
                    CorrectionSettingsSection(model: corrections)
                }

                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text(SettingsCopy.moreSettings)
                        .windowFont(Tokens.Typography.section)
                        .foregroundStyle(WindowColor.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: Tokens.Spacing.s) {
                        ForEach(SettingsCopy.moreSettingsPages, id: \.self) { page in
                            Button(SettingsCopy.moreSettingsTitle(page)) { open(page) }
                                .accessibilityIdentifier("settings.more.\(page.rawValue)")
                        }
                    }
                }
            }
        }
        .onAppear {
            if !launchAtLogin.isUnsaved { launchAtLogin = SettingDraft(LaunchAtLogin.isEnabled) }
        }
    }

    private func commitLaunchAtLogin() {
        launchAtLogin.commit { on in
            guard LaunchAtLogin.set(enabled: on) else { throw LaunchAtLoginNotSaved() }
        }
    }
}

/// `SMAppService` refused the change; `LaunchAtLogin` logged why.
struct LaunchAtLoginNotSaved: Error {}

// MARK: - Shortcuts

/// Design §8.6 Shortcuts: key recorder with conflict result, hold explanation, "Double-tap to
/// latch", shortcut test — plus B2 latch pause, the I1 fn / 🌐 system-action prompt with "Open
/// Keyboard settings", and G1 draw-without-key while latched.
struct ShortcutsSettingsPage: View {
    @ObservedObject var general: GeneralSettingsViewModel
    @ObservedObject var shortcuts: ShortcutsPageModel
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.shortcuts), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                holdToTalk
                if let conflict = general.fnConflict {
                    ScopedBanner(SectionBanner(headline: conflict.headline, actionTitle: FnKeyConflict.actionTitle,
                                               body: conflict.detail),
                                 onAction: { general.openKeyboardSettings() })
                        .accessibilityIdentifier("settings.fnConflict")
                }
                GroupBox(layout: .rows) {
                    SettingsToggleRow(title: ShortcutCopy.latchTitle, detail: ShortcutCopy.latchDetail,
                                      isOn: $general.latchDoubleTap, identifier: "settings.latchDoubleTap")
                    RowView(ShortcutCopy.latchPauseTitle,
                            detail: general.latchDoubleTap ? ShortcutCopy.latchPauseDetail : ShortcutCopy.latchOffNote) {
                        HStack(spacing: Tokens.Spacing.s) {
                            Slider(value: $general.latchPauseSeconds, in: LatchSettings.pauseRange, step: 0.5)
                                .frame(width: 140)
                                .accessibilityLabel(ShortcutCopy.latchPauseTitle)
                                .accessibilityValue(ShortcutCopy.seconds(general.latchPauseSeconds))
                                .accessibilityIdentifier("settings.latchPause")
                            Text(ShortcutCopy.seconds(general.latchPauseSeconds))
                                .windowFont(Tokens.Typography.duration)
                                .foregroundStyle(WindowColor.ink)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .disabled(!general.latchDoubleTap)
                    }
                    SettingsToggleRow(title: ShortcutCopy.drawTitle,
                                      detail: general.latchDoubleTap ? ShortcutCopy.drawDetail : ShortcutCopy.latchOffNote,
                                      isOn: $general.drawWithoutKey, identifier: "settings.drawWithoutKey")
                        .disabled(!general.latchDoubleTap)
                    RowView(ShortcutCopy.testTitle, detail: shortcuts.testLine) {
                        Button(shortcuts.isTesting ? ShortcutCopy.testStop : ShortcutCopy.testStart) {
                            if shortcuts.isTesting { shortcuts.stopTesting() } else { shortcuts.startTesting() }
                        }
                        .disabled(!shortcuts.testMode.canProbe)
                        .accessibilityIdentifier("settings.shortcutTest")
                    }
                }
                GroupBox(SettingsCopy.keysTitle, layout: .rows) {
                    SettingsPickerRow(title: SettingsCopy.dictationKeyTitle, detail: general.hotkeyPermissionNote,
                                      selection: Binding(get: { general.hotkey }, set: { shortcuts.choose($0) }),
                                      options: HotkeyChoice.allCases,
                                      label: { $0.title }, identifier: "settings.hotkeyPicker")
                        .accessibilityIdentifier("settings.hotkeyPermissionNote")
                    RowView(SettingsCopy.actionsKeyTitle, detail: general.actKeyNote) {
                        Picker(SettingsCopy.actionsKeyTitle, selection: $general.actKey) {
                            ForEach(ActKeyChoice.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings.actKey")
                    }
                    .accessibilityIdentifier("settings.actKeyNote")
                    SettingsToggleRow(title: SettingsCopy.eventTapTitle, detail: SettingsCopy.eventTapDetail,
                                      isOn: $general.forceEventTap, identifier: "settings.forceEventTap")
                }
                SettingsFootnote(ShortcutCopy.footnote)
            }
        }
        .onAppear { general.refreshKeyStatus() }
        // Back from System Settings › Keyboard: read the 🌐 action again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            general.refreshKeyStatus()
        }
        .onDisappear { shortcuts.stopAll() }
    }

    /// The prototype's paper: "Hold to talk", the key in a large cap, the explanation, the recorder.
    private var holdToTalk: some View {
        GroupBox(layout: .padded) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text(ShortcutCopy.holdToTalk.uppercased())
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(WindowColor.secondaryInk)
                Text(general.hotkeyLabel)
                    .windowFont(Tokens.Typography.title)
                    .monospaced()
                    .foregroundStyle(WindowColor.ink)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.vertical, Tokens.Spacing.m)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(WindowColor.controlBorder, lineWidth: 1))
                    .accessibilityLabel(KeyCap.accessibilityLabel(for: general.hotkeyLabel))
                Text("\(ShortcutCopy.holdExplanation)\n\(ShortcutCopy.escapeCancels)")
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if shortcuts.isRecording {
                    HStack(spacing: Tokens.Spacing.s) {
                        Text(ShortcutCopy.recordingPrompt(general.hotkeyLabel))
                            .windowFont(Tokens.Typography.body)
                            .foregroundStyle(WindowColor.accent)
                            .accessibilityIdentifier("settings.hotkeyRecording")
                        Button(ShortcutCopy.stopRecording) { shortcuts.stopRecording() }
                    }
                } else {
                    Button(ShortcutCopy.changeShortcut) { shortcuts.startRecording() }
                        .accessibilityIdentifier("settings.hotkey")
                }
                if let change = shortcuts.lastChange {
                    if let banner = change.banner {
                        ScopedBanner(banner).accessibilityIdentifier("settings.hotkeyConflict")
                    } else if let line = change.confirmation {
                        Label(line, systemImage: "checkmark")
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.ready)
                    }
                }
            }
        }
    }
}

// MARK: - Appearance

/// Design §8.6 Appearance: follow system / light / dark (windows only; the pill stays dark), Reduce
/// Motion, presence visibility, Larger Text. No mascot picker: Spool is the fixed mascot.
struct AppearanceSettingsPage: View {
    @ObservedObject var general: GeneralSettingsViewModel
    var hotkey: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        SectionPage(.settings(.appearance), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(layout: .rows) {
                    RowView(SettingsCopy.themeTitle, detail: SettingsCopy.themeDetail) {
                        SegmentedControl(SettingsCopy.themeTitle, options: WindowTheme.allCases,
                                         selection: $general.theme, identifier: "settings.theme") { $0.title }
                            .fixedSize()
                    }
                    SettingsToggleRow(title: SettingsCopy.reduceMotionTitle,
                                      detail: SettingsCopy.reduceMotionDetail(system: systemReduceMotion),
                                      isOn: $general.reduceMotion, identifier: "settings.reduceMotion")
                    SettingsPickerRow(title: SettingsCopy.textSizeTitle, detail: SettingsCopy.textSizeDetail,
                                      selection: $general.textSize, options: WindowTextSize.allCases,
                                      label: { $0.title }, identifier: "settings.textSize")
                }
                GroupBox(SettingsCopy.presenceTitle, layout: .rows) {
                    SettingsToggleRow(title: SettingsCopy.presenceIndicatorTitle, detail: SettingsCopy.presenceIndicatorDetail,
                                      isOn: $general.presenceIndicator, identifier: "settings.presenceIndicator")
                    SettingsToggleRow(title: SettingsCopy.hideFullScreenTitle, detail: SettingsCopy.hideFullScreenDetail,
                                      isOn: $general.presenceHideInFullScreen, identifier: "settings.presenceHideInFullScreen")
                        .disabled(!general.presenceIndicator)
                }
                SettingsFootnote(SettingsCopy.mascotNote)
            }
        }
    }
}

// MARK: - Models

/// Design §8.6 Models: compatible model, installed size, real byte progress → Verifying → Loading →
/// Ready, retry / cancel, last working model — plus the H3 speaker-embedding row, the optional
/// refinement model, and the per-stage routing that used to be the Models tab.
struct ModelsSettingsPage: View {
    @ObservedObject var page: ModelsPageModel
    @ObservedObject var models: ModelsSettingsViewModel
    var refinement: RefinementReadiness
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.models), state: page.state(hotkey: hotkey), banner: page.banner,
                    onStateAction: { page.install() }, onBannerAction: { page.retry() },
                    isRetrying: page.phase.isBusy, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(layout: .rows) {
                    RowView(ModelsPageCopy.stackTitle, detail: page.phase.statusLine) {
                        StatusTag(page.phase.tag.text, kind: page.phase.tag.kind)
                    }
                    .accessibilityIdentifier("settings.models.stack")
                    progress
                    ForEach(page.rows) { row in
                        RowView(row.name, detail: detail(row)) {
                            StatusTag(row.installed ? SettingsCopy.installed : SettingsCopy.notInstalled,
                                      kind: row.installed ? .good : .warn)
                        }
                        .accessibilityIdentifier("settings.models.\(row.id.rawValue)")
                    }
                    if !page.missing.isEmpty && !page.phase.isDownloading {
                        RowView(SettingsCopy.missingTitle, detail: SettingsCopy.missingDetail(page.missing)) {
                            Button(ModelsPageCopy.install) { page.install() }
                                .accessibilityIdentifier("settings.models.install")
                        }
                    }
                    RowView(ModelsPageCopy.lastWorkingTitle,
                            detail: (page.lastWorking ?? page.inUseNow).map(ModelsPageCopy.lastWorking) ?? ModelsPageCopy.noLastWorking)
                    RowView(SettingsCopy.speechSummaryTitle, detail: models.speechModelSummary)
                        .accessibilityIdentifier("settings.speechModel")
                }
                GroupBox(ModelsPageCopy.refinementTitle, layout: .rows) {
                    RowView(SettingsCopy.refinementRowTitle, detail: refinement.note) {
                        StatusTag(refinement.isAvailable ? SettingsCopy.ready : SettingsCopy.off,
                                  kind: refinement.isAvailable ? .good : .neutral)
                    }
                }
                GroupBox(ModelsPageCopy.routingTitle, layout: .rows) {
                    ForEach(RoutableStage.all) { stage in
                        SettingsPickerRow(title: stage.title, detail: nil,
                                          selection: Binding(get: { models.choice(for: stage.id) },
                                                             set: { models.set($0, for: stage.id) }),
                                          options: models.options(for: stage), label: { $0.title },
                                          identifier: "settings.routing.\(stage.id.rawValue)")
                    }
                    RowView(SettingsCopy.resetRoutingTitle, detail: ModelsPageCopy.routingDetail) {
                        Button(SettingsCopy.resetRouting) { models.resetToAuto() }
                            .accessibilityIdentifier("settings.resetRoutingToAuto")
                    }
                }
                SettingsFootnote(ModelsPageCopy.footnote)
            }
        }
        .task { await page.refresh() }
    }

    /// Native progress only (design §8.9: no spinning tape): determinate with a true denominator.
    @ViewBuilder private var progress: some View {
        switch page.phase {
        case .downloading(let p):
            RowView(SettingsCopy.downloadTitle, detail: page.phase.statusLine) {
                HStack(spacing: Tokens.Spacing.s) {
                    if p.bytesExpected > 0 {
                        ProgressView(value: p.fraction).frame(width: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button(ModelsPageCopy.cancel) { page.cancel() }
                        .accessibilityIdentifier("settings.models.cancel")
                }
            }
        case .starting, .verifying, .loading:
            RowView(page.phase == .loading ? SettingsCopy.loadTitle
                    : page.phase == .verifying ? SettingsCopy.verifyTitle : SettingsCopy.downloadTitle) {
                HStack(spacing: Tokens.Spacing.s) {
                    ProgressView().controlSize(.small)
                    if page.phase.isDownloading {
                        Button(ModelsPageCopy.cancel) { page.cancel() }
                            .accessibilityIdentifier("settings.models.cancel")
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func detail(_ row: ModelsPage.Row) -> String {
        guard row.id == .speakerEmbedding, let note = ModelsPage.speakerNote(installed: row.installed) else { return row.detail }
        return "\(row.detail). \(note)"
    }
}

// MARK: - Providers

/// Design §8.6 Providers: the selected route, connectivity, and credentials in a secure control.
struct ProvidersSettingsPage: View {
    @ObservedObject var credentials: ProviderCredentialsModel
    @ObservedObject var connectors: ConnectorsSettingsViewModel
    @ObservedObject var models: ModelsSettingsViewModel
    var hotkey: String

    @State private var exploring = false
    @FocusState private var focusedService: String?

    var body: some View {
        let state = ProvidersPage.state(hasKey: credentials.hasAnyKey, discovered: models.connectedProviders,
                                        connectorsSignedIn: connectors.anySignedIn, exploring: exploring || credentials.hasStorageFailure, hotkey: hotkey)
        SectionPage(.settings(.providers), state: state, onStateAction: { exploring = true }, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(ProvidersCopy.routeTitle, layout: .rows) {
                    ForEach(ProviderRoute.rows(routing: models.routing)) { row in
                        RowView(row.title, detail: row.detail) {
                            StatusTag(row.isLocal ? ProvidersCopy.local : ProvidersCopy.service,
                                      kind: row.isLocal ? .good : .neutral)
                        }
                    }
                    RowView(ProvidersCopy.cloudFallbackTitle, detail: ProvidersCopy.cloudFallbackDetail) {
                        StatusTag(ProvidersCopy.off)
                    }
                    RowView(ProvidersCopy.discoveredTitle,
                            detail: models.connectedProviders.isEmpty ? ProvidersCopy.noneDiscovered
                                                                      : ProvidersCopy.discovered(models.connectedProviders)) {
                        Button(ProvidersCopy.connectWhatYouPayFor) { focusedService = credentials.services.first?.id }
                            .accessibilityIdentifier("settings.connectProviders")
                    }
                    .accessibilityIdentifier("settings.connectedProviders")
                }
                GroupBox(ProvidersCopy.servicesTitle, layout: .rows) {
                    ForEach(credentials.services) { service in
                        serviceRow(service)
                    }
                }
                ForEach(credentials.services.filter { credentials.saveFailures[$0.id] != nil }) { service in
                    if let banner = credentials.saveFailures[service.id] {
                        ScopedBanner(banner, onAction: { credentials.save(service) })
                    }
                }
                SettingsFootnote(ProvidersCopy.keysFootnote)
                ConnectorsSettingsTab(model: connectors)
            }
        }
        .onAppear { credentials.reload(); connectors.reload() }
    }

    @ViewBuilder private func serviceRow(_ service: ProviderService) -> some View {
        let status = credentials.status(service)
        RowView(service.name, detail: status.line) {
            HStack(spacing: Tokens.Spacing.s) {
                if status == .storageUnavailable {
                    Button(ProvidersCopy.checkStorage) { credentials.reload() }
                        .accessibilityIdentifier("settings.provider.\(service.id).retryStorage")
                } else if status.hasKey {
                    if status == .reachable { StatusTag(ProvidersCopy.connected, kind: .good) }
                    Button(ProvidersCopy.test) { Task { await credentials.test(service) } }
                        .disabled(status == .testing)
                        .accessibilityIdentifier("settings.provider.\(service.id).test")
                    Button(ProvidersCopy.remove) { credentials.remove(service) }
                        .accessibilityIdentifier("settings.provider.\(service.id).remove")
                } else {
                    SecureField(ProvidersCopy.keyField, text: Binding(
                        get: { credentials.entered[service.id] ?? "" },
                        set: { credentials.entered[service.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($focusedService, equals: service.id)
                        .onSubmit { credentials.save(service) }
                        .accessibilityLabel("\(service.name) \(ProvidersCopy.keyField)")
                        .accessibilityIdentifier("settings.provider.\(service.id).key")
                    Button(ProvidersCopy.save) { credentials.save(service) }
                        .disabled((credentials.entered[service.id] ?? "").isEmpty)
                }
            }
        }
    }
}

// MARK: - Sync

/// Design §8.6 Sync: pairing comparison, connected devices, paused / offline, conflict review.
struct SyncSettingsPage: View {
    @ObservedObject var sync: SyncSettingsViewModel
    var database: AppDatabase?
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.sync), state: sync.state(showingSetup: false), banner: sync.banner,
                    onStateAction: { sync.startPairing() }, onBannerAction: { sync.bannerAction() },
                    isRetrying: sync.isSyncing, hotkey: hotkey) {
            SyncSettingsTab(model: sync, database: database)
        }
    }
}

// MARK: - Updates

/// Design §8.6 Updates: installed version, checking, available, downloading, install-ready and
/// failure; installing protects active capture and unsaved drafts before the restart.
struct UpdatesSettingsPage: View {
    @ObservedObject var updates: UpdatesPageModel
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.updates), state: .content, banner: updates.banner,
                    onBannerAction: { updates.retry() }, isRetrying: updates.phase == .checking, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(layout: .rows) {
                    RowView(UpdatesCopy.installedTitle, detail: UpdatesCopy.installed(updates.version))
                        .accessibilityIdentifier("settings.version")
                    RowView(SettingsCopy.updateStatusTitle, detail: updates.statusLine) { updateAction }
                        .accessibilityIdentifier("settings.checkForUpdates")
                    if case .downloading(_, let fraction?) = updates.phase {
                        RowView(SettingsCopy.downloadTitle) { ProgressView(value: fraction).frame(width: 160) }
                    }
                    if updates.canUpdate {
                        SettingsToggleRow(title: UpdatesCopy.automaticTitle, detail: UpdatesCopy.automaticDetail,
                                          isOn: $updates.automaticChecks, identifier: "settings.updates.automatic")
                    }
                }
                if let pending = updates.pendingRestart, let message = UpdateRestartGuard.message(pending) {
                    restartNotice(pending, message: message)
                }
            }
        }
    }

    @ViewBuilder private var updateAction: some View {
        if updates.canUpdate {
            switch updates.phase {
            case .checking, .downloading(_, nil):
                ProgressView().controlSize(.small)
            case .downloading:
                EmptyView()
            case .available:
                Button(UpdatesCopy.download) { updates.download() }.buttonStyle(.borderedProminent)
            case .readyToInstall:
                Button(UpdatesCopy.installAndRestart) { updates.install() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.updates.install")
            case .idle, .upToDate, .failed:
                Button(UpdatesCopy.checkNow) { updates.check() }
            }
        }
    }

    private func restartNotice(_ decision: UpdateRestartGuard.Decision, message: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label(message, systemImage: "exclamationmark.triangle")
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(WindowColor.attention)
            HStack(spacing: Tokens.Spacing.s) {
                if case .confirmDrafts = decision {
                    Button(UpdatesCopy.installAnyway) { updates.confirmRestart() }
                }
                Button(SettingsCopy.notNow) { updates.dismissRestart() }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group).strokeBorder(WindowColor.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.updates.restartGuard")
    }
}

// MARK: - Copy

enum SettingsCopy {
    // General (prototype `case'settings'`)
    static let shortcutTitle = "Shortcut"
    static let shortcutDetail = "Hold to talk; release to preview and insert."
    static func shortcutButtonLabel(_ key: String) -> String { "Shortcut: \(key). Change in Shortcuts." }
    static let previewTitle = "Final preview"
    static let previewDetail = "Shown before the first insertion attempt."
    /// The prototype's `<select>` order: 900 ms · default, 600 ms, 1500 ms, Manual review.
    static let dwellOrder: [PreviewDwell] = [.standard, .long, .manual]
    static func dwellTitle(_ dwell: PreviewDwell) -> String {
        switch dwell {
        case .standard: return "600 ms · default"
        case .short: return "600 ms"
        case .long: return "1200 ms"
        case .manual: return "Manual review"
        }
    }
    static let lowConfidenceTitle = "Low-confidence preview"
    static let lowConfidenceDetail = "Same preview delay for every transcript; hover pauses it."
    static let reviewable = "Reviewable"
    static let soundCuesTitle = "Sound cues"
    static let soundCuesDetail = "Subtle start and stop feedback. No success sound until an insertion is verified."
    static let launchTitle = "Launch at login"
    static let launchDetail = "Ready when you start your Mac."
    static let launchUnavailable = "Only a VoicePlus that is running from an .app bundle can register itself as a login item."
    static let formattingTitle = "Formatting"
    static let spacingTitle = "Spacing"
    static func spacingOption(_ value: SpacingPreference) -> String {
        switch value {
        case .automatic: return "Automatic"
        case .always: return "Always add a space"
        case .never: return "Never add a space"
        }
    }
    static func spacingDetail(_ value: SpacingPreference) -> String {
        switch value {
        case .automatic: return "A space only where the text before the cursor needs one."
        case .always: return "A leading space unless the field is empty or already ends in one."
        case .never: return "Your words land exactly where the cursor is, with no space added."
        }
    }
    static let caretTitle = "When the cursor can’t be read"
    static func caretOption(_ value: UnknownCaretStyle) -> String {
        switch value {
        case .sentence: return "As a sentence"
        case .asSpoken: return "Exactly as spoken"
        }
    }
    static func caretDetail(_ value: UnknownCaretStyle) -> String {
        switch value {
        case .sentence: return "Three or more words keep a capital and a full stop; shorter phrases don’t."
        case .asSpoken: return "No capital or full stop you didn’t say. Spoken punctuation is kept."
        }
    }
    static let behaviourTitle = "Behaviour"
    static let onboardingTitle = "Setup"
    static let onboardingDetail = "Walk through permissions, the model, your key and your voice again."
    static let onboardingAction = "Run onboarding again"
    static let moreSettings = "More settings"
    static let moreSettingsPages: [SettingsSubpage] = [.models, .providers, .appearance, .updates]
    static func moreSettingsTitle(_ page: SettingsSubpage) -> String { page == .providers ? "Providers & Sync" : page.title }

    // Shortcuts
    static let keysTitle = "Keys"
    static let dictationKeyTitle = "Dictation key"
    static let actionsKeyTitle = "Actions key"
    static let eventTapTitle = "Use the legacy event-tap listener"
    static let eventTapDetail = "Only if the dictation key stops responding. It needs VoicePlus in Privacy & Security › Input Monitoring, and macOS hands that permission over only at launch, so you have to quit and reopen."

    // Appearance
    static let themeTitle = "Windows"
    static let themeDetail = "Follow system, light or dark. The pill stays dark and keeps its place at the top of the screen."
    static let reduceMotionTitle = "Reduce motion"
    static func reduceMotionDetail(system: Bool) -> String {
        "Spool and the pill stop moving and still show every state. macOS Reduce Motion is \(system ? "on" : "off"), and always applies."
    }
    static let textSizeTitle = "Larger text"
    static let textSizeDetail = "Window text only. The pill keeps its size and moves overflow to Review."
    static let presenceTitle = "Presence"
    static let presenceIndicatorTitle = "Show indicator under the notch"
    static let presenceIndicatorDetail = "A small chin under the camera housing that says VoicePlus is alive — and shows when the mic is open or muted."
    static let hideFullScreenTitle = "Hide it in full screen"
    static let hideFullScreenDetail = "Only the quiet states hide. Listening, working and muted always stay visible."
    static let mascotNote = "Spool is VoicePlus’s one mascot. Reduce Motion changes its movement, never its identity."

    // Models
    static let installed = "Installed"
    static let notInstalled = "Not installed"
    static let missingTitle = "Missing models"
    static func missingDetail(_ ids: [ModelID]) -> String {
        let bytes = ids.reduce(Int64(0)) { $0 + ModelCatalog.descriptor($1).approxBytes }
        return "\(ids.map { ModelCatalog.descriptor($0).displayName }.joined(separator: ", ")) · \(ByteText.short(bytes)) to download"
    }
    static let speechSummaryTitle = "On this Mac"
    static let refinementRowTitle = "Second pass"
    static let ready = "Ready"
    static let off = "Off"
    static let resetRoutingTitle = "Every stage"
    static let resetRouting = "Reset all to Auto"
    static let downloadTitle = "Download"
    static let verifyTitle = "Verification"
    static let loadTitle = "Loading into memory"

    // Updates
    static let updateStatusTitle = "Updates"
    static let notNow = "Not now"
}

/// Identifiable wrapper so `Table` can display `NetworkLogRecord`s (whose `id` is optional).
/// Used by Privacy › Transmitted (`PrivacySectionView`), which is where the Data Panel now lives.
struct DataRow: Identifiable {
    let record: NetworkLogRecord
    var id: String { "\(record.id ?? -1)-\(record.timestamp.timeIntervalSince1970)" }
    var timestamp: Date { record.timestamp }
    var stage: String { record.stage }
    var provider: String { record.provider }
    var host: String { record.host }
    var bytesOut: Int { record.bytesOut }
    var bytesIn: Int { record.bytesIn }
    var purpose: String { record.purpose }
}
