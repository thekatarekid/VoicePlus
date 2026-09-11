import Lab
import SwiftUI
import Shared

// R7.2 — Voice (`DESIGN.md` §9.4): Microphone, Enrollment, Benchmark. This is where the standalone
// enrollment window and the standalone Lab window went. Enrollment runs *in this pane*; the Lab's
// own `LabPanelView` is hosted here unchanged, because R7.2 moves surfaces, it does not rewrite them.

struct VoiceSectionView: View {
    @ObservedObject var model: VoiceSectionViewModel
    @ObservedObject var audio: AudioInputSettingsViewModel
    @ObservedObject var lab: LabPanelViewModel
    @ObservedObject var counters: BenchmarkViewModel
    /// The refinement picker's view model, built once from the same store the old Voice tab used so
    /// the saved mode is the saved mode.
    private let refinement: VoiceSettingsViewModel

    init(model: VoiceSectionViewModel) {
        self.model = model
        _audio = ObservedObject(wrappedValue: model.audio)
        _lab = ObservedObject(wrappedValue: model.lab)
        _counters = ObservedObject(wrappedValue: model.counters)
        refinement = MainWindowController.refinementViewModel()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MainWindowSection.voice.detailTitle).font(.title2.weight(.semibold))
                    Text(MainWindowSection.voice.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                microphoneGroup
                enrollmentGroup
                benchmarkGroup
                GroupBox("Second pass") { VoiceSettingsTab(model: refinement).padding(4) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.markDevicesEnumerated() }
    }

    // MARK: Microphone

    private var microphoneGroup: some View {
        GroupBox("Microphone") {
            VStack(alignment: .leading, spacing: 8) {
                if let banner = model.microphoneBanner { SectionBannerView(banner: banner) }
                Picker("Microphone", selection: Binding(
                    get: { audio.selection },
                    set: { audio.selection = $0 }
                )) {
                    Text("Automatic").tag(AudioInputSettingsViewModel.automatic)
                    ForEach(audio.devices) { Text(audio.title(for: $0)).tag($0.uid) }
                }
                .disabled(!model.isMicrophonePickerEnabled)
                .accessibilityIdentifier("settings.microphone")
                Text(audio.note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.microphoneNote")
                if !model.microphone.isContent {
                    SectionStateView(state: model.microphone) { model.openMicrophoneSettings() }
                }
            }
            .padding(4)
        }
    }

    // MARK: Enrollment — inline (R7.2)

    private var enrollmentGroup: some View {
        GroupBox("Enrollment") {
            VStack(alignment: .leading, spacing: 8) {
                if let enrolling = model.enrolling {
                    SpeakerEnrollmentView(model: enrolling) { model.cancelEnrollment() }
                        .accessibilityIdentifier("voice.enrollment.running")
                    Button("Stop") { model.cancelEnrollment() }
                } else if model.enrollment.isContent {
                    Label("A voice is enrolled on this Mac", systemImage: "person.crop.circle.badge.checkmark")
                        .accessibilityIdentifier("voice.enrollment")
                    Text("Enrollment is optional. It helps ambient capture tell you apart.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Re-enroll") { model.beginEnrollment() }
                            .accessibilityIdentifier("voice.enrollment.reenroll")
                        Button("Delete", role: .destructive) { model.deleteEnrollment() }
                            .accessibilityIdentifier("voice.enrollment.delete")
                    }
                } else {
                    SectionStateView(state: model.enrollment) { model.beginEnrollment() }
                        .accessibilityIdentifier("voice.enrollment")
                }
            }
            .padding(4)
        }
    }

    // MARK: Benchmark — the whole Lab, plus R4.1b's counters

    private var benchmarkGroup: some View {
        GroupBox("Benchmark") {
            VStack(alignment: .leading, spacing: 8) {
                if model.benchmark.isContent {
                    counterRows
                    LabPanelView(model: lab)
                    // P6.1's personal WER trend, which used to be the Lab window's second tab. It is
                    // a measurement, so §9.4 is its home now.
                    PersonalWERView(tracker: MainWindowController.environment.personalWER)
                    Button(lab.isRunning ? "Running…" : SectionCopy.runBenchmark) { model.startRun() }
                        .disabled(lab.isRunning)
                        .accessibilityIdentifier("voice.benchmark.run")
                } else if model.benchmark.rendering == .loading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.benchmark.headline).font(.body.weight(.medium))
                        if let percent = model.benchmarkProgressText {
                            Text(percent).font(.body.monospacedDigit())
                        }
                        ProgressView(value: progressValue).frame(width: 160)
                        Button("Cancel") { model.cancelRun() }
                        // Partial results as they land (§9.4): the Lab's own panel shows every
                        // report it has finished so far.
                        LabPanelView(model: lab)
                    }
                } else if model.benchmark.rendering == .error {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionStateView(state: model.benchmark) {
                            Pasteboard.copy(model.diagnostics ?? "")
                        }
                    }
                } else {
                    SectionStateView(state: model.benchmark) { model.startRun() }
                        .accessibilityIdentifier("voice.benchmark.run")
                }
            }
            .padding(4)
        }
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
                Text(corpus).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(counters.rows) { row in
                HStack {
                    Text(row.arm)
                    Spacer()
                    Text("recall \(row.recallText)").font(.caption.monospacedDigit())
                    Text("false insertions \(row.falseInsertions)").font(.caption.monospacedDigit())
                }
                .accessibilityIdentifier("benchmark.row.\(row.id)")
            }
            if let gain = counters.recallGainText {
                Text(gain).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("benchmark.recallGain")
            }
            if let pass = counters.passLabel {
                Text(pass).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("benchmark.passLabel")
            }
        }
    }
}
