import Foundation
import Testing
@testable import Injection

// MARK: - P3.4 deep AX reading: walking, range stitching, truncation

private let win = AXWindowID(pid: 42, windowNumber: 1)

private func tree(_ root: MockAXNode, focused: Bool = true) -> MockAXTree {
    let t = MockAXTree()
    t.addWindow(win, root: root, focused: focused)
    return t
}

@Suite struct AXReaderWalkTests {
    @Test func walksTreeInReadingOrderAndSkipsChrome() throws {
        let root = MockAXNode(role: "AXWindow", title: "Notes", children: [
            MockAXNode(role: "AXToolbar", children: [MockAXNode(role: "AXStaticText", value: "Toolbar junk")]),
            MockAXNode(role: "AXGroup", children: [
                MockAXNode(role: "AXStaticText", value: "Heading"),
                MockAXNode(role: "AXScrollArea", children: [MockAXNode(role: "AXTextArea", value: "Body text")]),
            ]),
            MockAXNode(role: "AXButton", title: "OK"),
        ])
        let content = try AXWindowReader(access: tree(root)).readWindow(win, options: .full)
        #expect(content.title == "Notes")
        #expect(content.blocks.map(\.text) == ["Heading", "Body text"])
        #expect(content.blocks.map(\.depth) == [2, 3])
        #expect(content.text == "Heading\n\nBody text")
        #expect(!content.truncated)
    }

    @Test func focusedWindowAndWindowList() throws {
        let t = MockAXTree()
        t.addWindow(AXWindowID(pid: 42, windowNumber: 7), root: MockAXNode(role: "AXWindow", children: [MockAXNode(role: "AXStaticText", value: "A")]), focused: false)
        t.addWindow(win, root: MockAXNode(role: "AXWindow", children: [MockAXNode(role: "AXStaticText", value: "B")]))
        let reader = AXWindowReader(access: t)
        #expect(reader.windows(pid: 42) == [win, AXWindowID(pid: 42, windowNumber: 7)])
        #expect(try reader.readFocusedWindow(pid: 42, options: .visible).text == "B")
        #expect(throws: AXReadError.windowNotFound(AXWindowID(pid: 42, windowNumber: 99))) {
            try reader.readWindow(AXWindowID(pid: 42, windowNumber: 99), options: .visible)
        }
        #expect(throws: AXReadError.noFocusedWindow(pid: 9)) { try reader.readFocusedWindow(pid: 9, options: .visible) }
        t.isTrusted = false
        #expect(throws: AXReadError.accessibilityNotTrusted) { try reader.readWindow(win, options: .visible) }
    }

    @Test func stitchesStringForRangeChunksAcrossScrollback() throws {
        let scrollback = (1...500).map { "line \($0)" }.joined(separator: "\n")   // ~4.4k chars
        let node = MockAXNode(role: "AXTextArea", value: scrollback, visibleRange: (scrollback.utf16.count - 200)..<scrollback.utf16.count)
        let t = tree(MockAXNode(role: "AXWindow", children: [node]))
        var opts = AXReadOptions.full
        opts.limits.rangeChunk = 1000
        let content = try AXWindowReader(access: t).readWindow(win, options: opts)
        #expect(content.text == scrollback)
        #expect(content.blocks[0].totalCharacters == scrollback.utf16.count)
        #expect(content.blocks[0].visibleRange == node.visibleRange)
        let ranges = t.rangeRequests.map(\.range)
        #expect(ranges.count == 5)
        #expect(ranges.first == 0..<1000)
        #expect(ranges.last?.upperBound == scrollback.utf16.count)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })   // contiguous
    }

    @Test func visibleOnlyReadUsesVisibleRangeAndDocumentReadGetsAll() throws {
        let text = String(repeating: "x", count: 1000) + "VISIBLE"
        let node = MockAXNode(role: "AXTextArea", value: text, visibleRange: 1000..<1007)
        let reader = AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: [node])))
        let visible = try reader.readWindow(win, options: .visible)
        #expect(visible.text == "VISIBLE")
        #expect(visible.blocks[0].totalCharacters == 1007)
        #expect(!visible.truncated)                         // expected partial view, not a cap hit
        #expect(try reader.readDocument(win).text == text)   // on-demand full content
    }

    @Test func fallsBackToAXValueWhenRangesUnsupported() throws {
        let node = MockAXNode(role: "AXTextArea", value: "electron text", supportsRanges: false, visibleRange: 9..<13)
        let t = tree(MockAXNode(role: "AXWindow", children: [node]))
        let reader = AXWindowReader(access: t)
        #expect(try reader.readWindow(win, options: .full).text == "electron text")
        #expect(try reader.readWindow(win, options: .visible).text == "text")
        #expect(t.rangeRequests.count == 1)   // one probe for the visible range, then AXValue fallback
    }

    @Test func partialRangeFailureKeepsWhatWasRead() throws {
        let node = MockAXNode(role: "AXTextArea", value: String(repeating: "a", count: 3000))
        node.rangeFailsAfter = 2000
        var opts = AXReadOptions.full
        opts.limits.rangeChunk = 1000
        let content = try AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: [node]))).readWindow(win, options: opts)
        #expect(content.text.count == 2000)
        #expect(content.truncated)
    }

    @Test func unicodeSurrogatePairsSurviveStitching() throws {
        let text = String(repeating: "😀é", count: 300)   // surrogate pairs straddle chunk edges
        let node = MockAXNode(role: "AXTextArea", value: text)
        var opts = AXReadOptions.full
        opts.limits.rangeChunk = 7
        let content = try AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: [node]))).readWindow(win, options: opts)
        #expect(content.text == text)
    }
}

@Suite struct AXReaderTruncationTests {
    @Test func capsAt200kCharactersKeepingHead() throws {
        let big = String(repeating: "b", count: 150_000)
        let root = MockAXNode(role: "AXWindow", children: [
            MockAXNode(role: "AXTextArea", value: big), MockAXNode(role: "AXTextArea", value: big),
            MockAXNode(role: "AXStaticText", value: "never reached"),
        ])
        let content = try AXWindowReader(access: tree(root)).readWindow(win, options: .full)
        #expect(content.characterCount == 200_000)
        #expect(content.truncated)
        #expect(content.blocks.count == 2)
        #expect(content.blocks[1].text.utf16.count == 50_000)
    }

    @Test func keepTailKeepsLatestTerminalOutput() throws {
        let old = String(repeating: "o", count: 150_000)
        let new = String(repeating: "n", count: 100_000) + "END"
        let root = MockAXNode(role: "AXWindow", children: [
            MockAXNode(role: "AXTextArea", value: old), MockAXNode(role: "AXTextArea", value: new),
        ])
        let content = try AXWindowReader(access: tree(root)).readDocument(win)
        #expect(content.characterCount == 200_000)
        #expect(content.truncated)
        #expect(content.blocks.count == 2)
        #expect(content.blocks[0].text.utf16.count == 99_997)
        #expect(content.text.hasSuffix("END"))
        #expect(!content.blocks[0].text.contains("n"))
    }

    @Test func customCapAndNodeBudget() throws {
        let children = (0..<100).map { MockAXNode(role: "AXStaticText", value: "row \($0)") }
        var opts = AXReadOptions.full
        opts.limits.maxNodes = 11   // window + 10 rows
        let content = try AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: children))).readWindow(win, options: opts)
        #expect(content.blocks.count == 10)
        #expect(content.truncated)
        #expect(content.nodesVisited == 11)

        opts = .full
        opts.limits.maxCharacters = 12
        let capped = try AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: children))).readWindow(win, options: opts)
        #expect(capped.characterCount == 12)
        #expect(capped.text == "row 0\n\nrow 1\n\nro")
    }

    @Test func depthLimitStopsRunawayTrees() throws {
        var node = MockAXNode(role: "AXStaticText", value: "deep")
        for _ in 0..<100 { node = MockAXNode(role: "AXGroup", children: [node]) }
        let content = try AXWindowReader(access: tree(MockAXNode(role: "AXWindow", children: [node]))).readWindow(win, options: .full)
        #expect(content.blocks.isEmpty)
        #expect(content.truncated)
    }
}
