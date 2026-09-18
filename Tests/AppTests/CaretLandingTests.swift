import Foundation
import Testing
import Injection
import Pipeline
import Shared
@testable import VoicePlusApp

/// D1 three-valued caret through the reader · D4 `renderedText` in the lander · D5 landing memory ·
/// D7 per-app caret capability memory · the D3/D6 settings.
@Suite struct CaretLandingTests {
    static let textEdit = "com.apple.TextEdit"

    /// An app whose focused element exposes text markers (WebKit / Chromium), or not.
    final class MarkerMock: MockSystemAccess, TextMarkerCaretReading {
        var markers: TextMarkerCaret?
        private(set) var markerReads = 0
        func caretByTextMarkers() -> TextMarkerCaret? {
            markerReads += 1
            return markers
        }
    }

    static func mock(_ field: MockSystemAccess.Field = MockSystemAccess.Field(role: "AXTextArea"),
                     bundleID: String = textEdit, token: String = "el-1") -> MarkerMock {
        let mock = MarkerMock(frontmost: FocusSnapshot(pid: 100, bundleID: bundleID, appName: "TextEdit",
                                                      elementToken: token))
        mock.field = field
        return mock
    }

    static func appPipeline() -> PipelineRunner {
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }
        return PipelineRunner(stages: FieldRolePipeline.replacingFormatters(in: builtIn))
    }

    static func lander(_ mock: MockSystemAccess, pipeline: PipelineRunner = appPipeline(),
                       reader: FieldContextReader? = nil,
                       preferences: FormattingPreferences = .default) -> UtteranceLander {
        let lander = UtteranceLander(pipeline: pipeline, injector: TextInjector(system: mock),
                                     system: mock, repair: nil, flags: .inMemory(), database: nil)
        let reader = reader ?? FieldContextReader(system: mock)
        lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
        lander.formattingPreferences = { preferences }
        return lander
    }

    static func words(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.95,
                           audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), provenance: [.asr])
        }
    }

    // MARK: - D1 three-valued caret

    @Test("D1: a value without a range reads unknown, not end of field — and lands with no leading space")
    func valueWithoutRangeIsUnknown() async {
        let mock = Self.mock(MockSystemAccess.Field(role: "AXTextArea", value: "Existing text on the page"))
        mock.axCaretReadable = false
        let reader = FieldContextReader(system: mock)
        let field = reader.fieldContext(bundleID: Self.textEdit)
        #expect(field?.caret == .unknown)
        #expect(reader.lastReading?.rung == CaretRung.none)
        #expect(mock.markerReads == 1)          // the marker rung was tried first

        let result = await Self.lander(mock, reader: reader).land(Self.words("and one more thing"),
                                                                   startedAt: Date(), focus: mock.frontmost)
        #expect(result.caret == .unknown)
        #expect(result.text == "and one more thing")      // no leading space, no invented capital or period
        #expect(!result.text.hasPrefix(" "))
    }

    @Test("D1: the marker rung answers known where the range is missing")
    func markerRangeAnswersKnown() {
        let mock = Self.mock(MockSystemAccess.Field(role: "AXTextArea", value: "stale"))
        mock.axCaretReadable = false
        mock.markers = TextMarkerCaret(before: "The quick brown", after: " jumps over")
        let reader = FieldContextReader(system: mock)
        #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret == .known(before: "The quick brown", after: " jumps over"))
        #expect(reader.lastReading?.rung == .textMarkers)

        mock.markers = TextMarkerCaret(before: "Done.", after: "")
        #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret == .endOfField(before: "Done."))
    }

    @Test("D1: the range rung comes first and does not pay for the marker round-trip")
    func rangeRungFirst() {
        let mock = Self.mock(MockSystemAccess.Field(role: "AXTextArea", value: "Hello", selection: 5..<5))
        mock.markers = TextMarkerCaret(before: "wrong", after: "wrong")
        let reader = FieldContextReader(system: mock)
        #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret == .endOfField(before: "Hello"))
        #expect(reader.lastReading?.rung == .selectedRange)
        #expect(mock.markerReads == 0)
    }

    @Test("D1: a secure field is refused as before, and nothing around its caret is read", arguments: [false, true])
    func secureFieldRefused(webStyle: Bool) async {
        let mock = Self.mock(.secure(webStyle: webStyle))
        mock.markers = TextMarkerCaret(before: "hunter", after: "")
        let reader = FieldContextReader(system: mock)
        let field = reader.fieldContext(bundleID: Self.textEdit)
        #expect(field?.caret == .unknown)
        #expect(mock.markerReads == 0)
        let result = await Self.lander(mock, reader: reader).land(Self.words("hunter two"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.fieldRole == .secure)
        #expect(result.injection == .refused(.secureField))
        #expect(result.text.isEmpty)
        #expect(mock.postCount == 0)
        #expect(reader.landingMemory.last == nil)
    }

    @Test("D1: no readable element — the run is unknown and StyleStage is off")
    func noElementIsUnknown() async {
        let mock = Self.mock()
        mock.hasFocusedElement = false
        let styleOnly = PipelineRunner(stages: [StyleStage()])
        let lander = Self.lander(mock, pipeline: styleOnly)
        lander.contextAugmenter = { _, ctx in
            var ctx = ctx
            var profile = StyleProfile.coldStart(appBundleID: Self.textEdit, category: .prose)
            profile.capitalizationRate = 1
            profile.terminalPeriodRate = 1
            ctx.extra[StyleStage.profileJSONKey] = try? profile.encodedJSON()
            return ctx
        }
        let result = await lander.land(Self.words("we left"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.caret == .unknown)
        #expect(result.fieldRole == nil)
        #expect(result.text == "we left")                 // no learned capital or period at an unknown caret

        // Without a wired reader (no caret reading at all) the learned style still applies.
        let legacy = UtteranceLander(pipeline: styleOnly, injector: TextInjector(system: mock), system: mock,
                                     repair: nil, flags: .inMemory(), database: nil)
        legacy.contextAugmenter = lander.contextAugmenter
        let old = await legacy.land(Self.words("we left"), startedAt: Date(), focus: mock.frontmost)
        #expect(old.caret == nil)
        #expect(old.text == "We left.")
    }

    // MARK: - D4 renderedText

    /// Blanks spans the way the formatter's filler removal and the ITN collapse do.
    struct Rewrite: PipelineStage {
        let id: StageID = "test.rewrite"
        let texts: [String]
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            spans.enumerated().map { i, s in s.rewritten(i < texts.count ? texts[i] : s.text, by: id) }
        }
    }

    static func plainLander(_ mock: MockSystemAccess, rewrite: [String]) -> UtteranceLander {
        UtteranceLander(pipeline: PipelineRunner(stages: [Rewrite(texts: rewrite)]), injector: TextInjector(system: mock),
                        system: mock, repair: nil, flags: .inMemory(), database: nil)
    }

    @Test("D4: a filler-removed first span leaves no leading space")
    func fillerRemovedFirstSpan() async {
        let mock = Self.mock()
        let lander = Self.plainLander(mock, rewrite: ["", "Send", "it", "now."])
        let result = await lander.land(Self.words("um send it now"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.text == "Send it now.")
        #expect(mock.field.value == "Send it now.")
    }

    @Test("D4: ITN-collapsed spans join with single spaces")
    func itnCollapsedSpans() async {
        let mock = Self.mock()
        let lander = Self.plainLander(mock, rewrite: ["It", "costs", "$25", "", " ", "today."])
        let result = await lander.land(Self.words("it costs twenty five dollars today"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.text == "It costs $25 today.")
        #expect(!result.text.contains("  "))
    }

    @Test("D4: the act-claim path renders too")
    func actClaimRenders() async {
        let mock = Self.mock()
        let lander = Self.plainLander(mock, rewrite: ["", "open", "", "mail"])
        lander.actClaimConsumer = { true }
        let result = await lander.land(Self.words("um open uh mail"), startedAt: Date(), focus: mock.frontmost)
        #expect(result.text == "open mail")
        #expect(mock.postCount == 0)
    }

    // MARK: - D5 landing memory

    static func caretlessApp() -> MarkerMock {
        let mock = Self.mock(MockSystemAccess.Field(role: "AXTextArea", value: ""))
        mock.axCaretReadable = false            // value readable, caret not: the Chromium shape
        return mock
    }

    @Test("D5: two landings in a caretless field — the second joins onto the first")
    func secondLandingJoins() async {
        let mock = Self.caretlessApp()
        let reader = FieldContextReader(system: mock)
        let lander = Self.lander(mock, reader: reader)
        let first = await lander.land(Self.words("send the report"), startedAt: Date(), focus: mock.frontmost)
        #expect(first.landed)
        #expect(first.caret == .unknown)
        #expect(first.text == "send the report")
        #expect(reader.landingMemory.last?.ending == .word)

        let second = await lander.land(Self.words("and the invoice"), startedAt: Date(), focus: mock.frontmost)
        #expect(second.caret == .known)
        #expect(reader.lastReading?.rung == .landingMemory)
        #expect(second.text == " and the invoice")
        #expect(mock.field.value == "send the report and the invoice")
    }

    @Test("D5: after a sentence end the next landing gets a space and a capital")
    func joinsAfterTerminal() async {
        let mock = Self.caretlessApp()
        let lander = Self.lander(mock)
        let first = await lander.land(Self.words("The report is ready."), startedAt: Date(), focus: mock.frontmost)
        #expect(first.text == "The report is ready.")
        #expect(lander.landingMemory.last?.ending == .terminal)
        let second = await lander.land(Self.words("send it today please"), startedAt: Date(), focus: mock.frontmost)
        #expect(second.text == " Send it today please.")
    }

    @Test("D5: a click between landings makes the caret unknown again", arguments: LandingInvalidation.allCases)
    func inputBetweenInvalidates(reason: LandingInvalidation) async {
        let mock = Self.caretlessApp()
        let reader = FieldContextReader(system: mock)
        let lander = Self.lander(mock, reader: reader)
        _ = await lander.land(Self.words("send the report"), startedAt: Date(), focus: mock.frontmost)
        reader.landingMemory.invalidate(reason)          // the live monitor delivers these
        #expect(reader.landingMemory.lastInvalidation == reason)
        let second = await lander.land(Self.words("and the invoice"), startedAt: Date(), focus: mock.frontmost)
        #expect(second.caret == .unknown)
        #expect(second.text == "and the invoice")
    }

    @Test("D5: the memory belongs to one element and lasts 30 s")
    func elementAndLifetime() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let memory = LandingMemory(clock: { clock.now })
        let element = LandedElement(bundleID: Self.textEdit, role: "AXTextArea", elementToken: "el-1")
        memory.record(text: "Hello there", in: element)
        #expect(memory.caret(for: element) == .known(before: "Hello there", after: ""))
        #expect(memory.caret(for: LandedElement(bundleID: Self.textEdit, role: "AXTextArea", elementToken: "el-2")) == nil)
        #expect(memory.caret(for: LandedElement(bundleID: "com.apple.Notes", role: "AXTextArea", elementToken: "el-1")) == nil)
        #expect(memory.caret(for: LandedElement(bundleID: Self.textEdit, role: "AXTextField", elementToken: "el-1")) == nil)
        clock.now += 29
        #expect(memory.caret(for: element) != nil)
        clock.now += 1.5
        #expect(memory.caret(for: element) == nil)
        #expect(memory.last == nil)
        // Empty text is not a landing; an element without an AX hash cannot be remembered.
        memory.record(text: "", in: element)
        #expect(memory.last == nil)
        #expect(LandedElement(focus: FocusSnapshot(pid: 1, bundleID: "x", elementToken: nil), role: nil) == nil)
    }

    @Test("D5: ending classes")
    func endingClasses() {
        #expect(LandingEnding(of: "send the report") == .word)
        #expect(LandingEnding(of: "send the report, ") == .space)
        #expect(LandingEnding(of: "Done.") == .terminal)
        #expect(LandingEnding(of: "Really?") == .terminal)
        #expect(LandingEnding(of: "and so on etc.") == .word)
        #expect(LandingEnding(of: "") == nil)
    }

    /// Stands in for the NSEvent monitors.
    final class FakeMonitor: LandingInputMonitor {
        var handler: (@Sendable (LandingInvalidation) -> Void)?
        var refreshes = 0
        var stopped = false
        func start(_ handler: @escaping @Sendable (LandingInvalidation) -> Void) { self.handler = handler }
        func stop() { stopped = true }
        func refresh() { refreshes += 1 }
    }

    @Test("D5: monitor events invalidate, and every landing lets the monitor pick up new permission")
    func monitorWiring() {
        let memory = LandingMemory()
        let monitor = FakeMonitor()
        memory.startMonitoring(monitor)
        #expect(memory.isMonitoring)
        let element = LandedElement(bundleID: Self.textEdit, role: nil, elementToken: "el-1")
        memory.record(text: "hello", in: element)
        #expect(monitor.refreshes == 1)
        monitor.handler?(.keyDown)
        #expect(memory.caret(for: element) == nil)
        #expect(memory.lastInvalidation == .keyDown)
        memory.stopMonitoring()
        #expect(monitor.stopped)
    }

    @Test("D5: the reader and the lander over one SystemAccess share one memory; a mock is not monitored")
    func sharedMemory() {
        let mock = Self.mock()
        let lander = Self.lander(mock)
        #expect(FieldContextReader(system: mock).landingMemory === lander.landingMemory)
        #expect(LandingMemory.attached(to: Self.mock()) !== lander.landingMemory)
        #expect(!lander.landingMemory.isMonitoring)
    }

    // MARK: - D7 per-app caret capability memory

    @Test("D7: five caretless landings in an app skip the marker round-trip; landing memory still answers")
    func capabilityCounter() {
        let mock = Self.caretlessApp()
        let reader = FieldContextReader(system: mock)
        for i in 1...5 {
            #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret == .unknown)
            #expect(reader.capabilities.misses(for: Self.textEdit) == i)
        }
        #expect(mock.markerReads == 5)
        #expect(reader.capabilities.shouldSkipAXRoundTrip(bundleID: Self.textEdit))
        _ = reader.fieldContext(bundleID: Self.textEdit)
        #expect(mock.markerReads == 5)                      // skipped
        // Straight to landing memory.
        reader.landingMemory.record(text: "hello there", in: LandedElement(bundleID: Self.textEdit, role: "AXTextArea", elementToken: "el-1"))
        #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret == .known(before: "hello there", after: ""))
        #expect(reader.lastReading?.rung == .landingMemory)
        #expect(mock.markerReads == 5)
        // Another app is unaffected.
        #expect(!reader.capabilities.shouldSkipAXRoundTrip(bundleID: "com.apple.Notes"))
    }

    @Test("D7: a rung answering resets the count")
    func capabilityReset() {
        let mock = Self.caretlessApp()
        let reader = FieldContextReader(system: mock)
        for _ in 1...5 { _ = reader.fieldContext(bundleID: Self.textEdit) }
        #expect(reader.capabilities.shouldSkipAXRoundTrip(bundleID: Self.textEdit))
        // The free range rung answers (the app fixed its accessibility, or this field has a caret).
        mock.axCaretReadable = true
        #expect(reader.fieldContext(bundleID: Self.textEdit)?.caret.hasCaret == true)
        #expect(reader.capabilities.misses(for: Self.textEdit) == 0)
        mock.axCaretReadable = false
        _ = reader.fieldContext(bundleID: Self.textEdit)
        #expect(mock.markerReads == 6)                      // tried again

        // A marker answer resets too.
        for _ in 1...3 { _ = reader.fieldContext(bundleID: Self.textEdit) }
        #expect(reader.capabilities.misses(for: Self.textEdit) == 4)
        mock.markers = TextMarkerCaret(before: "x", after: "")
        _ = reader.fieldContext(bundleID: Self.textEdit)
        #expect(reader.capabilities.misses(for: Self.textEdit) == 0)
    }

    @Test("D7: the counter itself")
    func counterUnit() {
        let memory = CaretCapabilityMemory()
        #expect(memory.threshold == 5)
        for _ in 1...4 { memory.note(bundleID: "a", answered: false) }
        #expect(!memory.shouldSkipAXRoundTrip(bundleID: "a"))
        memory.note(bundleID: "a", answered: false)
        #expect(memory.shouldSkipAXRoundTrip(bundleID: "a"))
        memory.note(bundleID: "a", answered: false)
        #expect(memory.misses(for: "a") == 5)               // capped
        memory.note(bundleID: "a", answered: true)
        #expect(memory.misses(for: "a") == 0)
        #expect(!memory.shouldSkipAXRoundTrip(bundleID: "a"))
    }

    // MARK: - D3 / D6 settings

    @Test("D3/D6: settings keys, defaults and round trip")
    func settings() {
        let store = InMemorySettingsStore()
        #expect(FormattingSettings.preferences(store) == .default)
        #expect(FormattingSettings.preferences(nil) == .default)
        FormattingSettings.setSpacing(.never, store: store)
        FormattingSettings.setUnknownCaretStyle(.asSpoken, store: store)
        #expect(store.string("formatting.spacing") == "never")
        #expect(store.string("formatting.unknownCaretStyle") == "asSpoken")
        #expect(FormattingSettings.preferences(store) == FormattingPreferences(spacing: .never, unknownCaretStyle: .asSpoken))
        store.set("sideways", for: SettingsKeys.formattingSpacing)
        #expect(FormattingSettings.spacing(store) == .automatic)
        #expect(FormattingSettings.allKeys == ["formatting.spacing", "formatting.unknownCaretStyle"])
    }

    @Test("D6: the lander applies the spacing setting")
    func landerSpacing() async {
        let value = "I think"
        let end = value.utf16.count
        for (spacing, expected) in [(SpacingPreference.automatic, " we should go"), (.always, " we should go"), (.never, "we should go")] {
            let mock = Self.mock(MockSystemAccess.Field(role: "AXTextArea", value: value, selection: end..<end))
            let lander = Self.lander(mock, preferences: FormattingPreferences(spacing: spacing))
            let result = await lander.land(Self.words("we should go"), startedAt: Date(), focus: mock.frontmost)
            #expect(result.text == expected, "\(spacing)")
        }
    }
}
