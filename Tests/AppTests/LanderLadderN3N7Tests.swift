import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// N3 (lander half) — an unreadable field is not "no field": the delivery ladder decides, so a
/// fake unreadable Chromium composer gets a write; Notes only when there is no window.
/// N7 (lander half) — the landing's context step reads the turn snapshot, so a 10 s source still
/// lands in about 400 ms, and the time is reported for stage_ms.
@Suite("N3/N7 lander: delivery ladder + bounded context")
@MainActor
struct LanderLadderN3N7Tests {
    typealias Stack = LatchLanderPathTests.Stack

    struct Notes {
        let root: URL
        let store: NotesStore
        let router: NotesRouter
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("n3-\(UUID().uuidString)", isDirectory: true)
            store = NotesStore(root: root, database: try AppDatabase.inMemory())
            router = NotesRouter(store: store)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func wire(_ stack: Stack, _ notes: Notes) {
        stack.lander.notesClaim = NotesWiring.landingClaim(notes.router, latched: { false },
                                                           meetingActive: { false }, agentRunning: { false })
    }

    private func land(_ stack: Stack, _ text: String) async -> LandingResult {
        await stack.lander.land(LatchLanderPathTests.spans([text]), startedAt: Date(), focus: stack.system.frontmost)
    }

    @Test("unreadable field (Chromium, AX off) with a window: written, not noted, unverified keystrokes")
    func unreadableFieldWithWindowGetsAWrite() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack()
        stack.system.hasFocusedElement = false      // ChatGPT before its accessibility tree is on
        stack.system.focusedWindow = "w1"
        wire(stack, notes)
        let result = await land(stack, "draft the reply to the team")
        #expect(result.noted == nil)
        #expect(stack.requests.count == 1)
        #expect(notes.store.notes().isEmpty)
        #expect(result.ladder == .deliver(method: .keystrokes, verify: false))
    }

    @Test("multi-line text into an unreadable field: the ladder picks paste (no Return key)")
    func multilineUnreadablePastes() {
        let stack = Stack()
        stack.system.focusedWindow = "w1"
        let decision = stack.lander.unreadableFieldLadder(focus: stack.system.frontmost, multiline: true)
        #expect(decision == .deliver(method: .paste, verify: false))
    }

    @Test("no window at all: Notes keeps it (no destination), nothing typed")
    func noWindowGoesToNotes() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack()
        stack.system.hasFocusedElement = false
        stack.system.focusedWindow = nil
        wire(stack, notes)
        let result = await land(stack, "buy milk on the way home")
        #expect(result.noted == .noField)
        #expect(stack.requests.isEmpty)
        #expect(result.ladder == .notes(.noWindow))
    }

    @Test("cannot tell whether there is a window: neutral, delivered (never Notes on unknown)")
    func unknownWindowDelivers() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack()
        stack.system.hasFocusedElement = false
        stack.lander.windowPresence = { _ in nil }
        wire(stack, notes)
        let result = await land(stack, "see you at noon")
        #expect(result.noted == nil)
        #expect(stack.requests.count == 1)
    }

    @Test("a readable field never consults the window probe")
    func readableFieldSkipsLadder() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack()
        var probed = false
        stack.lander.windowPresence = { _ in probed = true; return false }
        wire(stack, notes)
        let result = await land(stack, "meet me at noon")
        #expect(result.ladder == nil)
        #expect(!probed)
        #expect(stack.requests.count == 1)
    }

    @Test("N7: a 10 s context source through the turn snapshot lands in about 400 ms")
    func tenSecondSourceLandsBounded() async {
        let stack = Stack()
        let reader = SlowTurnReader(delay: 10)
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        let text = AXReaderWindowText(system: stack.system)
        text.snapshot = snapshot
        stack.lander.contextAugmenter = { _, ctx in
            var ctx = ctx
            ctx.extra["window"] = text.windowText() ?? ""
            return ctx
        }
        let started = Date()
        #expect(snapshot.start(app: stack.system.frontmost))
        let result = await land(stack, "ship it on friday")
        let elapsed = Date().timeIntervalSince(started)
        // The context step itself is the bound (~250 ms budget + slack); the whole landing is far
        // from the source's 10 s even when the pipeline runs under a loaded parallel test run.
        #expect(result.contextMs < 450)
        #expect(elapsed < 9)       // never waits out the source
        #expect(stack.requests.count == 1)
        #expect(reader.calls == 1)      // one read for the turn, never a second walk at landing
        snapshot.end()
    }

    @Test("N7: stage_ms carries the context step")
    func contextStageName() {
        var extras = TurnRecordExtras()
        extras.setStage(TurnRecordExtras.Stage.context, ms: 12)
        #expect(extras.stageMs?["context"] == 12)
    }
}

private final class SlowTurnReader: TurnContextReading, @unchecked Sendable {
    let delay: TimeInterval
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(delay: TimeInterval) { self.delay = delay }
    func read(target: TurnContextTarget, deadline: Date, cancellation: AXReadCancellation) -> TurnContextContents? {
        lock.withLock { count += 1 }
        Thread.sleep(forTimeInterval: delay)      // ignores its deadline
        return nil
    }
}
