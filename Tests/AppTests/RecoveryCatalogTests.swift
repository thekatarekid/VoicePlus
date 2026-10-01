import Actions
import Engine
import FluidAudio
import Foundation
import Injection
import Lab
import Pipeline
import Providers
import Shared
import Sync
import Testing
@testable import VoicePlusApp

/// S9 — the recovery catalogue (design_v1 §10) against the prototype's fixtures, and every mapping
/// into it: thrown errors, delivery outcomes and reasons, permission states, engine and session
/// states, repair refusals and named conditions.
@Suite("Recovery catalogue: 59 entries, verbatim copy, every id reachable or defensive")
struct RecoveryCatalogTests {
    // MARK: Fixtures

    private struct FixtureEntry: Decodable {
        let id, family, trigger, headline, consequence, action, data: String
    }
    private struct Copy: Decodable { let errors: [FixtureEntry] }
    private struct Pose: Decodable { let pose: String; let key: String }
    private struct Spec: Decodable { let errorPoses: [String: Pose] }

    private static func fixture<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        let dir = try #require(AppPaths.fixturesDirectory())
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(path)))
    }

    /// Design §10: a headline never carries a `…Error` type name, a camelCase token, a scratch file
    /// or a path.
    private static let leak = try! Regex(
        #"[A-Za-z]+Error|\b[a-z]+[A-Z][A-Za-z]*\b|\.bin\b|\.partial\b|\.part\b|/[A-Za-z0-9_.-]+"#)

    private static let quiet = Log(category: "s9-test", buffer: LogBuffer(capacity: 1))

    // MARK: Samples: one of every error shape each mapping knows, with the id it must reach

    private enum Bare: Error { case somethingSpecific }

    static let engineErrors: [(Error, RecoveryID)] = [
        (EngineError.alreadyListening, .K04),
        (EngineError.modelUnavailable("tdt-v3"), .M01),
        (EngineError.notListening, .X08),
        (AudioCaptureError.noInputDevice, .A01),
        (AudioCaptureError.engineStartFailed("kAudioUnitErr_FormatNotSupported"), .A03),
        (AudioCaptureError.deviceSelectionFailed(-10851), .A03),
        (AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100), .A04),
        (AudioCaptureError.noAudio(seconds: 1.5), .A05),
        (AudioCaptureError.busy(owner: "meeting"), .A09),
        (ModelManagerError.unsupported(.parakeetTDTv3), .M06),
        (ModelManagerError.notPresent(.parakeetTDTv3), .M08),
        (ModelManagerError.verificationFailed(.parakeetTDTv3, ["Encoder.mlmodelc/weights/weight.bin"]), .M03),
        (ModelManagerError.incomplete(.parakeetTDTv3, ["Encoder.mlmodelc/weights/weight.bin.partial"]), .M02),
        (DownloadError.httpStatus(503, "https://huggingface.co/x"), .M04),
        (DownloadError.checksumMismatch(path: "/Models/a.bin", expected: "aa", actual: "bb"), .M03),
        (DownloadError.incompleteDownload(.parakeetTDTv3, ["a.bin"]), .M02),
        (ASRError.invalidAudioData, .A07),
        (ASRError.modelLoadFailed, .M07),
        (ASRError.unsupportedPlatform("x86_64"), .M06),
        (ASRError.processingFailed("decoder"), .T01),
        (RefinementError.weightsMissing(searched: ["/Models/qwen3"]), .T03),
        (SpeakerError.tooShort(samples: 10), .X03),
        (BiasVocabulary.LoadError.unsupportedFormat("xml"), .X04),
        (URLError(.networkConnectionLost), .M04),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/Models/parakeet/Decoder.mlmodelc/weights/weight.bin.partial",
            NSLocalizedDescriptionKey: "The file “weight.bin.partial” doesn’t exist.",
        ]), .M02),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .M05),
        (Bare.somethingSpecific, .X08),
    ]

    static let appErrors: [(Error, RecoveryID)] = [
        (SessionCoordinator.Refusal.busy(.hotkey), .K04),
        (SessionCoordinator.Refusal.busy(.menu), .K04),
        (SessionCoordinator.Refusal.busy(.meeting), .A09),
        (SessionCoordinator.Refusal.busy(.onboarding), .A09),
        (SessionCoordinator.Refusal.muted, .K05),
        (SessionCoordinator.Refusal.awaitingRestart, .K02),
        (ProviderError.unavailable("ollama"), .N01),
        (ProviderError.timeout, .N01),
        (ProviderError.http(503, "upstream"), .N01),
        (ProviderError.unauthorized, .N02),
        (ProviderError.http(401, "bad key"), .N02),
        (ProviderError.http(429, "rate limited"), .N03),
        (ProviderError.http(402, "billing"), .N03),
        (ProviderError.http(400, "bad request"), .N04),
        (ProviderError.malformedResponse("not json"), .N04),
        (ProviderError.cancelled, .N04),
        (ProviderError.capabilityMissing("rewrite"), .N04),
        (ProviderError.flagDisabled("providers.cloud"), .N04),
        (ProviderRoutingError.unavailable, .N01),
        (ProviderRoutingError.disabled(stage: .transform), .N04),
        (SystemAccessError.accessibilityNotTrusted, .P02),
        (SystemAccessError.noFocusedElement, .D02),
        (SystemAccessError.attributeNotSettable("AXValue"), .D02),
        (SystemAccessError.axError(-25204), .D05),
        (SystemAccessError.eventPostFailed, .D05),
        (TransformError.uncertainInstruction(["frobnicate"]), .T05),
        (TransformError.emptyOutput, .T03),
        (RefinementTimedOut(deadline: .seconds(1)), .T03),
        (PairingError.codeMismatch, .X05),
        (PairingError.selfPairing, .X05),
        (SyncCryptoError.tampered, .X05),
        (PairingPayload.ParseError.badScheme, .X05),
        (ConnectorError.notSignedIn, .N02),
        (ConnectorError.unauthorized, .N02),
        (ConnectorError.http(401, "expired"), .N02),
        (ConnectorError.http(429, "slow down"), .N03),
        (ConnectorError.http(502, "gateway"), .N01),
        (ConnectorError.http(404, "gone"), .N04),
        (ConnectorError.timeout, .N01),
        (ConnectorError.malformedResponse("html"), .N04),
        (ConnectorError.unsupported("calendar"), .N04),
        (EgressGate.Denied.killSwitch(host: "api.openai.com"), .N04),
        (InputRecorderError.inputMonitoringNotGranted, .P03),
        (InputRecorderError.tapCreationFailed, .P03),
        (SnippetError.duplicateTrigger("sig"), .S02),
        (SnippetError.emptyBody, .S02),
    ]

    static let outcomes: [(DeliveryOutcome, RecoveryID?)] = [
        (.delivered(verified: true, method: "ax"), nil),
        (.delivered(verified: false, method: "keystroke"), .D06),
        (.partial(method: "keystroke"), .D07),
        (.held(reason: DeliveryReason.destinationChanged), .D01),
        (.held(reason: DeliveryReason.neverInject), .D04),
        (.failed(reason: DeliveryReason.noDestination), .D02),
        (.failed(reason: DeliveryReason.everyMethodThrew), .D05),
        (.failed(reason: DeliveryReason.secureField), .D03),
        (InjectionOutcome.refused(.secureField).delivery, .D03),
        (InjectionOutcome.refused(.neverInject).delivery, .D04),
        (InjectionOutcome.abortedFocusChanged(expected: nil, actual: nil).delivery, .D01),
        (InjectionOutcome.failed(attempts: []).delivery, .D02),
        (InjectionOutcome.failed(attempts: [.ax, .keystroke]).delivery, .D05),
        (.failed(reason: "microphone disconnected"), .A02),
        (.failed(reason: "no speech"), .A06),
        (.held(reason: "focus moved to another window"), .D01),
        (.failed(reason: "AXError -25212 kAXErrorCannotComplete"), .D05),
        (.held(reason: "target element went away"), .D01),
        (.failed(reason: "no input"), .A02),
        (.failed(reason: "empty transcript"), .A06),
        (.failed(reason: "nothing heard"), .A06),
    ]

    static let permissions: [(RecoveryCatalog.PermissionState, RecoveryID?)] = [
        (.init(.microphone, .denied), .P01),
        (.init(.microphone, .awaitingUserAction), .P01),
        (.init(.accessibility, .denied), .P02),
        (.init(.inputMonitoring, .awaitingUserAction), .P03),
        (.init(.accessibility, .granted, needsRelaunch: true), .P04),
        (.init(.inputMonitoring, .denied, needsRelaunch: true), .P04),
        (.init(.microphone, .granted), nil),
        (.init(.accessibility, .notDetermined), nil),
    ]

    static let engineStates: [(EngineState, RecoveryID?)] = [
        (.idle, nil), (.prewarming, nil), (.starting, nil), (.listening(level: 0.4), nil),
        (.previewing(text: "hello"), nil), (.finalizing, nil), (.finishing, nil), (.landed, nil), (.cancelled, nil),
        (.unavailable("No speech model installed"), .M01),
        (.warning(MicQuality(snr: 6, clipping: 0, lowLevel: false, verdict: .poor)), .A08),
        (.error("boom"), .X08),
        (.error("The speech model isn’t ready"), .M07),
    ]

    static let stops: [(SessionCoordinator.StopReason, RecoveryID?)] = [
        (.userStopped, nil), (.escape, nil), (.muted, .K05), (.locked, .K02), (.slept, .K02),
        (.preempted, .A09), (.deviceLost, .A02),
    ]

    static let repairs: [(RepairSuggestion.Reason, RecoveryID?)] = [
        (.regionChanged(actual: "Can we meet Friday"), .D10), (.editRefused("focus moved"), .D10),
        (.regionUnreadable("AX"), .D10), (.nothingToScratch, nil), (.contextExpired, nil),
    ]

    static let signals: [(RecoveryCatalog.Signal, RecoveryID)] = [
        (.shortcutUnavailable, .K01), (.pressTooShort, .K03), (.noSpeech, .A06), (.tooShortToTranscribe, .A07),
        (.historyUnreadable, .S01), (.changesNotSaved, .S02), (.deletionPartial, .S04),
        (.meetingPermissionMissing, .X01), (.meetingUnreadable, .X02), (.wordImportFailed, .X04),
    ]

    // MARK: Data

    @Test func theCatalogueIsTheFixturesFiftyNineEntriesVerbatim() throws {
        let fixture = try Self.fixture("design/design_copy.json", as: Copy.self).errors
        #expect(fixture.count == 59)
        #expect(RecoveryCatalog.entries.count == 59)
        #expect(RecoveryCatalog.entries.map(\.id.rawValue) == fixture.map(\.id))
        #expect(Set(RecoveryCatalog.entries.map(\.id)) == Set(RecoveryID.allCases))
        for (entry, row) in zip(RecoveryCatalog.entries, fixture) {
            #expect(entry.family.rawValue == row.family, "\(row.id)")
            #expect(entry.trigger == row.trigger, "\(row.id)")
            #expect(entry.headline == row.headline, "\(row.id)")
            #expect(entry.consequence == row.consequence, "\(row.id)")
            #expect(entry.action == row.action, "\(row.id)")
            #expect(entry.dataPolicy == row.data, "\(row.id)")
            #expect(RecoveryCatalog.entry(entry.id) == entry)
        }
    }

    @Test func everyEntryCarriesTheSpecsSpoolTreatment() throws {
        let poses = try Self.fixture("spool/spool_spec.json", as: Spec.self).errorPoses
        #expect(poses.count == 59)
        for entry in RecoveryCatalog.entries {
            let pose = try #require(poses[entry.id.rawValue], "\(entry.id.rawValue) has no pose")
            #expect(entry.treatment.poseName == pose.pose, "\(entry.id.rawValue)")
            #expect(entry.poseKey == pose.key, "\(entry.id.rawValue)")
        }
        #expect(Set(RecoveryCatalog.entries.map(\.treatment)) == Set(RecoveryTreatment.allCases),
                "every treatment the spec names is used, and no other")
    }

    @Test func noCatalogueHeadlineCarriesATechnicalToken() {
        for entry in RecoveryCatalog.entries {
            #expect(entry.headline.firstMatch(of: Self.leak) == nil, "\(entry.id.rawValue): \(entry.headline)")
        }
    }

    // MARK: Mapping

    @Test func everyMappedErrorYieldsItsEntryAndACleanHeadline() {
        for (error, id) in Self.engineErrors + Self.appErrors {
            let entry = RecoveryCatalog.entry(for: error)
            #expect(entry.id == id, "\(error)")
            #expect(entry.headline.firstMatch(of: Self.leak) == nil, "\(entry.headline) (from \(error))")
        }
    }

    @Test func deliveryOutcomesAndReasons() {
        for (outcome, id) in Self.outcomes {
            #expect(RecoveryCatalog.entry(for: outcome)?.id == id, "\(outcome)")
        }
        #expect(RecoveryCatalog.entry(for: InjectionRefusal.secureField).id == .D03)
        #expect(RecoveryCatalog.entry(for: InjectionRefusal.neverInject).id == .D04)
        #expect(RecoveryCatalog.entry(forDeliveryReason: "  Destination Changed ").id == .D01)
    }

    @Test func permissionStates() {
        for (state, id) in Self.permissions {
            #expect(RecoveryCatalog.entry(for: state)?.id == id, "\(state)")
        }
    }

    @Test func engineStatesAndSessionStops() {
        for (state, id) in Self.engineStates {
            #expect(RecoveryCatalog.entry(for: state)?.id == id, "\(state)")
        }
        for (reason, id) in Self.stops {
            #expect(RecoveryCatalog.entry(for: reason)?.id == id, "\(reason)")
        }
        for (reason, id) in Self.repairs {
            #expect(RecoveryCatalog.entry(for: reason)?.id == id, "\(reason)")
        }
        for (signal, id) in Self.signals {
            #expect(RecoveryCatalog.entry(for: signal).id == id, "\(signal)")
        }
        #expect(Self.signals.count == RecoveryCatalog.Signal.allCases.count)
    }

    /// Build doc S9: every catalogue id is reachable by at least one mapping or is marked defensive —
    /// and the flag is honest: no defensive entry is reachable.
    @Test func everyIDIsReachableOrMarkedDefensive() {
        var reachable = Set<RecoveryID>()
        func add(_ entry: RecoveryEntry?) { if let entry { reachable.insert(entry.id) } }
        for (error, _) in Self.engineErrors + Self.appErrors { add(RecoveryCatalog.entry(for: error)) }
        for (outcome, _) in Self.outcomes { add(RecoveryCatalog.entry(for: outcome)) }
        for refusal in InjectionRefusal.allCases { add(RecoveryCatalog.entry(for: refusal)) }
        for (state, _) in Self.permissions { add(RecoveryCatalog.entry(for: state)) }
        for (state, _) in Self.engineStates { add(RecoveryCatalog.entry(for: state)) }
        for (reason, _) in Self.stops { add(RecoveryCatalog.entry(for: reason)) }
        for (reason, _) in Self.repairs { add(RecoveryCatalog.entry(for: reason)) }
        for signal in RecoveryCatalog.Signal.allCases { add(RecoveryCatalog.entry(for: signal)) }

        let defensive = Set(RecoveryCatalog.entries.filter(\.isDefensive).map(\.id))
        let unaccounted = Set(RecoveryID.allCases).subtracting(reachable).subtracting(defensive)
        #expect(unaccounted.isEmpty, "unreachable and not defensive: \(unaccounted.map(\.rawValue).sorted())")
        let dishonest = reachable.intersection(defensive)
        #expect(dishonest.isEmpty, "marked defensive but mapped: \(dishonest.map(\.rawValue).sorted())")
        #expect(defensive == [.T02, .T04, .D08, .D09, .D11, .S03, .S05, .X06, .X07])
    }

    // MARK: EngineMessage routes through the catalogue

    @Test func describeReturnsTheCatalogueHeadlineForEveryEngineError() {
        for (error, id) in Self.engineErrors {
            let headline = EngineMessage.describe(error, log: Self.quiet)
            #expect(headline == RecoveryCatalog.entry(id).headline, "\(error)")
            #expect(EngineMessage.recoveryID(for: error) == RecoveryCatalog.recoveryID(for: error))
            // The published `EngineState.error` maps straight back to the same entry.
            #expect(RecoveryCatalog.entry(for: EngineState.error(headline))?.id == id)
        }
    }

    @Test func theEngineSliceIsTheCataloguesCopy() {
        var slice = 0
        for id in RecoveryID.allCases {
            guard let headline = EngineMessage.engineHeadline(for: id) else { continue }
            slice += 1
            #expect(headline == RecoveryCatalog.entry(id).headline, "\(id.rawValue)")
        }
        // 21 since `AudioCaptureError.notPermitted` made P01 reachable from the engine layer: a
        // missing or revoked microphone grant is no longer reported as A01 "No microphone found".
        #expect(slice == 21)
    }

    /// App-layer errors follow the same rule as `EngineMessage.describe`: the entry comes back, the
    /// error's own text (here an HTTP body and a host) goes to the log only.
    @Test func reportLogsTheTechnicalDetailAndReturnsOnlyTheEntry() {
        let buffer = LogBuffer(capacity: 10)
        let error = ProviderError.http(429, "quota exceeded for key sk-live-…")
        let entry = RecoveryCatalog.report(error, log: Log(category: "s9-test", buffer: buffer))
        #expect(entry.id == .N03)
        #expect(entry.headline == "This service is temporarily unavailable")
        let logged = buffer.snapshot().map(\.message).joined(separator: "\n")
        #expect(logged.contains("N03") && logged.contains("quota exceeded"))
        for text in [entry.headline, entry.consequence, entry.action] { #expect(!text.contains("sk-live")) }
        #expect(RecoveryCatalog.report(Bare.somethingSpecific, log: Self.quiet).id == .X08)
    }

    /// The Qwen3-ASR second pass is macOS 15+: unsupported hardware is M06, anything else leaves the
    /// first-pass text standing (T03).
    @Test func qwenRefinementErrors() {
        guard #available(macOS 15, *) else { return }
        #expect(RecoveryCatalog.entry(for: Qwen3AsrError.unsupportedHardware).id == .M06)
        #expect(RecoveryCatalog.entry(for: Qwen3AsrError.decoderFailed("logits")).id == .T03)
        #expect(EngineMessage.describe(Qwen3AsrError.modelNotFound("qwen3_asr_embeddings.bin"), log: Self.quiet)
                == "Cleanup is unavailable")
    }

    @Test func describeSendsTheRawTextToTheLogOnly() {
        let buffer = LogBuffer(capacity: 10)
        let error = ASRError.invalidAudioData
        let headline = EngineMessage.describe(error, log: Log(category: "s9-test", buffer: buffer))
        #expect(headline == "That was too short to transcribe")
        let logged = buffer.snapshot().map(\.message)
        #expect(logged.contains { $0.contains("A07") && $0.contains("300ms of 16kHz") })
        #expect(!headline.contains("300ms"))
    }

    // MARK: Presentation rules

    /// Owner decision: "Right Control" is rendered with the configured key; nothing else changes.
    @Test func theConfiguredKeyReplacesRightControl() {
        #expect(RecoveryCatalog.entry(.K03).headline == "Hold Right Control a little longer")
        #expect(RecoveryCatalog.entry(.K03).rendered(hotkey: "fn / 🌐").headline == "Hold fn / 🌐 a little longer")
        for entry in RecoveryCatalog.entries {
            let rendered = entry.rendered(hotkey: "fn")
            for text in [rendered.headline, rendered.consequence, rendered.action, rendered.dataPolicy, rendered.trigger] {
                #expect(!text.contains("Right Control"), "\(entry.id.rawValue)")
            }
            if entry.id != .K03 { #expect(rendered == entry, "\(entry.id.rawValue) changed") }
        }
    }

    /// Design §10: notices stay until the user acts; only quiet-return hints fade (800–1600 ms).
    @Test func onlyQuietReturnsFade() {
        #expect(RecoveryCatalog.fadeWindow == 0.8...1.6)
        let fading = Set(RecoveryCatalog.entries.filter { $0.dismissal == .fades }.map(\.id))
        #expect(fading == [.K03, .A06, .A07])
        #expect(Set(RecoveryCatalog.entries.filter { $0.dismissal == .whileConditionHolds }.map(\.id)) == [.K04, .A08])
        for id in [RecoveryID.D01, .D06, .D07, .A02, .M02, .X08, .P01, .N01] {
            #expect(RecoveryCatalog.entry(id).dismissal == .untilAction, "\(id.rawValue)")
        }
    }
}
