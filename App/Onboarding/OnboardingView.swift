import AppKit
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
                Text(p.why).font(.callout)
                switch model.machine.permissionPhase {
                case .explain:
                    Button("Allow \(p.title)") { model.send(.allow(p)) }.keyboardShortcut(.defaultAction)
                case .requesting:
                    ProgressView("Asking macOS…")
                case .needsSystemSettings(let attempts):
                    needsSettings(p, attempts: attempts)
                }
            }
            permissionChecklist
        }
    }

    /// The one phase that can follow a request. It always offers a way forward, so the step can never
    /// dead-end the way "Allow" alone did — and, since 1.6.3, the copy is per-service: a promptable
    /// service is never told to add itself to a pane that has no "+" button, and is always given a
    /// button that re-invokes the real system request.
    @ViewBuilder private func needsSettings(_ p: OnboardingPermission, attempts: Int) -> some View {
        let copy = p.recoveryCopy(status: model.machine.statuses[p] ?? .notDetermined, attempts: attempts)
        VStack(alignment: .leading, spacing: 10) {
            Label(copy.headline, systemImage: attempts == 0 ? "arrow.up.forward.app" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if let detail = copy.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if copy.showsResetCommand {
                HStack(spacing: 8) {
                    Button("Copy reset command") { model.copyResetCommand(for: p) }
                    Text(PermissionDiagnostics.summary()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Text(p.consequenceIfSkipped).font(.caption).foregroundStyle(.secondary)
            HStack {
                // The escape hatch for anyone already stuck: `.allow` re-issues the real request from
                // this phase too, which is the only thing that can register the app with TCC.
                if let retry = copy.retryTitle {
                    Button(retry) { model.send(.allow(p)) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button("Open System Settings") { model.openSettings(for: p) }
                    Button("Re-check") { model.send(.verify(p)) }
                } else {
                    Button("Open System Settings") { model.openSettings(for: p) }.buttonStyle(.borderedProminent)
                    Button("Re-check") { model.send(.verify(p)) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var permissionChecklist: some View {
        HStack(spacing: 14) {
            ForEach(OnboardingPermission.allCases) { p in
                let status = model.machine.statuses[p] ?? .notDetermined
                Label(p.title, systemImage: Self.checklistSymbol(status))
                    .foregroundStyle(status == .granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    static func checklistSymbol(_ status: OnboardingPermissionStatus) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle"
        case .awaitingUserAction: return "ellipsis.circle"
        case .notDetermined: return "circle"
        }
    }

    private var micCheck: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say something.").font(.title.bold())
            Text("Try: \"Testing, one two three.\" The bar should move as you talk.")
            MicLevelMeter(level: model.micLevel)
            switch model.machine.micVerdict {
            case .waiting:
                Text("Listening…").foregroundStyle(.secondary)
            case .noAudio:
                VStack(alignment: .leading, spacing: 6) {
                    Label("No sound is reaching VoicePlus.", systemImage: "waveform.slash").foregroundStyle(.orange)
                    Text("Capture started but not one audio block arrived. That is usually a microphone grant macOS has stopped honouring for this build, not the volume. Re-grant VoicePlus in Privacy & Security › Microphone, or pick a different input in Sound.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    micRecoveryButtons
                }
            case .tooQuiet:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Audio is arriving, but it's very quiet.", systemImage: "speaker.slash").foregroundStyle(.orange)
                    Text("Check the input level for the right mic in System Settings › Sound.")
                        .font(.caption).foregroundStyle(.secondary)
                    micRecoveryButtons
                }
            case .good:
                Label("Sounds good.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .clipping:
                Label("Too loud — it's clipping. Move the mic a little further away.", systemImage: "waveform.badge.exclamationmark").foregroundStyle(.orange)
            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't start the microphone.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    micRecoveryButtons
                }
            }
            if !model.deps.micLevel.isRealCapture {
                Label("Simulated meter — no real capture is running in this build.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var micRecoveryButtons: some View {
        HStack {
            Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
            Button("Open Microphone privacy") { model.openSettings(for: .microphone) }
            Button("Try again") { model.send(.verify(.microphone)) }
        }
        .font(.caption)
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
            // The permissions step has its own per-permission advance below; a global "Skip" there
            // used to jump past every remaining permission, which is why Accessibility was unreachable.
            if model.step != .done && model.step != .permissions { Button("Skip") { model.send(.skip) } }
            switch model.step {
            case .welcome: Button("Get started") { model.send(.next) }.keyboardShortcut(.defaultAction)
            case .permissions:
                Button(model.machine.permissionPhase == .explain ? "Skip this one" : "Continue anyway") {
                    model.send(.next)
                }
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
