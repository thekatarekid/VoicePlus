import Foundation
import Injection
import Testing
@testable import VoicePlusApp

// MARK: - H21 — the snapshot reads outward from the caret first; read facts persist per turn

/// A mock tree that also models the focused element and parents (MockAXTree models neither).
private final class CaretMockTree: AXNodeAccess, CaretNeighbourhoodAccess {
    let tree = MockAXTree()
    var focusedNode: MockAXNode?
    var subroles: [String: String] = [:]
    private var parents: [String: MockAXNode] = [:]

    func add(_ id: AXWindowID, root: MockAXNode) {
        tree.addWindow(id, root: root)
        index(root)
    }
    private func index(_ node: MockAXNode) {
        for c in node.children { parents[c.id] = node; index(c) }
    }

    var isTrusted: Bool { true }
    func windows(pid: Int32) -> [AXNodeRef] { tree.windows(pid: pid) }
    func focusedWindow(pid: Int32) -> AXNodeRef? { tree.focusedWindow(pid: pid) }
    func windowID(of node: AXNodeRef) -> AXWindowID? { tree.windowID(of: node) }
    func role(of node: AXNodeRef) -> String { tree.role(of: node) }
    func title(of node: AXNodeRef) -> String? { tree.title(of: node) }
    func children(of node: AXNodeRef) -> [AXNodeRef] { tree.children(of: node) }
    func value(of node: AXNodeRef) -> String? { tree.value(of: node) }
    func numberOfCharacters(of node: AXNodeRef) -> Int? { tree.numberOfCharacters(of: node) }
    func visibleCharacterRange(of node: AXNodeRef) -> Range<Int>? { tree.visibleCharacterRange(of: node) }
    func string(of node: AXNodeRef, range: Range<Int>) -> String? { tree.string(of: node, range: range) }
    func observe(window: AXWindowID, handler: @escaping (AXChangeEvent) -> Void) -> AXObservationToken? { nil }

    func focusedElement(pid: Int32) -> AXNodeRef? { focusedNode?.ref }
    func parent(of node: AXNodeRef) -> AXNodeRef? { parents[node.id]?.ref }
    func subrole(of node: AXNodeRef) -> String? { subroles[node.id] }
    func text(of node: AXNodeRef) -> String? { tree.value(of: node) ?? tree.title(of: node) }
}

private let claude = FocusSnapshot(pid: 321, bundleID: "com.anthropic.claudefordesktop", appName: "Claude")
private let window = AXWindowID(pid: 321, windowNumber: 1)

/// A long chat: sidebar, 1,500 messages, then the composer. The last message mentions hold-to-talk.
private func longChat(_ tree: CaretMockTree, composerRole: String = "AXTextArea") -> MockAXNode {
    let messages = (0..<1_500).map { i in
        MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText",
            value: i == 1_499 ? "Rename the hold-to-talk setting in Kubernetes docs" : "older message number \(i)")])
    }
    let composer = MockAXNode(role: composerRole, value: "draft")
    let root = MockAXNode(role: "AXWindow", title: "Claude", children: [
        MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: "Sidebar chats")]),
        MockAXNode(role: "AXScrollArea", children: messages),
        MockAXNode(role: "AXGroup", children: [composer, MockAXNode(role: "AXButton", title: "Send")]),
    ])
    tree.add(window, root: root)
    tree.focusedNode = composer
    return composer
}

@Suite("H21 snapshot outward from the caret")
struct TurnContextSnapshotH21Tests {
    @Test func walkerReadsNearestSiblingsFirstAndSkipsTheFocusedField() {
        let tree = CaretMockTree()
        _ = longChat(tree)
        let near = CaretOutwardWalker.read(access: tree, pid: claude.pid, deadline: nil, maxNodes: 40)
        #expect(near.blocks.first?.text == "Rename the hold-to-talk setting in Kubernetes docs")
        #expect(!near.blocks.contains { $0.text == "draft" })          // the field itself is H17's caret window
        #expect(near.nodesVisited <= 40)
        #expect(!near.secure)
    }

    @Test func longChatFixtureKeepsNearComposerText() throws {
        let tree = CaretMockTree()
        _ = longChat(tree)
        let reader = AXWindowReader(access: tree)
        let turnReader = AXTurnContextReader(reader: reader)
        #expect(turnReader.caretAccess != nil)                         // resolved from the reader's access
        let diagnostics = TurnContextDiagnostics()
        let snapshot = TurnContextSnapshot(reader: turnReader, contextualReading: { _ in true })
        snapshot.diagnostics = diagnostics
        snapshot.start(app: claude)
        guard case .contents(let c?) = snapshot.lookup(frontmost: claude) else { Issue.record("no contents"); return }
        // The top-down window walk (800 nodes) never reaches the last message …
        #expect(!c.content.blocks.contains { $0.text.contains("hold-to-talk") })
        // … but the snapshot keeps it, first, with the highest salience.
        let terms = c.candidates()
        let near = try #require(terms.first { $0.text == "hold-to-talk" })
        #expect(near.source == .nearCaret)
        #expect(near.distance == 2)                                    // a sibling of the composer's group
        #expect(c.visibleStrings().dropFirst().first?.0 == "Rename the hold-to-talk setting in Kubernetes docs")
        #expect(c.windowText()?.contains("Rename the hold-to-talk setting") == true)
        // Read facts: node count includes both reads, per-source counts recorded.
        let stats = try #require(snapshot.lastStats)
        #expect(stats.nearNodes > 0 && stats.nodes >= stats.nearNodes + 800)
        #expect((stats.candidateCounts["nearCaret"] ?? 0) > 0)
        #expect(diagnostics.current.stats == stats)
    }

    @Test func secureFocusedFieldReadsNothingNearTheCaret() {
        let tree = CaretMockTree()
        let field = longChat(tree, composerRole: "AXTextField")
        tree.subroles[field.id] = "AXSecureTextField"
        let near = CaretOutwardWalker.read(access: tree, pid: claude.pid, deadline: nil)
        #expect(near.secure)
        #expect(near.blocks.isEmpty && near.nodesVisited == 0)
    }

    @Test func secureNeighbourIsSkipped() {
        let tree = CaretMockTree()
        let field = MockAXNode(role: "AXTextArea", value: "x")
        let password = MockAXNode(role: "AXTextField", value: "hunter2")
        tree.subroles[password.id] = "AXSecureTextField"
        tree.add(window, root: MockAXNode(role: "AXWindow", children: [password, field, MockAXNode(role: "AXStaticText", value: "Label")]))
        tree.focusedNode = field
        let near = CaretOutwardWalker.read(access: tree, pid: claude.pid, deadline: nil)
        #expect(near.blocks.map(\.text) == ["Label"])
    }

    @Test func deadlineAndCancellationCutTheOutwardRead() {
        let tree = CaretMockTree()
        _ = longChat(tree)
        let past = CaretOutwardWalker.read(access: tree, pid: claude.pid, deadline: Date().addingTimeInterval(-1))
        #expect(past.interrupted && past.blocks.isEmpty)
        let token = AXReadCancellation(); token.cancel()
        #expect(CaretOutwardWalker.read(access: tree, pid: claude.pid, deadline: nil, cancellation: token).interrupted)
    }

    @Test func mockTreeWithoutParentsKeepsTheWindowWalkOnly() {
        let system = MockSystemAccess(frontmost: claude)
        #expect(AXTurnContextReader(reader: system.axReader).caretAccess == nil)
    }

    @Test func readFactsPersistInExtras() {
        var extras = TurnRecordExtras()
        let stats = TurnContextSnapshot.Stats(readMs: 120, nodes: 1_100, interrupted: true, timedOutWaiting: false,
                                              nearNodes: 300, candidateCounts: ["nearCaret": 7, "visible": 40])
        let entry = TurnContextDiagnostics.Entry(stats: stats, turnCandidateCounts: ["screenNear": 3, "screenWindow": 47])
        TurnContextDiagnostics.apply(entry, to: &extras)
        let s = extras.stageMs ?? [:]
        #expect(s["ctx_nodes"] == 1_100 && s["ctx_near_nodes"] == 300 && s["ctx_interrupted"] == 1 && s["ctx_timed_out"] == 0)
        #expect(s["ctx_read_ms"] == 120 && s["ctx_terms_nearCaret"] == 7 && s["ctx_terms_visible"] == 40)
        #expect(s["ctx_cand_screenNear"] == 3 && s["ctx_cand_screenWindow"] == 47)
    }

    @Test func diagnosticsResetAtKeyDown() {
        let diagnostics = TurnContextDiagnostics()
        diagnostics.recordTurnCandidates(["screenNear": 2])
        let snapshot = TurnContextSnapshot(reader: nil)
        snapshot.diagnostics = diagnostics
        snapshot.start(app: claude)
        #expect(diagnostics.current == TurnContextDiagnostics.Entry())
    }
}
