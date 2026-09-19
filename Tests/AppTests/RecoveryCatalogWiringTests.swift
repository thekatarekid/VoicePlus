import Actions
import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// S11 — catalogue wiring (design_v1 §10): every catalogue id walked through the pill row and the
/// window notice renderers; retry semantics (no universal Retry, unconfirmed never auto-retries);
/// `DeliveryCopy` as catalogue lookups; the menu, presence, onboarding and app-level producers.
@Suite("S11 — every error surface resolves through the recovery catalogue")
struct RecoveryCatalogWiringTests {
    static let key = "fn / 🌐"
    static let words = "can we meet with Mira on Friday"

    static func context(_ text: String = "", destination: String? = "Mail") -> PillTurnContext {
        PillTurnContext(keyLabel: key, destination: destination, now: Date(timeIntervalSince1970: 1_000), liveText: text)
    }

    /// Design §10: no raw enum token, camelCase identifier, scratch file or path in anything drawn.
    static let leak = try! Regex(
        #"[A-Za-z]+Error|\b[a-z]+[A-Z][A-Za-z]*\b|\.bin\b|\.partial\b|\.part\b|/[A-Za-z0-9_.-]+"#)

    /// A button that re-runs failed work.
    static let retryWord = try! Regex(#"(?i)\b(retry|again)\b"#)

    static func isRetryLabel(_ label: String) -> Bool { label.firstMatch(of: retryWord) != nil }

    // MARK: - The table: every id through the pill row

    @Test("every catalogue id renders as a pill row with its own headline, consequence, pose and action",
          arguments: RecoveryCatalog.entries)
    func pillRow(_ entry: RecoveryEntry) {
        let rendered = entry.rendered(hotkey: Self.key)
        let state = PillState.recovery(entry)
        #expect(PillNotice.entry(forMessage: state.caseName == "error" ? entry.headline : "")?.id == entry.id,
                "\(entry.id.rawValue): the state names its entry again")

        for text in ["", Self.words] {
            let row = PillContent.make(state, context: Self.context(text))
            let hasWords = !text.isEmpty
            let tag = "\(entry.id.rawValue) words=\(hasWords)"
            #expect(row.designKey == "error", "\(tag)")
            #expect(row.trailing == .destination("Mail"), "\(tag)")
            // Nothing drawn leaks a raw token; nothing names "Right Control" (owner decision).
            for line in [row.status, row.helper] + row.buttons.map(\.label) {
                #expect(line.firstMatch(of: Self.leak) == nil, "\(tag): \(line)")
                #expect(!line.contains("Right Control"), "\(tag): \(line)")
            }
            #expect(row.accessibilityLabel.contains(rendered.headline), "\(tag)")

            if entry.treatment == .quietReturn {
                // A06 / A07 / K03: headline and consequence, no ⚠, no buttons, and it fades.
                #expect(row.status == rendered.headline, "\(tag)")
                #expect(row.helper == rendered.consequence, "\(tag)")
                #expect(row.buttons.isEmpty && !row.notice, "\(tag)")
                #expect(row.spoolKey == "cancelled", "\(tag)")
                #expect(RecoveryCatalog.fadeWindow.contains(PillDwell.minimum(for: state)), "\(tag)")
                continue
            }
            #expect(PillDwell.staysUntilAction(state), "\(tag): an error notice stays until the user acts")

            if entry.id == .T01, hasWords {
                // The design's E0 row, verbatim from the fixture deck.
                #expect(row.status == PillDeck.errorStatus && row.helper == PillDeck.errorHelper, "\(tag)")
                #expect(row.buttons == PillDeck.errorButtons && row.words == .final(text) && row.notice, "\(tag)")
                continue
            }
            #expect(row.status == PillDeck.warnPrefix + rendered.headline, "\(tag)")
            #expect(row.helper == rendered.consequence, "\(tag)")
            #expect(row.spoolKey == entry.poseKey, "\(tag): the entry's Spool treatment")
            #expect(row.tone == .warn, "\(tag)")
            #expect(row.words == (hasWords ? .final(text) : .none), "\(tag): kept words stay on the row")
            #expect(row.notice == (entry.dismissal == .untilAction), "\(tag)")
            #expect(row.buttons.filter(\.primary).count <= 1, "\(tag): one primary action")
            #expect(row.buttons.count <= 3, "\(tag)")

            // The entry's one action, when the pill can carry it out.
            let kind = entry.actionKind
            let offered = row.buttons.first { $0.label == rendered.action }
            if let pill = kind.pillAction, !kind.needsRecoveryMaterial || hasWords {
                #expect(offered?.action == pill, "\(tag): the entry's own action")
                #expect(offered?.primary == true, "\(tag)")
            } else {
                #expect(offered == nil || offered?.action == .copy, "\(tag): no action the pill cannot carry out")
            }
            // A "recover" action is present only when recovery material exists (design §10).
            if !hasWords {
                let material = row.buttons.filter { [.review, .copy, .useAvailable, .meeting].contains($0.action) }
                #expect(material.isEmpty, "\(tag): \(material.map(\.label))")
            } else {
                #expect(row.buttons.contains { $0.action == .copy }, "\(tag): kept words can always be copied")
            }
            // Sticky notices always have a way out; conditions that clear themselves have none.
            let dismiss = row.buttons.contains { $0.action == .dismiss }
            #expect(dismiss == (entry.dismissal == .untilAction), "\(tag)")
            // No universal Retry: only an entry whose own action re-runs work may say retry/again.
            for button in row.buttons where Self.isRetryLabel(button.label) {
                #expect(kind.rerunsWork && button.label == rendered.action, "\(tag): \(button.label)")
            }
            // Unconfirmed / partial writes are inspected, never re-inserted.
            if entry.treatment == .unconfirmedHold {
                #expect(kind == .inspect, "\(tag)")
                #expect(!row.buttons.contains { [.insert, .commit, .useAvailable].contains($0.action) }, "\(tag)")
            }
        }
    }

    // MARK: - The table: every id through the window notice renderers

    @Test("every catalogue id renders as a window banner, a partial banner and an error page",
          arguments: RecoveryCatalog.entries)
    func windowNotice(_ entry: RecoveryEntry) {
        let rendered = entry.rendered(hotkey: Self.key)
        let tag = entry.id.rawValue

        let banner = SectionBanner.recovery(rendered)
        #expect(banner.headline == rendered.headline && banner.body == rendered.consequence, "\(tag)")
        #expect(banner.actionTitle == rendered.action && banner.recoveryID == entry.id, "\(tag)")

        let partial = SectionBanner.partial(rendered)
        #expect(partial.headline == rendered.headline, "\(tag)")
        #expect(partial.body == rendered.consequence + SectionCopy.partialSuffix, "\(tag)")
        #expect(partial.actionTitle == rendered.action, "\(tag)")

        let state = SectionState.error(rendered)
        #expect(state.rendering == .error && state.isWellFormed, "\(tag)")
        #expect(state.recoveryID == entry.id, "\(tag)")
        #expect(SectionState.error(entry.id) == SectionState.error(entry), "\(tag)")

        let blocks = SectionPageAnatomy.blocks(copy: PageCopy(.today), state: state, hotkey: Self.key)
        #expect(blocks.first == .header(title: DesignScreen.today.name, subtitle: SectionCopy.errorSubtitle, action: nil),
                "\(tag)")
        guard case .recovery(let shown, let kept, let footnote)? = blocks.last else {
            Issue.record("\(tag): the error page ends with the recovery block"); return
        }
        #expect(shown.headline == rendered.headline && shown.actionTitle == rendered.action, "\(tag)")
        #expect(shown.body == rendered.consequence, "\(tag)")
        #expect(kept == rendered.dataPolicy, "\(tag): Data kept is the entry's data policy")
        #expect(footnote == SectionCopy.errorFootnote, "\(tag)")
        for line in [shown.headline, shown.body ?? "", shown.actionTitle ?? ""] {
            #expect(line.firstMatch(of: Self.leak) == nil, "\(tag): \(line)")
            #expect(!line.contains("Right Control"), "\(tag): \(line)")
        }
        // The window's one action is the entry's own — never a generic Retry in its place.
        if Self.isRetryLabel(shown.actionTitle ?? "") { #expect(entry.actionKind.rerunsWork, "\(tag)") }
    }

    // MARK: - Retry semantics (design §10)

    @Test("an action says retry or again exactly when it re-runs the failed work")
    func retryWordsMatchRerunningActions() {
        for entry in RecoveryCatalog.entries {
            #expect(Self.isRetryLabel(entry.action) == entry.actionKind.rerunsWork, "\(entry.id.rawValue): \(entry.action)")
        }
        // "No-speech retries a turn, model retry restarts a download, permission action opens the correct
        // setting, held text uses explicit retargeting, and unconfirmed insertion asks for inspection."
        #expect(RecoveryID.A06.actionKind == .retryTurn && RecoveryID.A06.actionKind.pillAction == nil)
        #expect([RecoveryID.M02, .M03, .M04].allSatisfy { $0.actionKind == .restartDownload })
        #expect(RecoveryID.P01.permission == .microphone && RecoveryID.P02.permission == .accessibility
            && RecoveryID.P03.permission == .inputMonitoring)
        #expect(RecoveryID.D01.actionKind == .retarget)
        #expect(RecoveryID.D06.actionKind == .inspect && RecoveryID.D07.actionKind == .inspect)
        #expect(!RecoveryActionKind.inspect.rerunsWork && RecoveryActionKind.inspect.pillAction == .check)
    }

    @Test("an unconfirmed or partial insertion is inspected, never retried, and nothing re-inserts it")
    @MainActor func unconfirmedNeverAutoRetries() {
        let model = PillViewModel()
        model.keyLabel = { Self.key }
        let held = HeldTextStore()
        var inserted = 0
        held.insertSink = { _ in inserted += 1; return true }
        let driver = DeliveryPillDriver(pill: model, held: held)
        var actions: [PillActionKind] = []
        model.onAction = { action, _ in actions.append(action) }

        for outcome in [DeliveryOutcome.delivered(verified: false, method: "paste"), .partial(method: "paste")] {
            let state = driver.handle(outcome, text: Self.words, destination: "Mail")
            #expect(PillDwell.staysUntilAction(state), "no timer can ever act on it")
            let row = model.content()
            #expect(!row.buttons.contains { Self.isRetryLabel($0.label) }, "\(row.buttons.map(\.label))")
            #expect(!row.buttons.contains { [.insert, .commit].contains($0.action) })
            #expect(held.isEmpty, "an unconfirmed write is never queued to be written again")
            #expect(row.buttons.first?.action == .check)
            model.perform(.check)
        }
        #expect(inserted == 0)
        #expect(actions == [.check, .check], "the only thing the row does is inspection")
        #expect(RecoveryCatalog.entry(for: DeliveryOutcome.delivered(verified: false, method: "paste"))?.id == .D06)
        #expect(RecoveryCatalog.entry(for: DeliveryOutcome.partial(method: "paste"))?.id == .D07)
        #expect(DeliveryCopy.landedUnverified == RecoveryCatalog.entry(.D06).headline)
    }

    @Test("a message the catalogue does not know is never drawn: X08, or the design's E0 row over kept words")
    func unknownMessageIsCatchAll() {
        let x08 = RecoveryCatalog.entry(.X08)
        for raw in ["invalidAudioData", "The file “weight.bin.partial” doesn’t exist.", "Nothing to put back"] {
            let row = PillContent.make(.error(message: raw), context: Self.context())
            #expect(row.status == PillDeck.warnPrefix + x08.headline, "\(raw)")
            #expect(!row.status.contains(raw) && !row.helper.contains(raw))
            #expect(PillState.error(message: raw).messageLines == [x08.headline, x08.consequence])
            // Words recovered from the turn: the prototype's error state E0 (T01's headline).
            let recovered = PillContent.make(.error(message: raw), context: Self.context(Self.words))
            #expect(recovered.status == PillDeck.errorStatus && recovered.buttons == PillDeck.errorButtons, "\(raw)")
            #expect(!recovered.status.contains(raw) && !recovered.helper.contains(raw))
        }
        // A headline rendered with the configured key still finds its entry (K03 fades).
        let k03 = RecoveryCatalog.entry(.K03).rendered(hotkey: Self.key).headline
        #expect(k03 == "Hold fn / 🌐 a little longer")
        #expect(PillNotice.entry(forMessage: k03)?.id == .K03)
        #expect(PillNotice.isQuietReturn(k03))
    }

    // MARK: - DeliveryCopy constants are catalogue lookups

    @Test("DeliveryCopy is the catalogue's words, and every reason maps through one mapping")
    func deliveryCopyLookups() {
        #expect(DeliveryCopy.destinationChanged == RecoveryCatalog.entry(.D01).headline)
        #expect(DeliveryCopy.microphoneDisconnected == RecoveryCatalog.entry(.A02).headline)
        #expect(DeliveryCopy.noSpeechDetected == RecoveryCatalog.entry(.A06).headline)
        #expect(DeliveryCopy.couldNotType == RecoveryCatalog.entry(.D05).headline)
        #expect(DeliveryCopy.landedUnverified == RecoveryCatalog.entry(.D06).headline)
        let reasons = [DeliveryReason.destinationChanged, DeliveryReason.noDestination, DeliveryReason.everyMethodThrew,
                       DeliveryReason.secureField, DeliveryReason.neverInject, "focus moved", "microphone disconnected",
                       "no speech detected", "no method could type here: keystroke,paste", "AXError -25204"]
        for reason in reasons {
            let entry = RecoveryCatalog.entry(forDeliveryReason: reason)
            #expect(DeliveryCopy.entry(forFailure: reason) == entry, "\(reason)")
            #expect(DeliveryCopy.message(forFailure: reason) == entry.headline, "\(reason)")
            let failed = PillDeliveryRouter.state(for: .failed(reason: reason), text: "x")
            #expect(failed == .error(message: entry.headline), "\(reason)")
            let held = HeldPillInfo(text: "x", destination: "Mail", reason: reason)
            #expect(held.headline == entry.headline, "\(reason)")
        }
        #expect(HeldPillInfo(text: "x", destination: "", reason: "").headline == DeliveryCopy.destinationChanged)
        #expect(DeliveryCopy.message(forFailure: "AXError -25204") == DeliveryCopy.couldNotType)
    }

    // MARK: - Repair suggestions

    @Test("a repair that found the text changed is D10; an informational refusal is a line that fades")
    func repairSuggestions() {
        let changed = RepairSuggestion(command: .scratchThat, segment: nil, reason: .regionChanged(actual: "x"))
        let entry = RecoveryCatalog.entry(for: changed.reason)
        #expect(entry?.id == .D10)
        #expect(DeliveryPillDriver.state(for: changed.pillLine, entry: entry) == .recovery(.D10))
        let nothing = RepairSuggestion(command: .scratchThat, segment: nil, reason: .nothingToScratch)
        #expect(RecoveryCatalog.entry(for: nothing.reason) == nil)
        #expect(DeliveryPillDriver.state(for: nothing.pillLine, entry: nil) == .preview(text: nothing.pillLine))
    }

    // MARK: - App-level notices, menu and presence

    @Test("app-level pill notices are catalogue entries: relaunch P04, lock K02, failed actions X08")
    func appLevelNotices() {
        #expect(AppRecovery.tapProvenDead == .P04)
        #expect(AppRecovery.entry(forStop: .locked)?.id == .K02)
        #expect(AppRecovery.entry(forStop: .slept)?.id == .K02)
        #expect(AppRecovery.entry(forStop: .userStopped) == nil)
        #expect(AppRecovery.entry(forAct: .failed(.execute, "AXError -25204"))?.id == .X08)
        #expect(AppRecovery.entry(forAct: .success(verified: true)) == nil)
        #expect(AppRecovery.entry(forAgent: .failed(reason: "planner: disabled"))?.id == .X08)
        #expect(AppRecovery.entry(forAgent: .gaveUp(reason: "x"))?.id == .X08)
        #expect(AppRecovery.entry(forAgent: .timedOut)?.id == .X08)
        #expect(AppRecovery.entry(forAgent: .unavailable(reason: "no planner")) == nil)
        #expect(AppRecovery.entry(forAgent: .completed(summary: "ok")) == nil)
        // K02 with nothing kept offers no "Review recovered text" (no recovery material).
        let k02 = PillContent.make(.recovery(.K02), context: Self.context())
        #expect(k02.buttons == [PillButton(PillDeck.dismissLabel, .dismiss, primary: true)])
    }

    @Test("the menu and the presence line are catalogue lines")
    func menuAndPresence() {
        let ids: [(MenuCopy.Line, RecoveryID)] = [
            (MenuCopy.Catalogue.microphoneDenied, .P01), (MenuCopy.Catalogue.shortcutPermission, .P03),
            (MenuCopy.Catalogue.reopen, .P04), (MenuCopy.Catalogue.finishingPrevious, .K04),
            (MenuCopy.Catalogue.muted, .K05), (MenuCopy.Catalogue.modelMissing, .M01),
        ]
        for (line, id) in ids {
            #expect(line == MenuCopy.Line(RecoveryCatalog.entry(id)), "\(id.rawValue)")
        }
        let reasons: [(PresenceBlockReason, RecoveryID)] = [
            (.microphoneDenied, .P01), (.hotkeyUnavailable, .P03), (.relaunchNeeded, .P04), (.modelMissing, .M01),
        ]
        for (reason, id) in reasons {
            let line = RecoveryCatalog.entry(id).problemAction
            #expect(MenuCopy.blockedLine(reason) == line, "\(id.rawValue)")
            #expect(reason.detail == line, "\(id.rawValue): the presence hover says the same")
            #expect(MenuStatus.blocked(reason).detail == line)
        }
        #expect(RecoveryCatalog.entry(.P04).problemAction == "Reopen VoicePlus to finish setup")
        #expect(PresenceBlockReason.modelDownloading(0.42).detail == "Downloading the speech model — 42%")
    }

    // MARK: - Onboarding

    @Test("onboarding's failures are catalogue entries with the entry's own action")
    func onboarding() {
        #expect(GuidedDictationOutcome.noSpeech(seconds: 0).recoveryID == .A05)
        #expect(GuidedDictationOutcome.noSpeech(seconds: 0.1).recoveryID == .A07)
        #expect(GuidedDictationOutcome.noSpeech(seconds: 2).recoveryID == .A06)
        #expect(GuidedDictationOutcome.failed(reason: RecoveryCatalog.entry(.A03).headline).recoveryID == .A03)
        #expect(GuidedDictationOutcome.failed(reason: "invalidAudioData").recoveryID == .X08)
        #expect(GuidedDictationOutcome.failed(reason: "invalidAudioData").failureMessage == RecoveryCatalog.entry(.X08).headline)
        #expect(GuidedDictationOutcome.heard(text: "x", recognizer: "y").recoveryID == nil)

        #expect(OnboardingRecovery.step(for: .A06) == .retryDictation)
        #expect(OnboardingRecovery.step(for: .P01) == .openSettings(.microphone))
        #expect(OnboardingRecovery.step(for: .A03) == .openSoundSettings)
        #expect(OnboardingRecovery.step(for: .M07) == .retryModelLoad)
        #expect(OnboardingRecovery.step(for: .M02) == .installModels)
        #expect(OnboardingRecovery.step(for: .X08) == .none, "no generic Try again standing in for Open recovery")
        #expect(OnboardingRecovery.step(for: .T01) == .none)
        // Every step the window offers is labelled with the entry's own action, and only a
        // re-running action ever becomes a retry.
        for entry in RecoveryCatalog.entries {
            let step = OnboardingRecovery.step(for: entry.id)
            if step == .retryDictation || step == .retryModelLoad || step == .installModels {
                #expect(entry.actionKind.rerunsWork, "\(entry.id.rawValue)")
            }
        }

        #expect(OnboardingRecovery.entry(for: .noAudio)?.id == .A05)
        #expect(OnboardingRecovery.entry(for: .tooQuiet)?.id == .A08)
        #expect(OnboardingRecovery.entry(for: .clipping)?.id == .A08)
        #expect(OnboardingRecovery.entry(for: .unavailable("kAudioUnitErr_FormatNotSupported"))?.id == .A03)
        #expect(OnboardingRecovery.detail(for: .unavailable("kAudioUnitErr_FormatNotSupported")) == "kAudioUnitErr_FormatNotSupported",
                "the technical cause sits behind Details, not in the headline")
        #expect(OnboardingRecovery.entry(for: .permissionRequired)?.id == .P01)
        #expect(OnboardingRecovery.entry(for: .good) == nil && OnboardingRecovery.entry(for: .waiting) == nil)
        // The practice field's own failures: nothing reached a field (D02), the text changed (D10).
        #expect(OnboardingCopy.notInserted.hasPrefix(RecoveryCatalog.entry(.D02).headline))
        #expect(OnboardingCopy.correctionRefused
            == RecoveryCatalog.entry(.D10).headline + ". " + RecoveryCatalog.entry(.D10).consequence)
    }

    // MARK: - Window copy that used to be written locally

    @Test("the window's error sentences are catalogue headlines")
    @MainActor func windowSentences() {
        #expect(SectionCopy.timelineUnreadable == RecoveryCatalog.entry(.S01).headline)
        #expect(SectionCopy.egressUnreadable == RecoveryCatalog.entry(.S01).headline)
        #expect(SectionCopy.meetingsUnreadable == RecoveryCatalog.entry(.S01).headline)
        #expect(SectionCopy.timelineSearchFailed == RecoveryCatalog.entry(.S01).headline)
        #expect(SectionCopy.timelineStoreMissing == RecoveryCatalog.entry(.S01).headline)
        #expect(SectionCopy.notSaved == RecoveryCatalog.entry(.S02).headline)
        #expect(SectionCopy.settingNotSaved == RecoveryCatalog.entry(.S02).headline)
        #expect(SectionCopy.deleteAllPartial == RecoveryCatalog.entry(.S04).headline)
        #expect(SectionCopy.timelineRowNotDeleted == RecoveryCatalog.entry(.S04).headline)
        #expect(SectionCopy.contactsDenied == RecoveryCatalog.entry(.X04).headline)
        #expect(SectionCopy.calendarOff == RecoveryCatalog.entry(.X01).headline)
        #expect(SectionCopy.meetingUnreadableRow == RecoveryCatalog.entry(.X02).headline)
        #expect(SectionCopy.microphoneOff == RecoveryCatalog.entry(.P01).headline)
        #expect(SectionCopy.heldRowFailed == RecoveryCatalog.entry(.D05).headline)
        #expect(MeetingsCopy.recoverFailed == RecoveryCatalog.entry(.X02).headline)
        #expect(MeetingsCopy.deleteFailed == RecoveryCatalog.entry(.S04).headline)
        #expect(MeetingsCopy.askFailed == RecoveryCatalog.entry(.N04).headline)
        #expect(SnippetsViewModel.describe(NSError(domain: "x", code: 1)) == RecoveryCatalog.entry(.S02).problemAction)
        #expect(SnippetsViewModel.notDeleted("brb") == RecoveryCatalog.entry(.S04).problemAction)
        #expect(VoiceSectionViewModel.microphoneState(denied: true, enumerated: true, deviceCount: 1)
            == .error(RecoveryCatalog.entry(.P01)))
        #expect(PillState.unavailable(reason: "No speech model installed").messageLines
            == [RecoveryCatalog.entry(.M01).headline, RecoveryCatalog.entry(.M01).consequence])
    }

    @Test("a transform that did not land says so in catalogue words, never the reason")
    func transformFailures() {
        #expect(TransformLanding.describe(TransformReplaceOutcome.mismatch(actual: "x")) == RecoveryCatalog.entry(.D10).headline)
        let unavailable = TransformLanding.describe(TransformReplaceOutcome.unavailable(reason: "AXError -25204"))
        #expect(unavailable == RecoveryCatalog.entry(.D05).headline)
        #expect(!unavailable.contains("AXError"))
        #expect(TransformLanding.describe(TransformError.uncertainInstruction(["frobnicate"])) == RecoveryCatalog.entry(.T05).headline)
    }
}
