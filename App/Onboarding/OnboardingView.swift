import AppKit
import Engine
import SwiftUI
import Shared

public struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel
    /// Which permission's "Remove the old entry…" confirmation is up, if any.
    @State private var confirmingRowReset: OnboardingPermission?

    /// Height the current step wants, and the height of the fixed chrome around it. Both are
    /// measured rather than guessed: every step has a different resting height, and Microphone and
    /// Accessibility in particular grow and shrink while they are on screen (a permission's recovery
    /// copy, or the level meter's own states).
    @State private var stepHeight: CGFloat = OnboardingWindowSizing.minimumStepHeight
    @State private var progressHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    public init(model: OnboardingViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.machine.progress).progressViewStyle(.linear)
                .measureHeight { h in
                    if OnboardingWindowSizing.shouldResize(from: progressHeight, to: h) { progressHeight = h }
                }
            // The step scrolls; the action row below never does. Even at a content height the
            // display cannot fit, Back / Skip / Continue keep their own space — the clipped-in-half
            // button row from 1.7.0 is structurally impossible now, not merely unlikely.
            ScrollView {
                Group {
                    switch model.step {
                    case .welcome: welcome
                    case .microphone: microphone
                    case .accessibility: accessibility
                    case .firstDictation: firstDictation
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .measureHeight { h in
                    // Sub-point republishes (and the constant re-layout of the progress text) must
                    // not move the window.
                    if OnboardingWindowSizing.shouldResize(from: stepHeight, to: h) { stepHeight = h }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer.measureHeight { h in
                if OnboardingWindowSizing.shouldResize(from: footerHeight, to: h) { footerHeight = h }
            }
        }
        .padding(24)
        .frame(width: OnboardingWindowSizing.contentWidth, height: windowContentHeight)
        .sheet(isPresented: $model.showContactsOffer) { contactsOffer }
    }

    /// The height the window should adopt: chrome + the step's own fitting height, clamped to the
    /// display it opens on. `NSHostingController`'s `.preferredContentSize` sizing turns this into a
    /// window resize, anchored at the top-left, so a step that grows mid-flight (a download starting)
    /// extends downwards instead of jumping the window around the screen.
    private var windowContentHeight: CGFloat {
        OnboardingWindowSizing.contentHeight(stepHeight: stepHeight,
                                             chromeHeight: progressHeight + footerHeight,
                                             usableHeight: OnboardingWindowSizing.usableFrame().height)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold a key. Talk. Let go.").font(.largeTitle.bold())
            Text("VoicePlus types what you say into whatever app you're in — on this Mac, never in the cloud unless you ask. This takes about a minute.")
            Text("Everything here can be skipped and changed later in Settings.").foregroundStyle(.secondary).font(.callout)
            // DESIGN §11.1 — a single quiet line, never a blocking progress screen. The install
            // started the instant this window opened; Welcome just says so.
            if let line = model.machine.modelInstallStatusLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The permission-ask half of a step: "why", then whichever phase is current. Shared by
    /// `.microphone` (while the mic grant is outstanding) and `.accessibility` (for whatever is left
    /// once the microphone is settled — Accessibility itself, and, on the `hotkeyForceEventTap`
    /// escape hatch, Input Monitoring first).
    ///
    /// No longer carries its own `ScrollView`: since 1.7.1 the whole step area scrolls and the
    /// window sizes itself to the step, so a nested scroller would only report a collapsed height
    /// and defeat that.
    @ViewBuilder private func permissionAsk(for p: OnboardingPermission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Step 3 of 5 — whatever permission walk is left once the microphone is settled. On a default
    /// install that is Accessibility alone; on the escape hatch it is Input Monitoring, then
    /// Accessibility, on the same screen (DESIGN §11 — "today's flow… `permissions` splits into
    /// Microphone and Accessibility so each denial has its own honest screen").
    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.machine.currentPermission {
                permissionAsk(for: p)
            }
            permissionChecklist
            if let line = model.machine.modelInstallStatusLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Step 2 of 5 — the microphone permission ask and the real level meter, merged onto one screen
    /// per DESIGN §11.2: the ask shows while the grant is outstanding, the meter (or its blocked
    /// state) shows once it isn't.
    private var microphone: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.machine.currentPermission, p == .microphone {
                permissionAsk(for: p)
            } else {
                microphoneMeter
            }
            if let line = model.machine.modelInstallStatusLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var microphoneMeter: some View {
        VStack(alignment: .leading, spacing: 12) {
            let blocked = model.machine.micVerdict == .permissionRequired
            Text(blocked ? "The microphone is blocked." : "Say something.").font(.title.bold())
            if !blocked {
                // The meter is only ever drawn when a live capture stack is feeding it, so a moving
                // bar is evidence and not decoration.
                Text("Try: \"Testing, one two three.\" The bar should move as you talk.")
                MicLevelMeter(level: model.micLevel)
            }
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
            case .permissionRequired:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Microphone access is needed.", systemImage: "mic.slash.fill").foregroundStyle(.orange)
                    Text("VoicePlus has no permission to open the microphone, so there is nothing to measure here — and dictation cannot work until it does. Allow VoicePlus in Privacy & Security › Microphone, then press Re-check.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Microphone privacy") { model.openSettings(for: .microphone) }
                        Button("Re-check") { model.send(.verify(.microphone)) }
                    }
                    .font(.caption)
                }
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

    /// R6.2 — there is no model-install *screen* any more (DESIGN §11.1: "never a blocking progress
    /// screen"). The one stack starts downloading the moment onboarding opens and keeps going in the
    /// background; every other step's `modelInstallStatusLine` says the truth about it in one line,
    /// and Settings › Models is where anyone who wants the bar, the estimate or a Retry button goes
    /// looking for it.

    /// Step 4 of 5 — "Try the key". Two presses, and it never claims more than happened. When the
    /// model is still installing, `GuidedDictationGate` already says so plainly in `gate.banner`
    /// ("Using X for now — Y is still downloading — N%") rather than pretending nothing is missing.
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

    /// Step 5 of 5. DESIGN §11.5 — "a short list of what is not ready… each with the one action
    /// that fixes it, phrased as a consequence, not a scolding." Close is always enabled regardless
    /// of how much of this list is non-empty.
    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("That's it.").font(.largeTitle.bold())
            Text("Hold the key and talk, anywhere. Settings live in the menu bar.")
            ForEach(Array(stillMissing.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = model.contactsOutcome, case .imported(let n) = outcome {
                Text("Added \(n) names from Contacts to your dictionary.").foregroundStyle(.secondary)
            }
        }
    }

    private var stillMissing: [String] {
        var lines: [String] = []
        if model.machine.statuses[.microphone] != .granted {
            lines.append("Microphone access is off, so nothing can be transcribed yet — turn it on in \(OnboardingPermission.microphone.settingsListName).")
        }
        if model.machine.statuses[.accessibility] != .granted {
            lines.append("Accessibility access is off, so typed text is held for you to paste instead of landing — turn it on in \(OnboardingPermission.accessibility.settingsListName).")
        }
        if let line = model.machine.modelInstallStatusLine { lines.append(line) }
        if model.machine.landedText == nil, model.machine.heardText == nil {
            lines.append("Dictation hasn't landed anything yet — try it any time by holding your key.")
        }
        return lines
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
            // DESIGN §11.1 — Welcome has no "Skip everything": the next two steps are what make the
            // app work. A permission screen has its own per-permission advance below; a global
            // "Skip" there used to jump past every remaining permission, which is why Accessibility
            // was once unreachable. Once the permission side of the screen has nothing left to ask,
            // the global Skip is back (it is what used to skip the separate meter-only step).
            if model.step != .welcome && model.step != .done && model.machine.currentPermission == nil {
                Button("Skip") { model.send(.skip) }
            }
            switch model.step {
            case .welcome: Button("Get started") { model.send(.next) }.keyboardShortcut(.defaultAction)
            case .microphone, .accessibility:
                if model.machine.currentPermission != nil {
                    Button(model.machine.permissionPhase == .explain ? "Skip this one" : "Continue anyway") {
                        model.send(.next)
                    }
                } else {
                    Button("Continue") { model.send(.next) }.keyboardShortcut(.defaultAction)
                }
            // "Finish" once VoicePlus has actually heard something — not merely once an event with
            // an empty payload arrived, which is what `landedText != nil` used to mean.
            case .firstDictation: Button(model.machine.heardText == nil ? "Continue" : "Finish") { model.send(.next) }
            case .done: Button("Close") { OnboardingWindowController.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Reports a subview's laid-out height upwards, so the window can size itself to whichever step is
/// showing instead of to one hard-coded number that fits none of them.
struct OnboardingHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: OnboardingHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(OnboardingHeightKey.self) { onChange($0) }
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
