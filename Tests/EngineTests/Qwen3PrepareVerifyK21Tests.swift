import Foundation
import Testing
@testable import Engine

/// V5 K21 — the real session's prepare checks byte counts (`Qwen3WeightsStore.verify`) before any
/// CoreML load, so a folder the Settings row calls "Not verified" is never loaded as if it were.
@Suite("Qwen3 prepare verifies weights (K21)")
struct Qwen3PrepareVerifyK21Tests {
    @Test func prepareRejectsWeightsWhoseSizesDoNotMatchTheManifest() async throws {
        let root = try Qwen3WeightsStoreTests.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Qwen3WeightsStoreTests.makeWeightsTree(in: root)   // 1-byte files: present, not verified
        let store = Qwen3WeightsStore(searchPaths: [folder])
        #expect(store.problems(at: folder).isEmpty)
        #expect(!store.verify(at: folder).isEmpty)
        let session = Qwen3RefinementSession(store: store)
        do {
            try await session.prepare()
            Issue.record("prepare accepted unverified weights")
        } catch let RefinementError.weightsIncomplete(path, problems) {
            #expect(path == folder.path)
            #expect(problems.count == store.verify(at: folder).count)
            #expect(problems.allSatisfy { $0.hasSuffix("does not match the published size") })
        }
    }
}
