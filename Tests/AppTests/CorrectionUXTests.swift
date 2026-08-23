import Foundation
import Testing
import Shared
import Engine
import Injection
import Pipeline
@testable import VoicePlusApp

@Suite("P1.5.2 — correction UX models")
struct CorrectionUXTests {
    static func event(_ was: String, _ now: String, at: Int = 0, kind: CorrectionEvent.Kind = .applied, id: UUID = UUID()) -> CorrectionEvent {
        CorrectionEvent(utteranceID: id, kind: kind, range: at..<(at + now.utf16.count), was: was, now: now, audioRange: 0...1)
    }

    @Test func ledgerRecordsEventsWithStatusAndApp() {
        let ledger = CorrectionLedger()
        ledger.currentAppBundleID = "com.apple.mail"
        ledger.correction(Self.event("Cotari", "Kothari"))
        ledger.correction(Self.event("their", "there", kind: .suggested(.lowFinalConfidence)))
        ledger.correction(Self.event("a", "b", kind: .refused))
        #expect(ledger.all.count == 3)
        #expect(ledger.all[0].status == .applied && ledger.all[0].appBundleID == "com.apple.mail")
        #expect(ledger.all[1].status == .suggested("lowFinalConfidence"))
        #expect(ledger.all[2].status == .suggested("refused"))
        #expect(ledger.recent.first?.now == "b")
    }

    @Test func ledgerIsBounded() {
        let ledger = CorrectionLedger(); ledger.maxEntries = 3
        for i in 0..<5 { ledger.correction(Self.event("w\(i)", "x\(i)")) }
        #expect(ledger.all.map(\.was) == ["w2", "w3", "w4"])
    }

    @Test func hoverLabelAndMenuLine() {
        var e = CorrectionEntry(event: Self.event("Cotari", "Kothari"), appBundleID: nil, at: Date())
        #expect(e.hoverLabel == "was: Cotari" && e.menuLine == "Cotari → Kothari" && e.isRevertable)
        e.status = .reverted
        #expect(e.menuLine == "Cotari ← Kothari (put back)" && !e.isRevertable)
        e.status = .suggested("safetyMismatch")
        #expect(e.menuLine.hasSuffix("(suggested)"))
        let ins = CorrectionEntry(event: Self.event("", "the"), appBundleID: nil, at: Date())
        #expect(ins.hoverLabel == "was: ∅" && ins.menuLine == "∅ → the")
    }

    @Test func highlightPhasesShimmerThenUnderlineThenGone() {
        #expect(CorrectionHighlightPhase.at(0) == .shimmer)
        #expect(CorrectionHighlightPhase.at(0.44) == .shimmer)
        #expect(CorrectionHighlightPhase.at(0.5) == .underline)
        #expect(CorrectionHighlightPhase.at(1.99) == .underline)
        #expect(CorrectionHighlightPhase.at(2.0) == .gone)
    }

    @Test func revertPutsWordBackThroughSinkAndShiftsSiblings() {
        let sink = InMemoryReplaceRangeSink(document: "send Kothari the docs now")
        let ledger = CorrectionLedger()
        let id = UUID()
        ledger.correction(Self.event("Cotari", "Kothari", at: 5, id: id))     // 5..<12
        ledger.correction(Self.event("dogs", "docs", at: 17, id: id))        // 17..<21
        let first = ledger.all[0]
        #expect(ledger.revert(first, via: sink) == .replaced)
        #expect(sink.document == "send Cotari the docs now")
        #expect(ledger.all[0].status == .reverted)
        #expect(ledger.all[1].range == 16..<20)                               // shifted by -1
        #expect(ledger.revert(ledger.all[0], via: sink) == .unavailable(reason: "not revertable"))
        #expect(ledger.revert(ledger.all[1], via: sink) == .replaced)
        #expect(sink.document == "send Cotari the dogs now")
    }

    @Test func revertRefusedWhenDocumentChanged() {
        let system = MockSystemAccess()
        system.field = .init(value: "send Kotari now")
        let sink = InjectionReplaceRangeSink(system: system)
        let ledger = CorrectionLedger()
        ledger.correction(Self.event("Cotari", "Kothari", at: 5))
        let o = ledger.revert(ledger.all[0], via: sink)
        #expect(!o.succeeded && ledger.all[0].status == .applied)
        #expect(system.field.value == "send Kotari now")
    }

    @Test func latestRevertableHonoursUndoWindow() {
        let ledger = CorrectionLedger()
        let t0 = Date(timeIntervalSince1970: 1_000)
        ledger.now = { t0 }
        ledger.correction(Self.event("a", "b"))
        #expect(ledger.latestRevertable(at: t0 + 9) != nil)
        #expect(ledger.latestRevertable(at: t0 + 11) == nil)
        #expect(CorrectionLedger().latestRevertable() == nil)
    }

    @Test func putItBackVoiceUndoRevertsLatestCorrectionOnly() {
        let sink = InMemoryReplaceRangeSink(document: "hello Kothari")
        let ledger = CorrectionLedger()
        ledger.correction(Self.event("Cotari", "Kothari", at: 6))
        #expect(CorrectionUndoRouter.handle(text: "no, Kothari", ledger: ledger, sink: sink) == .notACorrection)
        guard case .revertedCorrection(let e) = CorrectionUndoRouter.handle(text: "put it back", ledger: ledger, sink: sink) else {
            Issue.record("expected revert"); return
        }
        #expect(e.status == .reverted && sink.document == "hello Cotari")
        // Nothing left to put back → falls through to the repair session's own undo.
        #expect(CorrectionUndoRouter.handle(text: "put it back", ledger: ledger, sink: sink) == .notACorrection)
    }

    @Test func perAppOffSwitchAndGlobalSwitch() {
        let store = InMemorySettingsStore()
        #expect(CorrectionSettings.isEnabled(for: "com.apple.Notes", store: store))
        CorrectionSettings.setEnabled(false, for: "com.apple.Notes", store: store)
        #expect(!CorrectionSettings.isEnabled(for: "com.apple.Notes", store: store))
        #expect(CorrectionSettings.isEnabled(for: "com.apple.mail", store: store))
        #expect(CorrectionSettings.isEnabled(for: nil, store: store))
        CorrectionSettings.setEnabled(true, for: "com.apple.Notes", store: store)
        #expect(CorrectionSettings.isEnabled(for: "com.apple.Notes", store: store))
        store.set(false, for: CorrectionSettings.enabledKey)
        #expect(!CorrectionSettings.isEnabled(for: "com.apple.mail", store: store))
    }

    @Test @MainActor func correctionSettingsViewModelTracksDisabledApps() {
        let store = InMemorySettingsStore()
        let vm = CorrectionSettingsViewModel(store: store)
        #expect(vm.enabled)
        vm.disable(app: " com.tinyspeck.slackmacgap ")
        #expect(vm.disabledApps == ["com.tinyspeck.slackmacgap"])
        #expect(!CorrectionSettings.isEnabled(for: "com.tinyspeck.slackmacgap", store: store))
        vm.enable(app: "com.tinyspeck.slackmacgap")
        #expect(vm.disabledApps.isEmpty && CorrectionSettings.isEnabled(for: "com.tinyspeck.slackmacgap", store: store))
        vm.enabled = false
        #expect(store.bool(CorrectionSettings.enabledKey) == false)
        #expect(CorrectionSettingsViewModel(store: store).enabled == false)
    }

    @Test func overlayFrameCoversWordAndHangsCardBelowOrAbove() {
        let e = CorrectionEntry(event: Self.event("Cotari", "Kothari"), appBundleID: nil, at: Date())
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let word = CGRect(x: 300, y: 500, width: 60, height: 18)
        let plain = CorrectionOverlayModel(entry: e, wordRect: word)
        #expect(plain.frame(in: screen) == word.insetBy(dx: -2, dy: -2) && plain.isVisible)
        let hovered = CorrectionOverlayModel(entry: e, wordRect: word, phase: .gone, hovered: true)
        let f = hovered.frame(in: screen)
        #expect(f.maxY == word.maxY + 2 && f.minY < word.minY && f.width > word.width && hovered.isVisible)
        #expect(!hovered.cardIsAbove(in: screen))
        let low = CorrectionOverlayModel(entry: e, wordRect: CGRect(x: 1430, y: 5, width: 60, height: 18), hovered: true)
        let lf = low.frame(in: screen)
        #expect(low.cardIsAbove(in: screen) && lf.minY == 3 && lf.maxX <= screen.maxX)
        #expect(!CorrectionOverlayModel(entry: e, wordRect: word, phase: .gone).isVisible)
    }

    @Test func menuRowsNewestFirstCappedAndToggleTitle() {
        let ledger = CorrectionLedger()
        for i in 0..<10 { ledger.correction(Self.event("w\(i)", "x\(i)")) }
        let rows = CorrectionMenuBuilder.rows(ledger: ledger)
        #expect(rows.count == CorrectionMenuBuilder.maxRows && rows.first?.was == "w9")
        let store = InMemorySettingsStore()
        #expect(CorrectionMenuBuilder.appToggleTitle(bundleID: "com.apple.Notes", settings: store) == "Turn off silent corrections in Notes")
        CorrectionSettings.setEnabled(false, for: "com.apple.Notes", store: store)
        #expect(CorrectionMenuBuilder.appToggleTitle(bundleID: "com.apple.Notes", settings: store) == "Turn on silent corrections in Notes")
        #expect(CorrectionMenuBuilder.appToggleTitle(bundleID: nil, settings: store) == nil)
    }

    @Test @MainActor func menuItemListsEntriesAndRevertsOnClick() {
        let ledger = CorrectionLedger()
        ledger.correction(Self.event("Cotari", "Kothari", at: 0))
        final class T: NSObject { @objc func r(_ s: Any) {}; @objc func t(_ s: Any) {} }
        let item = CorrectionMenuBuilder.item(ledger: ledger, settings: InMemorySettingsStore(), bundleID: "com.apple.Notes", target: T(),
                                              revert: #selector(T.r(_:)), toggleApp: #selector(T.t(_:)))
        let titles = item.submenu!.items.map(\.title)
        #expect(item.title == "Show what changed")
        #expect(titles.first == "Cotari → Kothari" && titles.last == "Turn off silent corrections in Notes")
        #expect(item.submenu!.items[0].isEnabled)
        let empty = CorrectionMenuBuilder.item(ledger: CorrectionLedger(), settings: nil, bundleID: nil, target: T(), revert: #selector(T.r(_:)), toggleApp: #selector(T.t(_:)))
        #expect(empty.submenu!.items.map(\.title) == ["No silent corrections yet"])
    }

    @Test @MainActor func overlayControllerShowsOnlyWithRectAndRevertsOnTap() {
        final class Rects: WordRectProvider {
            var rect: CGRect? = CGRect(x: 200, y: 400, width: 60, height: 18)
            func wordRect(utf16Range: Range<Int>) -> CGRect? { rect }
        }
        let sink = InMemoryReplaceRangeSink(document: "Kothari now")
        let ledger = CorrectionLedger()
        let rects = Rects()
        let overlay = CorrectionOverlayController(ledger: ledger, rectProvider: rects)
        overlay.revertSink = sink
        var reverted: CorrectionEntry?
        overlay.onReverted = { reverted = $0 }
        ledger.correction(Self.event("Cotari", "Kothari", at: 0))
        #expect(overlay.show(ledger.all[0]) && overlay.model?.phase == .shimmer)
        overlay.setHovered(true)
        #expect(overlay.model?.hovered == true)
        #expect(overlay.revertShown() == .replaced)
        #expect(sink.document == "Cotari now" && reverted?.status == .reverted && overlay.model == nil)
        rects.rect = nil
        ledger.correction(Self.event("a", "b", at: 0))
        #expect(!overlay.show(ledger.all[1]))
        overlay.isEnabled = { false }; rects.rect = .init(x: 0, y: 0, width: 10, height: 10)
        #expect(!overlay.show(ledger.all[1]))
    }
}

/// Scripted dual-path recognisers: the preview hears one thing, the final another.
final class ScriptedPreview: PreviewRecognizer, @unchecked Sendable {
    let text: String
    init(_ text: String) { self.text = text }
    func feed(_ samples: [Float]) async throws -> String { text }
    func reset() async {}
}
final class ScriptedFinal: FinalRecognizer, @unchecked Sendable {
    let name = "scripted"
    let spans: [TranscriptSpan]
    init(_ spans: [TranscriptSpan]) { self.spans = spans }
    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { spans }
}
struct ScriptedRecognizers: DualPathRecognizers {
    let preview: String; let final: [TranscriptSpan]
    func resolve() async throws -> (preview: PreviewRecognizer, final: FinalRecognizer)? { (ScriptedPreview(preview), ScriptedFinal(final)) }
}

@Suite("P1.5.2 — correction service + lander integration")
struct CorrectionServiceTests {
    static let finalSpans = [
        TranscriptSpan(text: "send", confidence: 0.98, audioRange: 0...0.3),
        TranscriptSpan(text: "Kothari", confidence: 0.95, audioRange: 0.3...0.7),
        TranscriptSpan(text: "now", confidence: 0.97, audioRange: 0.7...1.0),
    ]

    static func service(system: MockSystemAccess, flags: FeatureFlagService = .inMemory([FeatureFlag.dualPath.id: true]),
                        settings: SettingsStore = InMemorySettingsStore(), samples: [Float] = Array(repeating: 0, count: 16_000)) -> CorrectionService {
        CorrectionService(ledger: CorrectionLedger(), flags: flags, settings: settings, readback: InjectionDocumentReadback(system: system),
                          replaceSink: InjectionReplaceRangeSink(system: system),
                          recognizers: ScriptedRecognizers(preview: "send Cotari now", final: finalSpans), samples: { samples })
    }

    @Test func readbackAdapterReadsFocusedValueOrNil() {
        let system = MockSystemAccess()
        system.field = .init(value: "hello")
        #expect(InjectionDocumentReadback(system: system).currentText() == "hello")
        system.axReadable = false
        #expect(InjectionDocumentReadback(system: system).currentText() == nil)
    }

    @Test func reconcileCorrectsPreviewWordInPlaceAndFeedsLedger() async {
        let system = MockSystemAccess()
        system.field = .init(value: "Hi. send Cotari now")
        let svc = Self.service(system: system)
        let events = await svc.reconcile(utteranceID: UUID(), landedText: "send Cotari now", fieldOffset: 4, bundleID: "com.apple.Notes")
        #expect(events.map(\.kind) == [.applied])
        #expect(system.field.value == "Hi. send Kothari now")
        #expect(svc.ledger.all.first?.now == "Kothari" && svc.ledger.all.first?.appBundleID == "com.apple.Notes")
        #expect(svc.ledger.all.first?.range == 9..<16)
    }

    @Test func safetyRuleDowngradesWhenUserTypedOverIt() async {
        let system = MockSystemAccess()
        system.field = .init(value: "send Cotariii now")
        let svc = Self.service(system: system)
        let events = await svc.reconcile(utteranceID: UUID(), landedText: "send Cotari now", fieldOffset: 0, bundleID: nil)
        #expect(events.first?.kind == .suggested(.safetyMismatch))
        #expect(system.field.value == "send Cotariii now")
        #expect(svc.ledger.all.first?.isRevertable == false)
    }

    @Test func gatedByFlagAppSwitchAndAudio() async {
        let system = MockSystemAccess()
        system.field = .init(value: "send Cotari now")
        let off = Self.service(system: system, flags: .inMemory([FeatureFlag.dualPath.id: false]))
        #expect(await off.reconcile(utteranceID: UUID(), landedText: "send Cotari now", fieldOffset: 0, bundleID: nil).isEmpty)
        let settings = InMemorySettingsStore()
        CorrectionSettings.setEnabled(false, for: "com.apple.mail", store: settings)
        let perApp = Self.service(system: system, settings: settings)
        #expect(await perApp.reconcile(utteranceID: UUID(), landedText: "send Cotari now", fieldOffset: 0, bundleID: "com.apple.mail").isEmpty)
        #expect(!perApp.isEnabled(for: "com.apple.mail") && perApp.isEnabled(for: "com.apple.Notes"))
        let silent = Self.service(system: system, samples: [])
        #expect(await silent.reconcile(utteranceID: UUID(), landedText: "send Cotari now", fieldOffset: 0, bundleID: nil).isEmpty)
        #expect(system.field.value == "send Cotari now")
    }

    @Test func landerReconcilesAfterLandingAndPutItBackReverts() async {
        let system = MockSystemAccess()
        system.field = .init(value: "")
        let flags = FeatureFlagService.inMemory([FeatureFlag.dualPath.id: true, FeatureFlag.voiceRepair.id: true])
        let repair = RepairSession(replaceSink: InjectionReplaceRangeSink(system: system))
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: TextInjector(system: system),
                                     system: system, repair: repair, flags: flags, database: nil)
        // The landed (formatted) text stands in as the preview; the accurate pass says Kothari.
        // Case/punctuation-only differences ("Send"/"send", "now."/"now") are dropped by the planner.
        let svc = CorrectionService(ledger: CorrectionLedger(), flags: flags, settings: InMemorySettingsStore(),
                                    readback: InjectionDocumentReadback(system: system), replaceSink: InjectionReplaceRangeSink(system: system),
                                    recognizers: ScriptedRecognizers(preview: "send Cotari now", final: Self.finalSpans),
                                    samples: { Array(repeating: 0, count: 8_000) })
        lander.correction = svc
        lander.reconcileInline = true
        let spans = [TranscriptSpan(text: "send", confidence: 0.9, audioRange: 0...0.3), TranscriptSpan(text: "Cotari", confidence: 0.9, audioRange: 0.3...0.7),
                     TranscriptSpan(text: "now", confidence: 0.9, audioRange: 0.7...1)]
        let r = await lander.land(spans, startedAt: Date(), focus: system.frontmost)
        #expect(r.landed && system.field.value == "Send Kothari now.")
        #expect(svc.ledger.all.count == 1 && svc.ledger.all[0].status == .applied)

        let undo = await lander.land([TranscriptSpan(text: "put it back", confidence: 0.95, audioRange: 1...1.5)], startedAt: Date(), focus: system.frontmost)
        #expect(undo.revertedCorrection?.status == .reverted && undo.injection == nil)
        #expect(system.field.value == "Send Cotari now.")
    }

    @Test func utteranceTapAccumulatesAndResets() {
        let tap = UtteranceAudioTap(maxSeconds: 0.001)  // 16 samples
        tap.append(Array(repeating: 0.5, count: 10)); tap.append(Array(repeating: 0.5, count: 10))
        #expect(tap.samples.count == 16)
        tap.reset()
        #expect(tap.samples.isEmpty)
    }
}
