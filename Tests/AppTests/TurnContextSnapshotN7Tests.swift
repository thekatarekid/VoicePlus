import Foundation
import Injection
import Testing
@testable import VoicePlusApp

// MARK: - N7 — one bounded turn snapshot: key-down start, ~250 ms, bound to the start app, rule first

private final class MockTurnReader: TurnContextReading {
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private var _targets: [TurnContextTarget] = []
    var targets: [TurnContextTarget] { lock.lock(); defer { lock.unlock() }; return _targets }
    func read(target: TurnContextTarget, deadline: Date, cancellation: AXReadCancellation) -> TurnContextContents? {
        lock.lock(); _targets.append(target); lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }     // a source that ignores its deadline
        let content = WindowContent(window: AXWindowID(pid: target.pid, windowNumber: 1), title: "Q3 plan — Notes",
                                    blocks: [TextBlock(role: "AXStaticText", text: "Ask Priya Sharma about deck.key",
                                                       visibleRange: nil, totalCharacters: 31, depth: 2)],
                                    truncated: false, nodesVisited: 3, readAt: Date())
        return TurnContextContents(target: target, content: content, documentTail: "tail text", startedAt: Date(), readMs: 1)
    }
}

private let notes = FocusSnapshot(pid: 100, bundleID: "com.apple.Notes", appName: "Notes")
private let slack = FocusSnapshot(pid: 200, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")

@Suite("N7 turn context snapshot")
struct TurnContextSnapshotN7Tests {
    @Test func aTenSecondSourceLandsInAboutFourHundredMilliseconds() {
        let reader = MockTurnReader()
        reader.delay = 10
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        let started = Date()
        #expect(snapshot.start(app: notes))
        guard case .contents(let contents) = snapshot.lookup(frontmost: notes) else { Issue.record("expected a turn"); return }
        let elapsed = Date().timeIntervalSince(started)
        #expect(contents == nil)
        #expect(elapsed < 0.45)
        #expect(snapshot.lastStats?.timedOutWaiting == true)
    }

    @Test func slowAXTreeThroughTheRealReaderLandsBounded() {
        let system = MockSystemAccess(frontmost: notes)
        let tree = system.mockAXTree
        let kids = (0..<2_000).map { MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: "row \($0)")]) }
        tree.addWindow(AXWindowID(pid: notes.pid, windowNumber: 1), root: MockAXNode(role: "AXWindow", title: "Long note", children: kids))
        tree.perNodeDelay = 0.0025      // ≈ 10 s for the whole tree unbounded
        let snapshot = TurnContextSnapshot(reader: AXTurnContextReader(reader: system.axReader), contextualReading: { _ in true })
        let text = AXReaderWindowText(system: system)
        text.snapshot = snapshot
        let started = Date()
        snapshot.start(app: notes)
        let strings = text.visibleStrings()
        #expect(Date().timeIntervalSince(started) < 0.45)
        #expect(strings.first?.0 == "Long note")
        #expect(snapshot.lastStats?.interrupted == true)
    }

    @Test func noReadWhenContextualReadingIsOff() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { $0 != notes.bundleID })
        #expect(!snapshot.start(app: notes))
        #expect(snapshot.readsStarted == 0)
        #expect(snapshot.currentPhase == .skipped("contextualReadingOff"))
        guard case .contents(let c) = snapshot.lookup(frontmost: notes) else { Issue.record("turn expected"); return }
        #expect(c == nil)
        #expect(reader.targets.isEmpty)
    }

    @Test func consumersDoNotFallBackToALiveReadWhenTheRuleIsOff() {
        let system = MockSystemAccess(frontmost: notes)
        system.mockAXTree.addWindow(AXWindowID(pid: notes.pid, windowNumber: 1),
                                    root: MockAXNode(role: "AXWindow", title: "Secret", children: []))
        let snapshot = TurnContextSnapshot(reader: AXTurnContextReader(reader: system.axReader), contextualReading: { _ in false })
        let text = AXReaderWindowText(system: system)
        text.snapshot = snapshot
        snapshot.start(app: notes)
        #expect(text.visibleStrings().isEmpty)
        #expect(text.windowText() == nil)
        #expect((system.axReader as? CachedAXReader)?.walksStarted == 0)
    }

    @Test func readIsBoundToTheStartingApp() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        snapshot.start(app: notes)
        _ = snapshot.lookup(frontmost: notes)
        #expect(reader.targets.map(\.pid) == [notes.pid])
        #expect(snapshot.currentTarget?.window == AXWindowID(pid: notes.pid, windowNumber: 1))
    }

    @Test func appSwitchDiscardsAndNeverReadsTheNewApp() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        snapshot.start(app: notes)
        guard case .contents(let c) = snapshot.lookup(frontmost: slack) else { Issue.record("turn expected"); return }
        #expect(c == nil)
        #expect(snapshot.currentPhase == .discarded("appChanged"))
        guard case .contents(let again) = snapshot.lookup(frontmost: notes) else { Issue.record("turn expected"); return }
        #expect(again == nil)
        #expect(!reader.targets.contains { $0.pid == slack.pid })
    }

    @Test func endReturnsToNoTurnAndAFreshStartReadsAgain() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        snapshot.start(app: notes)
        guard case .contents(let c) = snapshot.lookup(frontmost: notes) else { Issue.record("turn expected"); return }
        #expect(c?.content.title == "Q3 plan — Notes")
        snapshot.end()
        guard case .noTurn = snapshot.lookup(frontmost: notes) else { Issue.record("no turn expected"); return }
        snapshot.start(app: notes)
        _ = snapshot.lookup(frontmost: notes)
        #expect(reader.targets.count == 2)
    }

    @Test func allConsumersShareOneWalkDuringATurn() {
        let system = MockSystemAccess(frontmost: notes)
        let kids = (0..<20).map { MockAXNode(role: "AXStaticText", value: "line \($0) report.pdf") }
        system.mockAXTree.addWindow(AXWindowID(pid: notes.pid, windowNumber: 1),
                                    root: MockAXNode(role: "AXWindow", title: "Inbox", children: kids))
        let snapshot = TurnContextSnapshot(reader: AXTurnContextReader(reader: system.axReader), contextualReading: { _ in true })
        let text = AXReaderWindowText(system: system)
        text.snapshot = snapshot
        snapshot.start(app: notes)
        let referents = AXReferentContext(text: text)
        _ = text.visibleStrings(); _ = text.windowText(); _ = referents.visibleArtifacts(); _ = text.candidates()
        // one visible walk + one tail walk (the shared reader), then everything is served from the snapshot
        #expect(((system.axReader as? CachedAXReader)?.walksStarted ?? 99) <= 2)
        #expect(referents.visibleArtifacts().contains { $0.title == "Inbox" })
    }

    @Test func candidatesAreTypedAndCapped() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        snapshot.start(app: notes)
        guard case .contents(let c?) = snapshot.lookup(frontmost: notes) else { Issue.record("contents expected"); return }
        let candidates = c.candidates(cap: 3)
        #expect(candidates.count <= 3)
        #expect(c.candidates().contains { $0.source == .title })
    }

    @Test func classifierSortsTermsIntoRubricClasses() {
        #expect(TurnContextContents.classify("report.pdf") == .file)
        #expect(TurnContextContents.classify("github.com") == .link)
        #expect(TurnContextContents.classify("https://x.dev/a") == .link)
        #expect(TurnContextContents.classify("useState") == .tech)
        #expect(TurnContextContents.classify("XLOOKUP") == .tech)
        #expect(TurnContextContents.classify("snake_case") == .tech)
        #expect(TurnContextContents.classify("Priya Sharma") == .name)
        #expect(TurnContextContents.classify("meeting") == .word)
    }

    @Test func ownProcessIsNeverRead() {
        let reader = MockTurnReader()
        let snapshot = TurnContextSnapshot(reader: reader, contextualReading: { _ in true })
        #expect(!snapshot.start(app: FocusSnapshot(pid: OwnProcess.pid, bundleID: "x")))
        #expect(reader.targets.isEmpty)
    }

    // N7 verify — a late end of turn 1 must not reset the snapshot a latched turn 2 started.
    @Test func leaseResetsOnlyWhenTheLastOpenTurnEnds() {
        let lease = TurnContextLease()
        lease.begin()          // turn 1 key-down
        lease.begin()          // latched turn 2 key-down before turn 1 lands
        #expect(!lease.end())  // turn 1 ends: turn 2 still reading
        #expect(lease.end())   // turn 2 ends: reset
        #expect(lease.end())   // stray end never goes negative and still resets
        #expect(lease.count == 0)
    }
}
