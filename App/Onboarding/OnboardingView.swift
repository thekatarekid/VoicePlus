import SwiftUI
import Shared

public struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    public init(model: OnboardingViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.machine.progress).progressViewStyle(.linear)
            Group {
                switch model.step {
                case .welcome: welcome
                case .permissions: permissions
                case .micCheck: micCheck
                case .modelChoice: modelChoice
                case .firstDictation: firstDictation
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .sheet(isPresented: $model.showContactsOffer) { contactsOffer }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold a key. Talk. Let go.").font(.largeTitle.bold())
            Text("VoicePlus types what you say into whatever app you're in — on this Mac, never in the cloud unless you ask. This takes about a minute.")
            Text("Everything here can be skipped and changed later in Settings.").foregroundStyle(.secondary).font(.callout)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.machine.currentPermission {
                Text(p.title).font(.title.bold())
                Text(p.why)
                switch model.machine.permissionPhase {
                case .explain:
                    Button("Allow \(p.title)") { model.send(.allow(p)) }.keyboardShortcut(.defaultAction)
                case .requesting:
                    ProgressView("Waiting for macOS…")
                case .denied:
                    Label("Not granted yet. \(p.consequenceIfSkipped)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Open System Settings") { model.openSettings(for: p) }
                        Button("Verify") { model.send(.verify(p)) }.keyboardShortcut(.defaultAction)
                        Button("Skip this one") { model.send(.next) }
                    }
                }
            }
            permissionChecklist
        }
    }

    private var permissionChecklist: some View {
        HStack(spacing: 14) {
            ForEach(OnboardingPermission.allCases) { p in
                let status = model.machine.statuses[p] ?? .notDetermined
                Label(p.title, systemImage: status == .granted ? "checkmark.circle.fill" : (status == .denied ? "xmark.circle" : "circle"))
                    .foregroundStyle(status == .granted ? .green : .secondary)
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    private var micCheck: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say something.").font(.title.bold())
            Text("Try: \"Testing, one two three.\" The bar should move as you talk.")
            MicLevelMeter(level: model.micLevel)
            switch model.machine.micVerdict {
            case .waiting: Text("Listening…").foregroundStyle(.secondary)
            case .tooQuiet: Label("Very quiet. Is the right mic selected in System Settings › Sound?", systemImage: "speaker.slash").foregroundStyle(.orange)
            case .good: Label("Sounds good.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .clipping: Label("Too loud — it's clipping. Move the mic a little further away.", systemImage: "waveform.badge.exclamationmark").foregroundStyle(.orange)
            }
        }
    }

    private var modelChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a free local model.").font(.title.bold())
            Text("It downloads in the background; the tiny built-in model works right now.").font(.callout).foregroundStyle(.secondary)
            ForEach(ModelTier.allCases) { tier in
                Button {
                    model.send(.choose(tier))
                } label: {
                    HStack {
                        Image(systemName: model.machine.chosenTier == tier ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            HStack {
                                Text(tier.title).bold()
                                Text("· \(tier.sizeMB) MB").foregroundStyle(.secondary)
                                if tier == .recommended { Text("Recommended").font(.caption).padding(3).background(.quaternary, in: Capsule()) }
                            }
                            Text(tier.tradeoff).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            downloadStatus
            Divider()
            HStack {
                Text("Already pay for ChatGPT, Claude, or an API key? That improves rewrites — not transcription.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Connect what you pay for…") { model.deps.openProvidersSettings() }
            }
        }
    }

    @ViewBuilder private var downloadStatus: some View {
        switch model.machine.download {
        case .notStarted: EmptyView()
        case .downloading(let p): ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%").font(.caption) }
        case .installed: Label("Ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let why): Label("Download failed (\(why)). Using the built-in model; retry from Settings.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        }
    }

    private var firstDictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now for real.").font(.title.bold())
            Text("Click into any text field — Notes, Slack, a browser — then press the button (or hold your hotkey) and say:")
            Text("“The quick brown fox jumps over the lazy dog.”").font(.title3).italic()
            Button(model.isDictating ? "Listening…" : "Dictate now") { model.runGuidedDictation() }
                .disabled(model.isDictating)
                .keyboardShortcut(.defaultAction)
            if !model.dictationPreview.isEmpty {
                Text(model.dictationPreview).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if model.machine.landedText != nil {
                Label("It landed. You're set.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("That's it.").font(.largeTitle.bold())
            Text("Hold the key and talk, anywhere. Settings live in the menu bar.")
            if let outcome = model.contactsOutcome, case .imported(let n) = outcome {
                Text("Added \(n) names from Contacts to your dictionary.").foregroundStyle(.secondary)
            }
        }
    }

    private var contactsOffer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add names from Contacts?").font(.title2.bold())
            Text("VoicePlus spells names right when it knows them. Names stay on this Mac and are only used to bias transcription.")
            HStack {
                Spacer()
                Button("Not now") { model.declineContactsImport() }
                Button("Add names") { model.acceptContactsImport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 380)
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done { Button("Back") { model.send(.back) } }
            Spacer()
            if model.step != .done { Button("Skip") { model.send(.skip) } }
            switch model.step {
            case .welcome: Button("Get started") { model.send(.next) }.keyboardShortcut(.defaultAction)
            case .permissions: EmptyView()
            case .micCheck: Button("Continue") { model.send(.next) }.keyboardShortcut(.defaultAction)
            case .modelChoice: Button("Continue") { model.send(.next) }
            case .firstDictation: Button(model.machine.landedText == nil ? "Continue" : "Finish") { model.send(.next) }
            case .done: Button("Close") { OnboardingWindowController.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Live quality meter for the mic-check step.
struct MicLevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(level >= 0.98 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
