import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// B3 (V4.37) — field context in the latch path. A latch segment lands through
/// `UtteranceLander.land` (field rules, continuation, rendering) whether it is delivered or held;
/// held text used to be `spans.joinedText`, raw.
///
/// The stack is the production one (`LanderLatchDelivery` → `UtteranceLander` with the app's
/// field-role pipeline and `FieldContextReader` → injector → `FocusGuard`) over `MockSystemAccess`;
/// the injector is a spy where the test is about what reached it.
@Suite("Latch segments land through the lander (B3)")
@MainActor
struct LatchLanderPathTests {
    nonisolated static let textEdit = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")
    nonisolated static let mail = FocusSnapshot(pid: 200, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-2")

    struct Stack {
        let system: MockSystemAccess
        let injector: any Injector
        let focusGuard: FocusGuard
        let lander: UtteranceLander
        let delivery: LanderLatchDelivery
        let runtime: LatchRuntime

        init(field: MockSystemAccess.Field = MockSystemAccess.Field(role: "AXTextArea"), spy: Bool = true) {
            system = MockSystemAccess(frontmost: LatchLanderPathTests.textEdit)
            system.field = field
            let real = TextInjector(system: system)
            injector = spy ? LatchSpyInjector() : real
            focusGuard = real.focusGuard
            let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }
            lander = UtteranceLander(pipeline: PipelineRunner(stages: FieldRolePipeline.replacingFormatters(in: builtIn)),
                                     injector: injector, system: system, repair: nil, flags: .inMemory(), database: nil)
            let reader = FieldContextReader(system: system)
            lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
            let guardRef = focusGuard
            delivery = LanderLatchDelivery(lander: lander, focusGuard: focusGuard, focusSnapshot: { guardRef.snapshot() })
            runtime = LatchRuntime(delivery: delivery)
            runtime.isLatched = { true }
            runtime.feedQueue = { $0() }
        }

        var requests: [InjectionRequest] { (injector as? LatchSpyInjector)?.requests ?? [] }

        /// What the lander lands for these words in this field, straight — the reference output.
        /// `unknownCaret`: as it lands where no field can be read (D1's unknown caret), which is
        /// what a destination that no longer has focus is.
        func landed(_ spans: [TranscriptSpan], focus: FocusSnapshot? = nil, unknownCaret: Bool = false) async -> String {
            let reference = UtteranceLander(pipeline: lander.pipeline, injector: LatchSpyInjector(), system: system,
                                            repair: nil, flags: .inMemory(), database: nil)
            reference.formattingPreferences = lander.formattingPreferences
            reference.fieldContextProvider = unknownCaret ? { _ in nil } : lander.fieldContextProvider
            return await reference.land(spans, startedAt: Date(), focus: focus ?? system.frontmost).text
        }
    }

    static let session = UUID()
    static func spans(_ parts: [String]) -> [TranscriptSpan] {
        parts.map { TranscriptSpan(text: $0, confidence: 0.9, audioRange: 0...1, provenance: [.asr], stability: .committed) }
    }
    static func closed(_ index: Int, _ spans: [TranscriptSpan]) -> SegmentEvent {
        .closed(segment: SegmentID(sessionID: session, index: index), spans: spans, stability: .committed, reason: .endpoint)
    }

    // MARK: delivered

    @Test("a latch segment is delivered through the lander, formatted, to the focus at close")
    func deliveredThroughTheLander() async {
        let stack = Stack()
        let words = Self.spans(["hello there", "", "from the office"])
        let expected = await stack.landed(words)
        #expect(expected != words.joinedText, "the reference did not format anything — the test proves nothing")

        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.requests.map(\.text) == [expected], "the latch posted something other than the lander's text")
        #expect(stack.requests.first?.expectedFocus == Self.textEdit)
        #expect(stack.runtime.outcomes.first?.outcome == .delivered(words.renderedText))
    }

    @Test("field rules reach latch segments: a terminal gets no capital and no period")
    func terminalRulesInLatch() async {
        let stack = Stack(field: MockSystemAccess.Field(role: "AXTextArea", hints: ["Terminal input"]))
        stack.runtime.handle(Self.closed(0, Self.spans(["git status"])))
        await stack.runtime.settle()
        let text = stack.requests.first?.text ?? ""
        #expect(!text.isEmpty)
        #expect(text.lowercased() == text)
        #expect(!text.hasSuffix("."))
    }

    @Test("continuation reaches latch segments: mid-sentence text gets a leading space and no capital")
    func continuationInLatch() async {
        let value = "The quick brown jumps over"
        let caret = "The quick brown".utf16.count
        let stack = Stack(field: MockSystemAccess.Field(role: "AXTextArea", value: value, selection: caret..<caret))
        let words = Self.spans(["and dusty"])
        let expected = await stack.landed(words)
        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.requests.first?.text == expected)
        #expect(stack.requests.first?.text.hasPrefix(" ") == true, "fused with the word before the caret")
        #expect(stack.requests.first?.text.first(where: { $0 != " " })?.isUppercase == false)
    }

    // MARK: held — the path that used to be raw

    @Test("a segment held for a focus change is the lander's text, not the raw join, and is never posted")
    func heldTextIsFormatted() async {
        let stack = Stack()
        let words = Self.spans(["um so", "", "meet me at three thirty"])
        // The words were meant for TextEdit, which no longer has focus when they are held: its
        // field cannot be read, so they are formatted for an unknown caret (D1), by the lander.
        let expected = await stack.landed(words, unknownCaret: true)
        #expect(expected != words.renderedText, "the lander did not format anything — the test proves nothing")

        // Speech begins in TextEdit…
        stack.runtime.handle(.opened(SegmentID(sessionID: Self.session, index: 0)))
        stack.runtime.noteVAD(.speechStart(at: 0.2))
        // …and focus moves to Mail before the segment closes.
        stack.system.frontmost = Self.mail
        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()

        #expect(stack.requests.isEmpty, "held text was posted")
        #expect(stack.focusGuard.held.count == 1)
        let item = stack.focusGuard.held.first
        #expect(item?.text == expected, "held text is not what the lander would have landed")
        #expect(item?.text != words.joinedText, "held text is the raw join")
        #expect(item?.reason == DeliveryReason.destinationChanged)
        #expect(item?.destinationName == "TextEdit", "held for the app the speech began in")
        #expect(item?.segmentID == SegmentID(sessionID: Self.session, index: 0))
        #expect(stack.runtime.outcomes.first?.outcome == .held(destination: "TextEdit", reason: DeliveryReason.destinationChanged))
    }

    @Test("a segment held while delivery is paused is formatted too, and names where it waits")
    func pausedHoldIsFormatted() async {
        let stack = Stack()
        let words = Self.spans(["meet me at noon"])
        let expected = await stack.landed(words)
        stack.runtime.pauseDelivery(awaiting: "TextEdit")
        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.requests.isEmpty)
        #expect(stack.focusGuard.held.map(\.text) == [expected])
        #expect(stack.focusGuard.held.first?.reason == LatchReason.awaitingNamedDestination)
        #expect(stack.runtime.outcomes.first?.outcome == .held(destination: "TextEdit", reason: LatchReason.awaitingNamedDestination))
    }

    @Test("an injector abort is held once, formatted — not held again raw")
    func injectorAbortIsHeldOnce() async {
        let stack = Stack(spy: false)
        let words = Self.spans(["see you there"])
        let expected = await stack.landed(words, focus: Self.mail)
        // The snapshot at close names Mail; TextEdit has focus when the injector checks.
        stack.delivery.focusSnapshot = { Self.mail }
        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.system.postCount == 0)
        #expect(stack.focusGuard.held.count == 1, "held \(stack.focusGuard.held.count) times")
        #expect(stack.focusGuard.held.first?.text == expected)
        #expect(stack.runtime.outcomes.first?.outcome == .held(destination: "Mail", reason: DeliveryReason.destinationChanged))
    }

    @Test("a password field refuses a latch segment: nothing typed, nothing kept")
    func secureFieldRefuses() async {
        let stack = Stack(field: .secure())
        stack.runtime.handle(Self.closed(0, Self.spans(["hunter two"])))
        await stack.runtime.settle()
        #expect(stack.requests.isEmpty)
        #expect(stack.focusGuard.held.isEmpty, "a secret was kept as held text")
        #expect(stack.runtime.outcomes.first?.outcome == .refused(DeliveryReason.secureField))
    }

    @Test("held text is formatted without the new app's field: its field context is not read")
    func heldTextIgnoresTheNewAppsField() async {
        let stack = Stack()
        let words = Self.spans(["hello there"])
        let expected = await stack.landed(words, unknownCaret: true)
        stack.runtime.handle(.opened(SegmentID(sessionID: Self.session, index: 0)))
        stack.runtime.noteVAD(.speechStart(at: 0.2))
        // Mail takes focus, with the caret right after a word: its field would add a leading space.
        stack.system.frontmost = Self.mail
        stack.system.field = MockSystemAccess.Field(role: "AXTextArea", value: "Dear Bob", selection: 8..<8)
        let mailWouldLand = await stack.landed(words, focus: Self.mail)
        #expect(mailWouldLand != expected, "Mail's field changes nothing — the test proves nothing")
        #expect(mailWouldLand.hasPrefix(" "))

        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.focusGuard.held.first?.text == expected, "held text took the new app's field rules")
        #expect(stack.focusGuard.held.first?.text.hasPrefix(" ") == false)
    }

    @Test("a hold without a field reader keeps the lander's plain path")
    func holdWithoutAFieldReader() async {
        let stack = Stack()
        stack.lander.fieldContextProvider = nil
        let words = Self.spans(["hello there", "", "from the office"])
        let expected = await stack.landed(words)
        stack.runtime.pauseDelivery(awaiting: "TextEdit")
        stack.runtime.handle(Self.closed(0, words))
        await stack.runtime.settle()
        #expect(stack.focusGuard.held.map(\.text) == [expected])
    }
}
