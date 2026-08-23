import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Clipboard (T1 ④)

@Suite struct ClipboardRestoreTests {
    static func randomItems(seed: UInt64) -> [PasteboardItemSnapshot] {
        var rng = seed
        func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
        return (0..<Int(next() % 3 + 1)).map { _ in
            var types: [String: Data] = [:]
            for type in ["public.utf8-plain-text", "public.png", "public.tiff", "com.apple.flat-rtfd", "public.file-url"] where next() % 2 == 0 {
                types[type] = Data((0..<Int(next() % 64)).map { _ in UInt8(truncatingIfNeeded: next()) })
            }
            if types.isEmpty { types["public.png"] = Data([0x89, 0x50, 0x4E, 0x47]) }
            return PasteboardItemSnapshot(types: types)
        }
    }

    @Test("clipboard identical before/after paste, incl. images", arguments: Array(1...40))
    func roundTrip(seed: Int) throws {
        let mock = MockSystemAccess()
        let items = Self.randomItems(seed: UInt64(seed))
        mock.setPasteboard(items)
        let before = mock.readPasteboard()
        let result = try ClipboardPaster(system: mock).paste("dictated \(seed)", toPID: 100)
        #expect(result == .restored)
        #expect(mock.readPasteboard().items == before.items)
        #expect(mock.field.value == "dictated \(seed)")
    }

    @Test func emptyClipboardIsLeftEmpty() throws {
        let mock = MockSystemAccess()
        let result = try ClipboardPaster(system: mock).paste("x", toPID: 100)
        #expect(result == .nothingToRestore)
        #expect(mock.readPasteboard().items.isEmpty)
    }

    @Test func changeCountGuardSkipsRestoreWhenSomethingElseWrote() throws {
        let mock = MockSystemAccess()
        mock.setPasteboard([PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data("original".utf8)])])
        mock.externalPasteboardWriteAfterOurWrite = "user copied this"
        let result = try ClipboardPaster(system: mock).paste("ours", toPID: 100)
        #expect(result == .skippedChangeCountMismatch)
        #expect(mock.pasteboardString == "user copied this")
        #expect(!mock.journal.contains("pasteboard.restore"))
    }

    @Test func pasteFailureStillRestores() {
        final class Broken: MockSystemAccess {
            override func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws { throw SystemAccessError.eventPostFailed }
        }
        let mock = Broken()
        mock.setPasteboard([PasteboardItemSnapshot(types: ["public.png": Data([1, 2, 3])])])
        #expect(throws: SystemAccessError.eventPostFailed) { try ClipboardPaster(system: mock).paste("x", toPID: 100) }
        #expect(mock.pasteboardItems.first?.types["public.png"] == Data([1, 2, 3]))
    }
}
