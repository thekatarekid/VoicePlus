import Foundation
import Testing
@testable import Injection

// MARK: - P3.4 WindowContentCache: observer invalidation + TTL fallback

private let win = AXWindowID(pid: 42, windowNumber: 1)

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

private func stack(observers: Bool = true, ttl: TimeInterval = 2) -> (CachedAXReader, MockAXTree, MockAXNode, Clock) {
    let clock = Clock()
    let t = MockAXTree()
    t.observersAvailable = observers
    let node = MockAXNode(role: "AXTextArea", value: "v1")
    t.addWindow(win, root: MockAXNode(role: "AXWindow", children: [node]))
    let reader = CachedAXReader(reader: AXWindowReader(access: t, now: { clock.now }), access: t,
                                cache: WindowContentCache(ttl: ttl, now: { clock.now }))
    return (reader, t, node, clock)
}

@Suite struct AXReaderCacheTests {
    @Test func secondReadIsServedFromCache() throws {
        let (reader, tree, node, _) = stack()
        #expect(try reader.readWindow(win, options: .full).text == "v1")
        node.value = "v2"                                   // changed without a notification
        #expect(try reader.readWindow(win, options: .full).text == "v1")
        #expect(reader.cache.hits == 1 && reader.cache.misses == 1)
        #expect(tree.observerCount == 1)
        #expect(reader.cache.isObserving(win))
    }

    @Test func valueChangedInvalidates() throws {
        let (reader, tree, node, _) = stack()
        _ = try reader.readWindow(win, options: .full)
        node.value = "v2"
        tree.fire(.valueChanged(win))
        #expect(try reader.readWindow(win, options: .full).text == "v2")
    }

    @Test func focusChangeInvalidatesOnlyThatWindow() throws {
        let (reader, tree, node, _) = stack()
        let other = AXWindowID(pid: 42, windowNumber: 2)
        let otherNode = MockAXNode(role: "AXTextArea", value: "o1")
        tree.addWindow(other, root: MockAXNode(role: "AXWindow", children: [otherNode]), focused: false)
        _ = try reader.readWindow(win, options: .full)
        _ = try reader.readWindow(other, options: .full)
        node.value = "v2"; otherNode.value = "o2"
        tree.fire(.focusChanged(win))
        #expect(try reader.readWindow(win, options: .full).text == "v2")
        #expect(try reader.readWindow(other, options: .full).text == "o1")
    }

    @Test func windowDestroyedDropsEntryAndObserver() throws {
        let (reader, tree, _, _) = stack()
        _ = try reader.readWindow(win, options: .full)
        tree.removeWindow(win)
        #expect(reader.cache.get(win, scrollback: true) == nil)
        #expect(!reader.cache.isObserving(win))
        #expect(tree.observerCount == 0)
    }

    @Test func ttlFallbackWhenObserversUnavailable() throws {
        let (reader, tree, node, clock) = stack(observers: false, ttl: 2)
        _ = try reader.readWindow(win, options: .full)
        #expect(tree.observerCount == 0)
        node.value = "v2"
        clock.advance(1.5)
        #expect(try reader.readWindow(win, options: .full).text == "v1")
        clock.advance(1)
        #expect(try reader.readWindow(win, options: .full).text == "v2")
    }

    @Test func visibleAndScrollbackEntriesAreSeparate() throws {
        let (reader, _, node, _) = stack()
        node.value = String(repeating: "x", count: 50) + "TAIL"
        node.visibleRange = 50..<54
        #expect(try reader.readWindow(win, options: .visible).text == "TAIL")
        #expect(try reader.readWindow(win, options: .full).text == node.value)
        #expect(reader.cache.misses == 2)
        #expect(try reader.readWindow(win, options: .visible).text == "TAIL")
        #expect(reader.cache.hits == 1)
    }

    @Test func truncatedEntryIsNotReusedForLargerCap() throws {
        let (reader, _, node, _) = stack()
        node.value = String(repeating: "y", count: 100)
        var small = AXReadOptions.full
        small.limits.maxCharacters = 10
        #expect(try reader.readWindow(win, options: small).characterCount == 10)
        #expect(try reader.readWindow(win, options: .full).characterCount == 100)
        #expect(try reader.readWindow(win, options: small).characterCount == 100)  // larger cached read still fits
    }

    @Test func readFocusedWindowGoesThroughCache() throws {
        let (reader, _, node, _) = stack()
        _ = try reader.readFocusedWindow(pid: 42, options: .full)
        node.value = "v2"
        #expect(try reader.readFocusedWindow(pid: 42, options: .full).text == "v1")
        reader.cache.invalidateAll()
        #expect(try reader.readFocusedWindow(pid: 42, options: .full).text == "v2")
    }

    @Test func mockSystemAccessVendsReader() throws {
        let access = MockSystemAccess()
        access.mockAXTree.addWindow(win, root: MockAXNode(role: "AXWindow", children: [MockAXNode(role: "AXStaticText", value: "hi")]))
        let provider: AXReaderProviding = access
        #expect(try provider.axReader.readFocusedWindow(pid: 42, options: .visible).text == "hi")
        #expect(provider.axReader === access.axReader)
    }
}
