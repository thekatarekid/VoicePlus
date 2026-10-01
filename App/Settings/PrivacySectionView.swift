import SwiftUI
import Shared

// S7f — Privacy's content (design §8.5), drawn inside `PrivacyScreen`'s `SectionPage` with the S7a
// components. Top to bottom: access (processing, microphone, typing access, optional context, hard
// mute) · on this Mac or a service · history · audio (J1) · meetings and sync · network activity ·
// delete data. Every state and every sentence comes from `PrivacySectionViewModel` / `PrivacyCopy`;
// this file only lays them out. The Diagnostics disclosure (flags, data panel, export) is
// `PrivacyScreen`'s.

struct PrivacySectionView: View {
    @ObservedObject var model: PrivacySectionViewModel
    @ObservedObject var audio: AudioInputSettingsViewModel
    @ObservedObject var meetings: MeetingsSectionViewModel
    @ObservedObject var sync: SyncSettingsViewModel
    @ObservedObject private var deletionRetry: ScopedRetry
    @ObservedObject private var activityRetry: ScopedRetry
    var settings: SettingsStore?
    var open: (WindowRoute) -> Void
    /// "Review retention" (the design's empty action): scrolls to the retention switches.
    var reviewRetention: () -> Void

    @State private var explainingContext = false

    init(model: PrivacySectionViewModel, meetings: MeetingsSectionViewModel, sync: SyncSettingsViewModel,
         settings: SettingsStore?, open: @escaping (WindowRoute) -> Void, reviewRetention: @escaping () -> Void) {
        self.model = model
        _audio = ObservedObject(wrappedValue: model.audio)
        _meetings = ObservedObject(wrappedValue: meetings)
        _sync = ObservedObject(wrappedValue: sync)
        _deletionRetry = ObservedObject(wrappedValue: model.deletionRetry)
        _activityRetry = ObservedObject(wrappedValue: model.activityRetry)
        self.settings = settings
        self.open = open
        self.reviewRetention = reviewRetention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            if !model.remaining.isEmpty { remainingList }
            access
            processing
            history
            audioGroup
            meetingsAndSync
            activity
            deleteData
        }
        .alert(PrivacyCopy.contextConfirmTitle, isPresented: $explainingContext) {
            Button(PrivacyCopy.contextConfirmAction) { model.enableScreenRecording() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(OptionalPermission.screenRecording.rationale)
        }
        .confirmationDialog(model.pendingDeletion?.title ?? "", isPresented: Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.pendingDeletion = nil } }
        ), presenting: model.pendingDeletion) { request in
            Button(request.confirmTitle, role: .destructive) { model.confirmDeletion() }
            Button(PrivacyCopy.keepIt, role: .cancel) { model.pendingDeletion = nil }
        } message: { request in
            Text(request.message)
        }
    }

    // MARK: Access — processing, microphone, typing access, optional context, hard mute

    private var access: some View {
        GroupBox(layout: .rows) {
            accessRow(PrivacyAccess.processing)
            ForEach(model.access) { row in accessRow(row) }
            RowView(PrivacyCopy.hardMuteTitle,
                    detail: model.isMuted ? PrivacyCopy.mutedNote
                        : (model.canControlMute ? PrivacyCopy.hardMuteOff : PrivacyCopy.hardMuteUnwired)) {
                HStack(spacing: Tokens.Spacing.s) {
                    StatusTag(model.isMuted ? "Muted" : "Not muted", kind: model.isMuted ? .warn : .neutral)
                    if model.canControlMute {
                        Button(model.isMuted ? PrivacyCopy.unmute : PrivacyCopy.mute) { model.setMuted(!model.isMuted) }
                            .accessibilityIdentifier("privacy.hardMute.toggle")
                    }
                }
            }
            .accessibilityIdentifier("privacy.hardMute")
        }
    }

    private func accessRow(_ row: PrivacyAccessRow) -> some View {
        RowView(row.title, detail: row.detail) {
            HStack(spacing: Tokens.Spacing.s) {
                StatusTag(row.status, kind: tagKind(row.tag))
                if let title = row.actionTitle, row.action != .none {
                    Button(title) {
                        if row.action == .explainThenRequest { explainingContext = true }
                        else { Task { await model.perform(row) } }
                    }
                    .accessibilityIdentifier("\(row.id).action")
                }
            }
        }
        .accessibilityIdentifier(row.id)
    }

    private func tagKind(_ tag: PrivacyAccessRow.Tag) -> StatusTag.Kind {
        switch tag {
        case .good: return .good
        case .warn: return .warn
        case .neutral: return .neutral
        }
    }

    // MARK: On this Mac or a service

    private var processing: some View {
        GroupBox(PrivacyCopy.processingGroup, layout: .rows) {
            ForEach(PrivacyProcessing.rows(settings: settings)) { row in
                RowView(row.title, detail: row.detail) {
                    StatusTag(row.status, kind: row.onDevice ? .good : .warn)
                }
                .accessibilityIdentifier(row.id)
            }
        }
        .accessibilityIdentifier("privacy.processing")
    }

    // MARK: History — ambient capture, other voices, transcript retention, recovery, dictation history

    private var history: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if model.historyState.rendering != .content {
                PrivacyScopedState(state: model.historyState, onAction: reviewRetention)
                    .accessibilityIdentifier("privacy.history.state")
            }
            GroupBox(PrivacyCopy.historyGroup, layout: .rows) {
                RowView(PrivacyCopy.saveHistoryTitle, detail: model.dictationHistorySwitchSentence) {
                    switchControl(PrivacyCopy.saveHistoryTitle, isOn: Binding(
                        get: { model.savesDictationHistory }, set: { model.savesDictationHistory = $0 }))
                }
                .accessibilityIdentifier("privacy.saveDictationHistory")
                RowView(PrivacyCopy.ambientTitle, detail: model.ambientMode.detail) {
                    SegmentedControl(PrivacyCopy.ambientTitle, selection: Binding(
                        get: { model.ambientMode }, set: { model.ambientMode = $0 }),
                        identifier: "privacy.ambientMode") { $0.title }
                        .fixedSize()
                }
                .accessibilityIdentifier("privacy.ambientCapture")
                RowView(PrivacyCopy.everySpeakerTitle,
                        detail: model.capturesEverySpeaker ? PrivacyCopy.everySpeakerOn : PrivacyCopy.everySpeakerOff) {
                    switchControl(PrivacyCopy.everySpeakerTitle, isOn: Binding(
                        get: { model.capturesEverySpeaker }, set: { model.capturesEverySpeaker = $0 }))
                        .disabled(!model.ambientCapture)
                }
                .accessibilityIdentifier("privacy.ambientEverySpeaker")
                RowView(PrivacyCopy.retentionTitle, detail: model.retentionSentence) {
                    Picker(PrivacyCopy.retentionTitle, selection: Binding(
                        get: { model.retentionDays }, set: { model.retentionDays = $0 })) {
                        ForEach(AmbientRetentionSettings.choices, id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .accessibilityIdentifier("privacy.retentionDays")
                RowView(PrivacyCopy.recoveryTitle, detail: model.recoverySentence) {
                    switchControl(PrivacyCopy.recoveryTitle, isOn: Binding(
                        get: { model.persistsRecovery }, set: { model.persistsRecovery = $0 }))
                }
                .accessibilityIdentifier("privacy.recoveryPersistence")
                RowView(PrivacyCopy.dictationHistoryTitle, detail: model.dictationHistorySentence)
                    .accessibilityIdentifier("privacy.dictationHistory")
            }
            .id(PrivacyScreen.retentionAnchor)
        }
    }

    // MARK: Audio — retain audio, keep 7/30/90 days/forever + disk limit (V5 F3), corpus label, folder (J1)

    private var audioGroup: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            GroupBox(PrivacyCopy.audioGroup, layout: .rows) {
                RowView(PrivacyCopy.retainAudioTitle, detail: model.audioRetentionSentence) {
                    switchControl(PrivacyCopy.retainAudioTitle, isOn: Binding(
                        get: { model.audioRetention }, set: { model.audioRetention = $0 }))
                        .accessibilityIdentifier("settings.saveRecordings")
                }
                .accessibilityIdentifier("settings.saveRecordingsNote")
                RowView(PrivacyCopy.keepTitle, detail: PrivacyCopy.keepDetail) {
                    Picker(PrivacyCopy.keepTitle, selection: Binding(
                        get: { model.recordingsRetentionDays }, set: { model.recordingsRetentionDays = $0 })) {
                        ForEach(model.retentionDayChoices, id: \.self) { days in
                            Text(model.retentionDaysLabel(days)).tag(days)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .accessibilityIdentifier("privacy.recordings.retention")
                RowView(PrivacyCopy.diskCapTitle, detail: PrivacyCopy.diskCapDetail) {
                    Picker(PrivacyCopy.diskCapTitle, selection: Binding(
                        get: { model.recordingsDiskCap }, set: { model.recordingsDiskCap = $0 })) {
                        ForEach(model.diskCapChoices, id: \.self) { bytes in
                            Text(model.diskCapLabel(bytes)).tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .accessibilityIdentifier("privacy.recordings.diskCap")
                corpusRow
                RowView(PrivacyCopy.recordingsTitle, detail: model.recordingsSentence) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Button(PrivacyCopy.revealInFinder) { model.revealRecordings() }
                            .accessibilityIdentifier("privacy.recordings.reveal")
                        Button(PrivacyCopy.deleteAll, role: .destructive) { model.requestDeletion(.recordings) }
                            .disabled((model.recordings?.utterances ?? 1) == 0)
                            .accessibilityIdentifier("privacy.recordings.deleteAll")
                    }
                }
                .accessibilityIdentifier("settings.recordings")
            }
            if model.audioState.rendering != .content {
                PrivacyScopedState(state: model.audioState)
                    .accessibilityIdentifier("privacy.audio.state")
            }
        }
    }

    private var corpusRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowView(PrivacyCopy.corpusTitle, detail: PrivacyCopy.corpusDetail) {
                HStack(spacing: Tokens.Spacing.s) {
                    TextField(PrivacyCopy.corpusPlaceholder, text: Binding(
                        get: { model.corpus.entered }, set: { model.corpus.entered = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { model.saveCorpus() }
                        .accessibilityLabel(PrivacyCopy.corpusTitle)
                    Button(PrivacyCopy.corpusSave) { model.saveCorpus() }
                        .disabled(!model.corpus.isUnsaved)
                }
            }
            if let failure = model.corpus.failureBanner {
                ScopedBanner(failure, onAction: { model.saveCorpus() })
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.m)
            }
        }
        .accessibilityIdentifier("privacy.recordings.corpus")
    }

    // MARK: Meetings and sync

    private var meetingsAndSync: some View {
        GroupBox(PrivacyCopy.meetingsSyncGroup, layout: .rows) {
            RowView(PrivacyCopy.meetingTitle, detail: meetings.isCaptureEnabled ? PrivacyCopy.meetingOn : PrivacyCopy.meetingOff) {
                switchControl(PrivacyCopy.meetingTitle, isOn: Binding(
                    get: { meetings.isCaptureEnabled }, set: { meetings.isCaptureEnabled = $0 }))
            }
            .accessibilityIdentifier("privacy.meetingCapture")
            let syncRow = PrivacyProcessing.sync(available: sync.isAvailable, paired: sync.fingerprint != nil)
            RowView(syncRow.title, detail: syncRow.detail) {
                HStack(spacing: Tokens.Spacing.s) {
                    StatusTag(syncRow.status, kind: syncRow.onDevice ? .neutral : .warn)
                    Button(PrivacyCopy.openSync) { open(.settings(.sync)) }
                }
            }
            .accessibilityIdentifier("privacy.sync")
        }
    }

    // MARK: Network activity · last 30 days

    private var activity: some View {
        GroupBox(PrivacyCopy.activityGroup, layout: .rows) {
            RowView(PrivacyCopy.killSwitchTitle, detail: model.windowSentence) {
                switchControl(PrivacyCopy.killSwitchTitle, isOn: Binding(
                    get: { model.killSwitch }, set: { model.killSwitch = $0 }))
            }
            .accessibilityIdentifier("privacy.killSwitch")
            RowView(model.bytesOutTodayLine) {
                Button(PrivacyCopy.refresh) { Task { await model.activityRetry.run { await model.reloadActivity() } } }
                    .disabled(activityRetry.isRetrying)
                    .accessibilityIdentifier("privacy.egressRefresh")
            }
            .accessibilityIdentifier("privacy.bytesOutToday")
            PrivacyActivityList(model: model)
                .accessibilityIdentifier("privacy.egressTable")
        }
    }

    // MARK: Delete data — scope and count, then what remains

    private var deleteData: some View {
        GroupBox(PrivacyCopy.deleteGroup, layout: .rows) {
            ForEach(PrivacyDataScope.allCases) { scope in
                RowView(scope.title, detail: model.inventory?.line(scope) ?? PrivacyCopy.readingKept) {
                    Button(PrivacyCopy.delete, role: .destructive) { model.requestDeletion(scope) }
                        .disabled(model.inventory?.count(scope)?.items == 0 || deletionRetry.isRetrying)
                        .accessibilityIdentifier("privacy.delete.\(scope.rawValue)")
                }
            }
            RowView(PrivacyCopy.deleteEverything) {
                Button(PrivacyCopy.deleteEverything, role: .destructive) { model.requestDeletion(nil) }
                    .disabled(model.inventory?.isEmpty == true || deletionRetry.isRetrying)
                    .accessibilityIdentifier("privacy.deleteAll")
            }
        }
    }

    /// Design §8.5 "partial deletion lists what remains": by scope, each with a count and names.
    private var remainingList: some View {
        GroupBox(PrivacyCopy.stillHere) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                ForEach(model.remaining) { remainder in
                    Text(remainder.line)
                        .windowFont(Tokens.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(WindowColor.ink)
                    ForEach(remainder.items, id: \.self) { item in
                        Text("• " + item)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                    }
                }
            }
        }
        .accessibilityIdentifier("privacy.delete.remaining")
    }

    // MARK: Controls

    private func switchControl(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

/// The dated activity list, or its one scoped state: "Reading activity…", the dated no-egress
/// result, or the unreadable-log error (which never says "Nothing left this Mac").
struct PrivacyActivityList: View {
    @ObservedObject var model: PrivacySectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = model.activityBanner, model.egress.isContent {
                ScopedBanner(banner, onAction: { Pasteboard.copy(model.activityDiagnostics) })
                    .padding(Tokens.Spacing.l)
            }
            if model.egress.isContent {
                ForEach(model.activity) { day in
                    Text(day.title)
                        .windowFont(Tokens.Typography.key)
                        .foregroundStyle(WindowColor.secondaryInk)
                        .padding(.horizontal, Tokens.Spacing.l)
                        .padding(.top, Tokens.Spacing.m)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.rows) { row in
                        RowView(row.destination, detail: detail(row)) {
                            StatusTag(row.status.label, kind: row.status == .allowed ? .neutral : .warn)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.summary)
                    }
                }
            } else {
                PrivacyScopedState(state: model.egress,
                                   onAction: model.egress.rendering == .error ? { Pasteboard.copy(model.activityDiagnostics) } : nil)
                    .padding(Tokens.Spacing.l)
                    .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
            }
        }
    }

    private func detail(_ row: NetworkActivityRow) -> String {
        var parts = [row.time.formatted(date: .omitted, time: .shortened), row.purpose]
        if let provider = row.provider { parts.append(provider) }
        if let out = row.bytesOut { parts.append(ByteCountFormatter.string(fromByteCount: Int64(out), countStyle: .binary) + " out") }
        return parts.joined(separator: " · ")
    }
}

/// A group's own empty / loading / error line: one glyph, one headline, one sentence, at most one
/// action. Never a spinner, and loading never uses the empty words.
struct PrivacyScopedState: View {
    let state: SectionState
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label(state.headline, systemImage: glyph)
                .windowFont(Tokens.Typography.body)
                .fontWeight(.medium)
                .foregroundStyle(state.rendering == .error ? WindowColor.attention : WindowColor.ink)
            if let detail = state.detail {
                Text(detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = state.actionTitle, let onAction {
                Button(title, action: onAction)
                    .accessibilityIdentifier("privacy.state.action")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
