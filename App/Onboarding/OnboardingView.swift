import AppKit
import SwiftUI
import Shared

public struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel
    /// Which permission's "Remove the old entry…" confirmation is up, if any.
    @State private var confirmingRowReset: OnboardingPermission?

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

    /// Scrollable since 1.6.6: the recovery panel now carries three numbered steps at body size, and
    /// the window is a fixed 520×420 — without this the instructions are the first thing clipped,
    /// which is the exact failure being fixed.
    private var permissions: some View {
        ScrollView {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The one phase that can follow a request. It always offers a way forward, so the step can never
    /// dead-end the way "Allow" alone did — and, since 1.6.3, the copy is per-service: a promptable
    /// service is never told to add itself to a pane that has no "+" button, and is always given a
    /// button that re-invokes the real system request.
    ///
    /// Since 1.6.6 the *steps* are the panel, not a footnote. The 1.6.5 report is a user who read the
    /// orange headline ("that switch belongs to an older build"), acted on the switch it named, and
    /// never reached the "select VoicePlus, press –, press +" instructions, which rendered as grey
    /// caption text below it. Same words, wrong weight. The headline now states the situation, the
    /// numbered steps state the cure at body size, and "Remove the old entry" does the fiddliest of
    /// them for the user.
    @ViewBuilder private func needsSettings(_ p: OnboardingPermission, attempts: Int) -> some View {
        let copy = p.recoveryCopy(status: model.machine.statuses[p] ?? .notDetermined, attempts: attempts,
                                  evidence: model.recoveryEvidence(for: p))
        VStack(alignment: .leading, spacing: 10) {
            Label(copy.headline, systemImage: attempts == 0 ? "arrow.up.forward.app" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if !copy.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(copy.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(step).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let detail = copy.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = copy.restartNote {
                Label(note, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = model.rowResetOutcome { rowResetResult(outcome, for: p) }
            if copy.showsResetCommand || copy.showsDequarantineCommand {
                HStack(spacing: 8) {
                    if copy.showsResetCommand {
                        Button("Copy reset command") { model.copyResetCommand(for: p) }
                    }
                    if copy.showsDequarantineCommand {
                        Button("Copy the xattr command") { model.copyDequarantineCommand() }
                    }
                    // The identity the panel rests on: bundle id, cdhash, and the requirement TCC
                    // actually evaluates. On screen so the diagnosis is checkable rather than
                    // something the app just asserts.
                    Text(PermissionDiagnostics.summary()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
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
                    // Re-check keeps Return only while it can still plausibly succeed. Once a
                    // re-check has come back off, the answer is a stored-requirement mismatch that
                    // re-asking cannot change, and a default-action button on it is a third promise
                    // the app cannot keep (after the empty dot and the unchanged status).
                    Button("Re-check") { model.send(.verify(p)) }
                        .keyboardShortcut(attempts == 0 ? .defaultAction : nil)
                    // Step 2 done for the user: with the entry gone there is no row to find and no
                    // "–" to press, so all that is left is "+" and the switch.
                    if copy.showsRowReset {
                        Button("Remove the old entry…") { confirmingRowReset = p }
                    }
                    if let relaunch = copy.relaunchTitle {
                        Button(relaunch) { model.relaunchApp() }
                    }
                }
            }
        }
        .confirmationDialog("Remove VoicePlus from \(p.settingsListName)?",
                            isPresented: Binding(get: { confirmingRowReset == p },
                                                 set: { if !$0 { confirmingRowReset = nil } })) {
            Button("Remove the entry") { model.resetPermissionRow(for: p) }
            Button("Cancel", role: .cancel) { confirmingRowReset = nil }
        } message: {
            Text("This clears VoicePlus' own entry for \(p.title) — the same thing as running “\(PermissionDiagnostics.resetCommand(for: p.core))” in Terminal. It touches nothing else and no other app. Afterwards, press “+” in that list, pick VoicePlus, and switch it on.")
        }
    }

    /// Says what the removal actually did. "No entry" is not a failure — it means the list never had
    /// VoicePlus in it, which is the same next step and rules the stale-entry story out.
    @ViewBuilder private func rowResetResult(_ outcome: PermissionRowResetOutcome,
                                             for p: OnboardingPermission) -> some View {
        switch outcome {
        case .removed:
            Label("Removed. VoicePlus is no longer in \(p.settingsListName) — press “+” there, pick it, and switch it on.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        case .noEntry:
            Label("There was no VoicePlus entry to remove, so nothing was stale. Press “+” in \(p.settingsListName), pick VoicePlus, and switch it on.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .failed(let reason):
            Label("Couldn't remove it: \(reason). Copy the reset command and run it in Terminal instead.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionChecklist: some View {
        HStack(spacing: 14) {
            // Only the permissions this run actually walks. Input Monitoring is absent unless the
            // hotkey backend needs it, so the checklist cannot show a green tick the user never earns.
            ForEach(model.machine.permissionOrder) { p in
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

    /// Names the real models, not just the friendly word. The 1.6.6 picker showed "Best · 1200 MB"
    /// and nothing else — the user could not tell what was being downloaded, and the number was
    /// wrong anyway (two models, 900 MB). Both now come from `ModelCatalog`.
    private var modelChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a free local model.").font(.title.bold())
            Text("It downloads in the background. Until it lands, VoicePlus uses whatever is already on this Mac — the next screen says which.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ModelTier.allCases) { tier in
                Button {
                    model.send(.choose(tier))
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: model.machine.chosenTier == tier ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(tier.title).bold()
                                Text("· \(tier.sizeLabel)").foregroundStyle(.secondary)
                                if tier == .recommended { Text("Recommended").font(.caption).padding(3).background(.quaternary, in: Capsule()) }
                            }
                            Text(tier.modelNameLine).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
        case .notStarted:
            EmptyView()
        case .downloading(let progress):
            // Bytes, percent and a time estimate. A bare percentage was the whole of the old copy,
            // and it left the user unable to answer "has the 1.2 GB even started?".
            ProgressView(value: progress.fraction) {
                Text(model.downloadLine ?? "Downloading… \(progress.percent)%").font(.caption)
            }
        case .installed:
            Label("Ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let why):
            Label("Download failed: \(why). Pick a tier again to retry, or carry on — the next screen says what will be used instead.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The last step. Two presses, and it never claims more than happened.
    private var firstDictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now for real.").font(.title.bold())
            Text("Press Dictate now, say the sentence, then press Stop.")
            Text("“The quick brown fox jumps over the lazy dog.”").font(.title3).italic()
            let gate = model.dictationGate
            Label(gate.banner, systemImage: gate.isWarning ? "exclamationmark.triangle" : "cpu")
                .font(.caption).foregroundStyle(gate.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(dictationButtonTitle) { model.toggleGuidedDictation() }
                    .disabled(!gate.canRun || model.isFinalizing)
                    .keyboardShortcut(.defaultAction)
                if model.isDictating, !model.isFinalizing {
                    Text("Listening…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.dictationPreview.isEmpty {
                Text(model.dictationPreview).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            dictationVerdict
        }
    }

    private var dictationButtonTitle: String {
        if model.isFinalizing { return "Transcribing…" }
        return model.isDictating ? "Stop & transcribe" : "Dictate now"
    }

    /// Exactly one of these, and only ever the one that matches what happened. The 1.6.6 screen drew
    /// the green check whenever `landedText != nil` — and failure was reported by storing `""` in
    /// `landedText`, so the check appeared next to a pill reading "⚠︎ invalidAudioData".
    @ViewBuilder private var dictationVerdict: some View {
        switch model.machine.dictation {
        case nil:
            EmptyView()
        case .landed(_, let app)?:
            Label("It landed in \(app ?? "the app you were in"). You're set.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        case .heard(_, let recognizer)?:
            VStack(alignment: .leading, spacing: 4) {
                Label("Heard you — that's \(recognizer) working.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                Text("Nothing was typed anywhere: pressing a button in this window puts VoicePlus in front, so there was no other field to type into. Hold your dictation key while another app is in front and the text lands there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Copy the text") { model.copyDictationText() }.font(.caption)
            }
        case .noSpeech?, .failed?:
            VStack(alignment: .leading, spacing: 6) {
                Label(model.machine.dictationError ?? "That didn't work.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { model.send(.retryDictation) }.font(.caption)
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
            // "Finish" once VoicePlus has actually heard something — not merely once an event with
            // an empty payload arrived, which is what `landedText != nil` used to mean.
            case .firstDictation: Button(model.machine.heardText == nil ? "Continue" : "Finish") { model.send(.next) }
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
