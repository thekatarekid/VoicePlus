import Lab
import SwiftUI
import Shared

// R7.2 / S7e — Voice's content (design §8.4; prototype `renderScreen` case 'voice'): a group with the
// Microphone picker and Input quality, the test under it, Recognition (Language, Your voice, the
// "Not you" corrections), the second pass, and the benchmarks in a disclosure. `VoiceScreen` puts it
// in the page; every state and every sentence comes from `VoiceSectionViewModel` and the copy enums.

struct VoiceSectionView: View {
    @ObservedObject var model: VoiceSectionViewModel
    @ObservedObject var audio: AudioInputSettingsViewModel
    @ObservedObject var test: VoiceMicrophoneTest
    @ObservedObject var lab: LabPanelViewModel
    @ObservedObject var counters: BenchmarkViewModel
    @ObservedObject var navigation: SectionNavigation
    var hotkey: String
    /// The refinement picker's view model, built once from the same store the old Voice tab used so
    /// the saved mode is the saved mode.
    private let refinement: VoiceSettingsViewModel

    init(model: VoiceSectionViewModel, navigation: SectionNavigation, hotkey: String) {
        self.model = model
        _audio = ObservedObject(wrappedValue: model.audio)
        _test = ObservedObject(wrappedValue: model.test)
        _lab = ObservedObject(wrappedValue: model.lab)
        _counters = ObservedObject(wrappedValue: model.counters)
        _navigation = ObservedObject(wrappedValue: navigation)
        self.hotkey = hotkey
        refinement = MainWindowController.refinementViewModel()
    }

    var body: some View {
        let presentation = model.testPresentation
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            microphoneGroup(presentation)
            VoiceTestPanel(test: test, presentation: presentation) { model.perform($0) }
            recognitionGroup
            GroupBox(VoiceCopy.secondPass, layout: .rows) {
                VoiceSettingsTab(model: refinement)
            }
            benchmarksDisclosure
        }
        .onChange(of: test.phase) { _, _ in model.testDidEnd() }
    }

    // MARK: Microphone + Input quality

    private func microphoneGroup(_ presentation: VoiceTestPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            GroupBox(layout: .rows) {
                RowView(VoiceCopy.microphoneTitle, detail: VoiceCopy.microphoneDetail) {
                    Picker(VoiceCopy.microphoneTitle, selection: Binding(
                        get: { audio.selection },
                        set: { model.selectMicrophone($0) }
                    )) {
                        Text(VoiceCopy.automatic).tag(AudioInputSettingsViewModel.automatic)
                        ForEach(audio.devices) { Text(audio.title(for: $0)).tag($0.uid) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    .disabled(!model.isMicrophonePickerEnabled)
                    .accessibilityLabel(VoiceCopy.microphoneTitle)
                    .accessibilityIdentifier("settings.microphone")
                }
                if model.microphone.rendering == .empty {
                    // "No microphones found" — its own state, never confused with "No voice enrolled".
                    SectionStateView(state: model.microphone) { model.refreshDevices() }
                        .padding(.vertical, Tokens.Spacing.m)
                        .padding(.horizontal, Tokens.Spacing.l)
                        .accessibilityIdentifier("voice.microphone.none")
                }
                RowView(VoiceTestCopy.rowTitle, detail: VoiceTestCopy.rowDetail) {
                    VoiceTestButton(button: presentation.primary) { model.perform($0) }
                }
            }
            Text(audio.note)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.microphoneNote")
        }
    }

    // MARK: Recognition — Language, Your voice, "Not you"

    private var recognitionGroup: some View {
        GroupBox(VoiceCopy.recognition, layout: .rows) {
            RowView(VoiceLanguageCopy.rowTitle, detail: VoiceLanguageCopy.rowDetail) {
                Picker(VoiceLanguageCopy.rowTitle, selection: Binding(
                    get: { model.languageSelection },
                    set: { model.selectLanguage($0) }
                )) {
                    ForEach(model.languageCapability.options) { option in
                        Text(option.title).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .disabled(model.languageCapability.languages.isEmpty)
                .accessibilityLabel(VoiceLanguageCopy.rowTitle)
                .accessibilityIdentifier("voice.language")
            }
            languageDetails
            if let enrolling = model.enrolling {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    SpeakerEnrollmentView(model: enrolling) { model.cancelEnrollment() }
                    Button(VoiceEnrollmentCopy.stop) { model.cancelEnrollment() }
                        .accessibilityIdentifier("voice.enrollment.stop")
                }
                .padding(Tokens.Spacing.l)
                .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
                .accessibilityIdentifier("voice.enrollment.running")
            } else {
                enrollmentRow
                if model.enrollment.rendering == .error {
                    SectionStateView(state: model.enrollment) { model.beginEnrollment() }
                        .padding(.vertical, Tokens.Spacing.m)
                        .padding(.horizontal, Tokens.Spacing.l)
                        .accessibilityIdentifier("voice.enrollment.error")
                }
                if case .enrolled(_, _, let notYou) = model.enrollmentStatus {
                    RowView(notYou.title, detail: notYou.summary) {
                        Text("\(notYou.corrections)")
                            .windowFont(Tokens.Typography.key)
                            .foregroundStyle(WindowColor.secondaryInk)
                    }
                    .accessibilityIdentifier("voice.enrollment.notYou")
                }
            }
        }
    }

    private var enrollmentRow: some View {
        let status = model.enrollmentStatus
        return RowView(VoiceEnrollmentCopy.rowTitle, detail: VoiceEnrollmentCopy.rowDetail + " " + status.line(hotkey: hotkey)) {
            HStack(spacing: Tokens.Spacing.s) {
                StatusTag(status.tag, kind: status.tagIsGood ? .good : .neutral)
                if case .enrolled(_, false, _) = status {
                    StatusTag(VoiceEnrollmentCopy.filteringUnavailableTag, kind: .warn)
                }
                Button(status.primaryAction) { model.beginEnrollment() }
                    .disabled(test.phase.isCapturing)
                    .accessibilityIdentifier(status.isEnrolled ? "voice.enrollment.reenroll" : "voice.enrollment.setUp")
                if status.isEnrolled {
                    Button(VoiceEnrollmentCopy.delete, role: .destructive) { model.deleteEnrollment() }
                        .accessibilityIdentifier("voice.enrollment.delete")
                }
            }
        }
        .accessibilityIdentifier("voice.enrollment")
    }

    /// The capability note and the mixed-script preview.
    private var languageDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(model.languageNote)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voice.language.note")
            if model.languageCapability.recognizerName != nil {
                Text(VoiceLanguageCopy.previewTitle.uppercased())
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(WindowColor.secondaryInk)
                preview(model.scriptPreview)
                if let unsupported = model.unsupportedScriptPreview {
                    preview(unsupported)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.m)
        .padding(.horizontal, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.language.preview")
    }

    private func preview(_ preview: VoiceScriptPreview) -> some View {
        let recognizer = model.languageCapability.recognizerName
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            preview.runs.reduce(Text("")) { text, run in
                let piece = Text(run.text)
                return text + (run.supported
                    ? piece.foregroundColor(WindowColor.ink)
                    : piece.foregroundColor(WindowColor.secondaryInk).underline(true, pattern: .dot, color: WindowColor.uncertainty))
            }
            .windowFont(Tokens.Typography.body)
            .textSelection(.enabled)
            ForEach(Array(preview.lines(recognizer: recognizer).enumerated()), id: \.offset) { index, line in
                Label(line, systemImage: preview.scripts[index].supported ? "checkmark" : "xmark")
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(preview.scripts[index].supported ? WindowColor.secondaryInk : WindowColor.attention)
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(WindowColor.surface))
    }

    // MARK: Benchmarks — a disclosure with stage, result and diagnostics (the whole Lab, plus R4.1b)

    private var benchmarksDisclosure: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { navigation.isExpanded(.benchmarks) },
            set: { navigation.setExpanded(.benchmarks, $0) }
        )) {
            benchmarkContent
                .padding(.top, Tokens.Spacing.m)
        } label: {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(SectionDisclosure.benchmarks.title)
                    .windowFont(Tokens.Typography.section)
                    .foregroundStyle(WindowColor.ink)
                Text(model.benchmarkSummary)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("voice.benchmarks.summary")
            }
        }
        .accessibilityIdentifier("voice.benchmarks")
    }

    @ViewBuilder private var benchmarkContent: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if model.benchmark.isContent {
                counterRows
                LabPanelView(model: lab)
                // P6.1's personal WER trend, which used to be the Lab window's second tab.
                PersonalWERView(tracker: MainWindowController.environment.personalWER)
                Button(lab.isRunning ? "Running…" : SectionCopy.runBenchmark) { model.startRun() }
                    .disabled(lab.isRunning)
                    .accessibilityIdentifier("voice.benchmark.run")
            } else if model.benchmark.rendering == .loading {
                Text(model.benchmark.headline).windowFont(Tokens.Typography.body).fontWeight(.medium)
                if let percent = model.benchmarkProgressText {
                    Text(percent).windowFont(Tokens.Typography.duration)
                }
                ProgressView(value: progressValue).frame(width: 160)
                Button("Cancel") { model.cancelRun() }
                // Partial results as they land (§9.4): the Lab's own panel shows every report so far.
                LabPanelView(model: lab)
            } else if model.benchmark.rendering == .error {
                SectionStateView(state: model.benchmark) { Pasteboard.copy(model.diagnostics ?? "") }
            } else {
                SectionStateView(state: model.benchmark) { model.startRun() }
                    .accessibilityIdentifier("voice.benchmark.run")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressValue: Double {
        guard case .running(let done, let total) = lab.phase, total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// R4.1b's ranked-context-list counters, which used to be their own tab.
    @ViewBuilder private var counterRows: some View {
        if !counters.hasData {
            Text(SectionCopy.noMeasurements).accessibilityIdentifier("benchmark.empty")
        } else {
            if let corpus = counters.corpusLabel {
                Text(corpus).windowFont(Tokens.Typography.key).foregroundStyle(WindowColor.secondaryInk)
            }
            ForEach(counters.rows) { row in
                HStack {
                    Text(row.arm)
                    Spacer()
                    Text("recall \(row.recallText)").windowFont(Tokens.Typography.duration)
                    Text("false insertions \(row.falseInsertions)").windowFont(Tokens.Typography.duration)
                }
                .accessibilityIdentifier("benchmark.row.\(row.id)")
            }
            if let gain = counters.recallGainText {
                Text(gain).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("benchmark.recallGain")
            }
            if let pass = counters.passLabel {
                Text(pass).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("benchmark.passLabel")
            }
        }
    }
}
