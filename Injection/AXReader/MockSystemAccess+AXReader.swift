import Foundation

extension MockSystemAccess: AXReaderProviding {
    /// Shared mock tree for the app's mock engine; seed it via `mockAXTree.addWindow`.
    public var mockAXTree: MockAXTree { MockAXTreeRegistry.shared.tree(for: self) }
    public var axReader: AXReading { MockAXTreeRegistry.shared.reader(for: self) }
}

/// Associates one tree + cached reader with each `MockSystemAccess` without touching its stored properties.
final class MockAXTreeRegistry {
    static let shared = MockAXTreeRegistry()
    private let table = NSMapTable<MockSystemAccess, CachedAXReader>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let lock = NSLock()

    func reader(for access: MockSystemAccess) -> CachedAXReader {
        lock.lock(); defer { lock.unlock() }
        if let r = table.object(forKey: access) { return r }
        let r = CachedAXReader(access: MockAXTree())
        table.setObject(r, forKey: access)
        return r
    }

    func tree(for access: MockSystemAccess) -> MockAXTree {
        // swiftlint:disable:next force_cast
        (reader(for: access).reader as! AXWindowReader).access as! MockAXTree
    }
}
