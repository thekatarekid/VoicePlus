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
    /// The practice field has the caret, so a hold lands there.
    @FocusState private var practiceFocused: Bool
    /// The Word review popover is open.
    @State private var reviewingWord = false
    @State private var customSpelling = ""

    public init(model: OnboardingViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            header
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
                    case .model: modelStep
                    case .firstDictation: firstDictation
                    case .voice: voiceStep
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

    /// The prototype's eyebrow and bar: "Setup · 3 of 7", filled to (step + 1) / count.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OnboardingCopy.eyebrow(step: model.machine.stepNumber, of: OnboardingStateMachine.stepCount))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ProgressView(value: model.machine.progress).progressViewStyle(.linear)
                .accessibilityLabel("Setup progress")
                .accessibilityValue(OnboardingCopy.eyebrow(step: model.machine.stepNumber, of: OnboardingStateMachine.stepCount))
        }
    }

    /// This step's copy with the configured key named.
    private func copy(_ step: OnboardingStateMachine.Step) -> OnboardingCopy.StepCopy {
        OnboardingCopy.copy(for: step, key: model.keyLabel)
    }

    /// One still cassette (design §8.9: "Still welcoming cassette"). Never animated here.
    private func cameo(_ key: SpoolStateKey = .ready) -> some View {
        SpoolView(key: key, stateStartedAt: .distantPast, style: .cameo)
            .frame(width: 76, height: 66)
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
        let copy = copy(.welcome)
        return VStack(alignment: .leading, spacing: 12) {
            cameo()
            Text(copy.heading).font(.largeTitle.bold())
            Text(copy.body)
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
        let copy = askCopy(for: p)
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.heading).font(.title.bold())
            // Explained just before the real macOS request (design §8.7).
            Text(copy.body).font(.callout)
            switch model.machine.permissionPhase {
            case .explain:
                Button(copy.action) { model.send(.allow(p)) }.keyboardShortcut(.defaultAction)
            case .requesting:
                ProgressView("Asking macOS…")
            case .needsSystemSettings(let attempts):
                needsSettings(p, attempts: attempts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Microphone and Typing access speak in the design's words; Input Monitoring (only on the
    /// event-tap escape hatch, which the design has no screen for) keeps its own.
    private func askCopy(for p: OnboardingPermission) -> OnboardingCopy.StepCopy {
        switch p {
        case .microphone: return copy(.microphone)
        case .accessibility: return copy(.accessibility)
        case .inputMonitoring: return .init(heading: p.title, body: p.why, action: "Allow \(p.title)")
        }
    }

    /// Step 3 of 7 — Typing access: whatever permission walk is left once the microphone is settled. On a default
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
            // S11: the tool's own error text is a technical cause — behind a disclosure, never the sentence.
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't remove it. Copy the reset command and run it in Terminal instead.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if !reason.isEmpty {
                    DisclosureGroup("Details") {
                        Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
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

    /// Step 2 of 7 — the microphone permission ask and the real level meter, merged onto one screen
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
                    micRecoveryHeadline(.noAudio, systemImage: "waveform.slash")
                    Text("Capture started but not one audio block arrived. That is usually a microphone grant macOS has stopped honouring for this build, not the volume. Re-grant VoicePlus in Privacy & Security › Microphone, or pick a different input in Sound.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    micRecoveryButtons
                }
            case .tooQuiet:
                VStack(alignment: .leading, spacing: 6) {
                    micRecoveryHeadline(.tooQuiet, systemImage: "speaker.slash")
                    Text("Audio is arriving, but it's very quiet. Check the input level for the right mic in System Settings › Sound.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    micRecoveryButtons
                }
            case .good:
                Label("Sounds good.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .clipping:
                VStack(alignment: .leading, spacing: 6) {
                    micRecoveryHeadline(.clipping, systemImage: "waveform.badge.exclamationmark")
                    Text("Too loud — it's clipping. Move the mic a little further away.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .unavailable:
                let verdict = model.machine.micVerdict
                VStack(alignment: .leading, spacing: 6) {
                    micRecoveryHeadline(verdict, systemImage: "exclamationmark.triangle.fill")
                    micRecoveryButtons
                    // S11: the capture error is a technical cause — behind a disclosure, never the headline.
                    if let detail = OnboardingRecovery.detail(for: verdict) {
                        DisclosureGroup("Details") {
                            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
            case .permissionRequired:
                let p01 = RecoveryCatalog.entry(.P01)
                VStack(alignment: .leading, spacing: 6) {
                    micRecoveryHeadline(.permissionRequired, systemImage: "mic.slash.fill")
                    Text("VoicePlus has no permission to open the microphone, so there is nothing to measure here — and dictation cannot work until it does. Allow VoicePlus in Privacy & Security › Microphone, then press Re-check.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(p01.action) { model.openSettings(for: .microphone) }
                        Button("Re-check") { model.send(.verify(.microphone)) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// S11 — a microphone-check verdict's catalogue headline and consequence (A05, A08, A03, P01).
    @ViewBuilder private func micRecoveryHeadline(_ verdict: OnboardingStateMachine.MicVerdict,
                                                  systemImage: String) -> some View {
        if let entry = OnboardingRecovery.entry(for: verdict)?.rendered(hotkey: model.keyLabel) {
            Label(entry.headline, systemImage: systemImage).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.consequence).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micRecoveryButtons: some View {
        HStack {
            Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
            Button("Open Microphone privacy") { model.openSettings(for: .microphone) }
            // S11: re-running the check is A05's own action, "Test microphone" — not a generic retry.
            Button(RecoveryCatalog.entry(.A05).action) { model.send(.verify(.microphone)) }
        }
        .font(.caption)
    }

    // MARK: Model — "Bring speech recognition on device." (design §8.6 / §8.7)

    /// Real byte progress → Verifying → Loading → Ready, and "Ready" only once the model is verified
    /// and loaded. Continue is never held shut by it (§11.1): the install keeps running whatever
    /// step is showing.
    private var modelStep: some View {
        let copy = copy(.model)
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.heading).font(.title.bold())
            Text(copy.body)
            Text(model.stackNameLine).font(.callout.weight(.semibold))
            modelPhaseView(action: copy.action)
        }
    }

    @ViewBuilder private func modelPhaseView(action: String) -> some View {
        switch model.machine.modelPhase {
        case .notStarted:
            Button(action) { model.send(.installModels) }.keyboardShortcut(.defaultAction)
        case .starting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(OnboardingCopy.starting) }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                Text(model.downloadLine ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minHeight: 16, alignment: .topLeading)
                Button(OnboardingCopy.cancelDownload) { model.send(.cancelDownload) }.font(.caption)
            }
        case .verifying:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(OnboardingCopy.verifying) }
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(OnboardingCopy.loading) }
        case .ready(let name):
            Label(OnboardingCopy.ready(name), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloadFailed(let why):
            recovery(.M02, detail: why) { model.send(.installModels) }
            // "interrupted → retry / local model selection": keep going on what is on this Mac.
            if case .fallback(let name, _) = model.machine.readiness {
                Button(OnboardingCopy.continueWith(name)) { model.send(.next) }
            }
        case .loadFailed(let why):
            recovery(.M07, detail: why) { model.send(.retryModelLoad) }
        }
    }

    /// A recovery-catalogue entry (design §10): headline, consequence, one action, and the technical
    /// cause behind a disclosure, never in the headline.
    @ViewBuilder private func recovery(_ id: RecoveryID, detail: String? = nil,
                                       action: @escaping () -> Void) -> some View {
        let entry = RecoveryCatalog.entry(id).rendered(hotkey: model.keyLabel)
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.headline, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.consequence).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(entry.action, action: action)
            if let detail, !detail.isEmpty {
                DisclosureGroup("Details") {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    // MARK: Try dictation — "Try your first sentence." (design §8.7, I1)

    /// The fn prompt and the key test first (I1), then a real hold into the practice field: live
    /// words above Spool's tape with counterclockwise reels → release → final preview → insertion,
    /// and one uncertain word to correct. The button test stays behind a disclosure for a key that
    /// cannot be held.
    private var firstDictation: some View {
        let copy = copy(.firstDictation)
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.heading).font(.title.bold())
            keyCheckView
            if case .ready = model.machine.keyCheck {
                practiceView(copy)
            }
            let gate = model.dictationGate
            Label(gate.banner, systemImage: gate.isWarning ? "exclamationmark.triangle" : "cpu")
                .font(.caption).foregroundStyle(gate.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if model.machine.modelPhase == .loading {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(OnboardingCopy.loading) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            dictationVerdict
            DisclosureGroup(OnboardingCopy.buttonFallback) { buttonTest(gate: gate) }
                .font(.callout)
        }
    }

    /// I1: the system-action prompt before the key test; Right ⌥ after three silent presses.
    @ViewBuilder private var keyCheckView: some View {
        let key = model.keyLabel
        switch model.machine.keyCheck {
        case .unknown:
            EmptyView()
        case .conflict(let conflict):
            VStack(alignment: .leading, spacing: 6) {
                Label(conflict.headline, systemImage: "globe").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(conflict.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(FnKeyConflict.actionTitle) { model.send(.fixFnConflict) }
                        .buttonStyle(.borderedProminent)
                    Button(OnboardingCopy.continueAnyway) { model.send(.dismissFnConflict) }
                }
            }
        case .testing(let attempts, let prompting):
            VStack(alignment: .leading, spacing: 6) {
                if prompting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(OnboardingCopy.pressNow(key))
                        Button(OnboardingCopy.pressedIt) { model.pressedKeyWithoutEvent() }
                    }
                } else {
                    Text(attempts == 0 ? OnboardingCopy.pressKeyPrompt(key)
                                       : OnboardingCopy.nothingArrived(key, attempt: attempts))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(OnboardingCopy.checkKey) { model.send(.checkKey) }.keyboardShortcut(.defaultAction)
                }
            }
        case .offerFallback(let fallback):
            let fallbackLabel = HotkeyBinding(kind: fallback).label
            VStack(alignment: .leading, spacing: 6) {
                Label(OnboardingCopy.fallbackOffer(from: key, to: fallbackLabel), systemImage: "keyboard")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(OnboardingCopy.useFallback(fallbackLabel)) { model.send(.useFallbackKey) }
                        .buttonStyle(.borderedProminent)
                    Button(OnboardingCopy.tryAgain(key)) { model.send(.retryFnKey) }
                }
            }
        case .ready(let kind):
            if kind == .fn {
                Label(OnboardingCopy.keyWorks(key), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func practiceView(_ copy: OnboardingCopy.StepCopy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.body).fixedSize(horizontal: false, vertical: true)
            practiceStage
            Text(OnboardingCopy.practiceFieldLabel).font(.caption.weight(.semibold))
            TextEditor(text: $model.practiceText)
                .font(.body)
                .focused($practiceFocused)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel(OnboardingCopy.practiceFieldLabel)
            HStack {
                Text(OnboardingCopy.practiceFieldNote).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // "Try dictation" puts the caret in the practice field, so the hold lands there.
                Button(copy.action) { practiceFocused = true }
            }
            if let review = model.wordReview { wordReviewView(review) }
        }
    }

    /// Spool, still until the real test runs; then the pill scene with the live words above its
    /// tape (counterclockwise reels while listening, clockwise on insertion).
    @ViewBuilder private var practiceStage: some View {
        let practice = model.practice
        if practice.phase == .waiting {
            HStack(spacing: 12) {
                cameo()
                Text(PillState.readyHint(key: model.keyLabel, latchEnabled: false))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            SpoolView(key: Self.spoolKey(for: practice), stateStartedAt: practice.phaseStartedAt,
                      level: Double(practice.level), style: .pill)
                .frame(height: 124)
                .background(Color(nsColor: Tokens.Pill.background), in: RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topLeading) {
                    stageWords(practice)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(nsColor: Tokens.Pill.ink))
                        .lineLimit(2)
                        .padding(.leading, 18).padding(.top, 18).padding(.trailing, 150)
                }
                .accessibilityElement(children: .combine)
        }
    }

    /// The words the stage shows for this phase; uncertain words dotted in red in the final preview.
    private func stageWords(_ practice: PracticeSession) -> Text {
        switch practice.phase {
        case .listening, .finishing:
            return Text(practice.liveText.isEmpty ? "Listening…" : practice.liveText)
        case .preview, .notInserted:
            return practice.finalSpans.reduce(Text("")) { text, span in
                let word = Text(span.text + " ")
                return text + (span.isLowConfidence
                    ? word.underline(pattern: .dot, color: Color(nsColor: Tokens.Pill.uncertainty))
                    : word)
            }
        case .inserted:
            return Text(practice.insertedText ?? practice.finalText)
        case .cancelled, .noSpeech, .failed, .waiting:
            return Text("")
        }
    }

    static func spoolKey(for practice: PracticeSession) -> SpoolStateKey {
        switch practice.phase {
        case .waiting: return .ready
        case .listening: return .listening
        case .finishing: return .finishing
        case .preview: return practice.finalSpans.contains(where: \.isLowConfidence) ? .uncertain : .preview
        case .inserted: return .inserted
        case .notInserted: return .held
        case .cancelled, .noSpeech: return .cancelled
        case .failed: return .error
        }
    }

    /// The prototype's Word review, anchored to the dotted word.
    private func wordReviewView(_ review: UncertainWordReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(UncertainWordReview.eyebrow).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if review.source == .example {
                    Text(OnboardingCopy.example).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            reviewSentence(review)
            if review.isResolved {
                Label(OnboardingCopy.reviewed, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            if model.correctionRefused {
                Text(OnboardingCopy.correctionRefused).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func reviewSentence(_ review: UncertainWordReview) -> some View {
        if !review.isResolved, let range = review.currentRange {
            HStack(spacing: 0) {
                Text(review.sentence[..<range.lowerBound])
                Button { reviewingWord = true } label: {
                    Text(review.sentence[range])
                        .underline(pattern: .dot, color: Color(nsColor: Tokens.Colors.uncertainty))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(review.reviewLabel)
                .popover(isPresented: $reviewingWord, arrowEdge: .bottom) { reviewPopover(review) }
                Text(review.sentence[range.upperBound...])
            }
        } else {
            Text(review.sentence)
        }
    }

    private func reviewPopover(_ review: UncertainWordReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UncertainWordReview.eyebrow).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(review.title).font(.headline)
            Text(review.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(review.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { choose(suggestion) }.buttonStyle(.borderedProminent)
                }
                Button(review.keepTitle) { choose(review.word) }
            }
            Text(UncertainWordReview.customLabel).font(.caption).foregroundStyle(.secondary)
            TextField(UncertainWordReview.customPlaceholder, text: $customSpelling)
            HStack {
                Button(UncertainWordReview.applyTitle) { choose(customSpelling) }
                    .disabled(customSpelling.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(UncertainWordReview.cancelTitle) { reviewingWord = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func choose(_ spelling: String) {
        model.correctUncertainWord(spelling)
        customSpelling = ""
        reviewingWord = false
    }

    /// The click-to-stop test (design §8.8: a button "cannot imply a held key"). Two presses, and it
    /// never claims more than happened.
    private func buttonTest(gate: GuidedDictationGate.Decision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Press Dictate now, say the sentence, then press Stop.")
            Text("“The quick brown fox jumps over the lazy dog.”").italic()
            HStack {
                Button(dictationButtonTitle) { model.toggleGuidedDictation() }
                    .disabled(!gate.canRun || model.isFinalizing)
                if model.isDictating, !model.isFinalizing {
                    Text("Listening…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.dictationPreview.isEmpty {
                Text(model.dictationPreview).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 6)
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
                if model.practice.phase == .notInserted {
                    Label(OnboardingCopy.notInserted, systemImage: "tray.full")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Heard you — that's \(recognizer) working.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                    Text("Nothing was typed anywhere: pressing a button in this window puts VoicePlus in front, so there was no other field to type into. Hold your dictation key while another app is in front and the text lands there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Copy the text") { model.copyDictationText() }.font(.caption)
            }
        case .noSpeech?, .failed?:
            // S11: the attempt's catalogue entry — headline, consequence and its own one action.
            if let entry = OnboardingRecovery.entry(for: model.machine.dictation)?.rendered(hotkey: model.keyLabel) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(entry.headline, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Text(entry.consequence).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    recoveryStepButton(entry)
                }
            }
        }
    }

    /// The entry's own action as the step can carry it out (`OnboardingRecovery.step`); nothing when
    /// this window cannot — never a generic "Try again" standing in for another action.
    @ViewBuilder private func recoveryStepButton(_ entry: RecoveryEntry) -> some View {
        switch OnboardingRecovery.step(for: entry.id) {
        case .retryDictation:
            Button(entry.action) { model.send(.retryDictation) }.font(.caption)
        case .openSettings(let permission):
            Button(entry.action) { model.openSettings(for: permission) }.font(.caption)
        case .openSoundSettings:
            Button(entry.action) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                .font(.caption)
        case .retryModelLoad:
            Button(entry.action) { model.send(.retryModelLoad) }.font(.caption)
        case .installModels:
            Button(entry.action) { model.send(.installModels) }.font(.caption)
        case .none:
            EmptyView()
        }
    }

    // MARK: Voice — the owner's step (V4.48)

    /// Prompted enrollment through the Voice section's own view; skippable, with H2's passive
    /// fallback stated before the choice.
    private var voiceStep: some View {
        let copy = copy(.voice)
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.heading).font(.title.bold())
            Text(copy.body)
            switch model.machine.voice {
            case .enrolled(let filtering):
                Label(OnboardingCopy.voiceEnrolled, systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
                if filtering {
                    Text(OnboardingCopy.voiceEnrolledDetail).font(.caption).foregroundStyle(.secondary)
                } else {
                    // Saved, but this Mac's embedder cannot tell voices apart (X03).
                    Text(RecoveryCatalog.entry(.X03).consequence).font(.caption).foregroundStyle(.secondary)
                }
            case .enrolling:
                if let enrollment = model.enrollment {
                    SpeakerEnrollmentView(model: enrollment)
                    Button("Stop") { model.send(.cancelVoiceEnrollment) }
                }
            case .unavailable:
                recovery(.X03) { model.send(.beginVoiceEnrollment) }
            case .notEnrolled:
                Text(OnboardingCopy.voiceInstruction).fixedSize(horizontal: false, vertical: true)
                Button(copy.action) { model.send(.beginVoiceEnrollment) }.keyboardShortcut(.defaultAction)
            }
            if !model.machine.voice.isEnrolled {
                Text(OnboardingCopy.voicePassiveFallback).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Ready — "You’re ready." only when it is true (design §8.7)

    private var done: some View {
        let copy = copy(.done)
        return VStack(alignment: .leading, spacing: 12) {
            switch model.machine.readyVerdict {
            case .ready, .copyOnly:
                cameo()
                Text(copy.heading).font(.largeTitle.bold())
                Text(copy.body)
                if model.machine.readyVerdict == .copyOnly {
                    Text(OnboardingCopy.copyOnlyLabel).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    recovery(.P02) { model.openSettings(for: .accessibility) }
                }
            case .notReady(let blockers):
                cameo(.blocked)
                Text(RecoveryCatalog.entry(blockers[0]).rendered(hotkey: model.keyLabel).headline)
                    .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                ForEach(blockers, id: \.self) { id in
                    recovery(id) { fix(id) }
                }
            }
            if model.machine.skippedSteps.contains(.voice) {
                Text(OnboardingCopy.voicePassiveFallback).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = model.machine.modelInstallStatusLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if let outcome = model.contactsOutcome, case .imported(let n) = outcome {
                Text("Added \(n) names from Contacts to your dictionary.").foregroundStyle(.secondary)
            }
            OnboardingWhatToExpectCard { open(OnboardingReady.expectDictionarySection) }   // I1
            laterSteps
        }
    }

    /// Design §8.7: "Meeting/system-audio and Calendar are optional later steps." Offered, never
    /// asked for here; each opens Meetings, where its permission is requested when first needed.
    private var laterSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OnboardingReady.laterHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(OnboardingReady.laterItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(item.action) { open(item.section) }.font(.caption)
                }
            }
        }
        .padding(.top, 8)
    }

    /// The one action that fixes each Ready blocker (`OnboardingReady.fix`).
    private func fix(_ id: RecoveryID) {
        switch OnboardingReady.fix(for: id) {
        case .systemSettings(let p): model.openSettings(for: p)
        case .installModels: model.send(.installModels)
        case .retryModelLoad: model.send(.retryModelLoad)
        case .models: SettingsWindowController.show(dependencies: model.deps, tab: .models)
        case .section(let section): open(section)
        }
    }

    private func open(_ section: MainWindowSection) {
        MainWindowController.show(dependencies: model.deps, section: section)
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

    /// Back, Set up later and the step's forward action (design §8.7). Nothing here is ever held
    /// shut by an install or a denial; Ready has no Back (it has already finished).
    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button(OnboardingCopy.back) { model.send(.back) }
            }
            if model.step != .done {
                Button(OnboardingCopy.setUpLater) { model.setUpLater() }
            }
            Spacer()
            // DESIGN §11.1 — Welcome has no "Skip everything": the next two steps are what make the
            // app work. A permission screen has its own per-permission advance below. The Model
            // step's Continue is never blocked, and the Voice step has its own Skip.
            if [.microphone, .accessibility, .firstDictation].contains(model.step), model.machine.currentPermission == nil {
                Button("Skip") { model.send(.skip) }
            }
            switch model.step {
            case .welcome:
                Button(copy(.welcome).action) { model.send(.next) }.keyboardShortcut(.defaultAction)
            case .microphone, .accessibility:
                if model.machine.currentPermission != nil {
                    Button(model.machine.permissionPhase == .explain ? "Skip this one" : "Continue anyway") {
                        model.send(.next)
                    }
                } else {
                    Button(OnboardingCopy.continueTitle) { model.send(.next) }.keyboardShortcut(.defaultAction)
                }
            case .model:
                Button(OnboardingCopy.continueTitle) { model.send(.next) }
                    .keyboardShortcut(model.machine.modelPhase == .notStarted ? nil : .defaultAction)
            case .firstDictation:
                Button(OnboardingCopy.continueTitle) { model.send(.next) }
            case .voice:
                if model.machine.voice.isEnrolled {
                    Button(OnboardingCopy.continueTitle) { model.send(.next) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(OnboardingCopy.voiceSkip) { model.send(.skip) }
                }
            case .done:
                Button(copy(.done).action) { model.openVoicePlus() }.keyboardShortcut(.defaultAction)
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
