import Foundation
import Testing
import Shared
@testable import Providers

// X5 — the rewrite-model manager and the offer policy, against a mock downloader: nothing here
// touches the network or downloads a model.

final class MockModelDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var fail: Error?
    var progressSteps: [Double] = [0.25, 0.5, 1]

    func download(_ model: LocalLLMModel, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { _calls.append(model.id) }
        for p in progressSteps { progress(p) }
        if let fail { throw fail }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = model.localURL(root: root)
        try Data("gguf".utf8).write(to: url)
        return url
    }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LocalModelState] = []
    var all: [LocalModelState] { lock.withLock { items } }
    func add(_ s: LocalModelState) { lock.withLock { items.append(s) } }
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("x5-models-\(UUID().uuidString)", isDirectory: true)
}

private func manager(_ d: MockModelDownloader, root: URL = tempRoot(), free: Int64? = 100 << 30,
                     residency: ModelResidency? = nil) -> LocalModelManager {
    LocalModelManager(root: root, downloader: d, residency: residency, persistence: .inMemory(), freeDiskBytes: { free })
}

@Suite struct LocalModelManagerTests {
    @Test func offersQwen2BAnd4BWithTheirSizes() {
        let m = manager(MockModelDownloader())
        #expect(m.models.map(\.id) == ["qwen3.5-2b-q4km", "qwen3.5-4b-q4km"])
        #expect(m.models[0].bytes == 1_280_835_840)   // 1.28 GB
        #expect(m.models[1].bytes == 2_740_937_888)   // 2.74 GB
        #expect(m.models.allSatisfy { $0.downloadURL.host == "huggingface.co" })
    }

    @Test func downloadGoesNotDownloadedToDownloadingToReady() async {
        let d = MockModelDownloader()
        let m = manager(d)
        let id = LocalLLMCatalog.qwen35_2B.id
        let log = StateLog()
        m.addObserver { log.add(m.state(id)) }
        #expect(m.state(id) == .notDownloaded)
        #expect(m.activeModel == nil)
        await m.download(id)
        #expect(m.state(id) == .ready)
        #expect(log.all.contains(.downloading(0.5)))
        #expect(d.calls == [id])
        #expect(m.activeModel?.id == id)          // the first download becomes the pick
        await m.download(id)                      // already on disk: no second fetch
        #expect(d.calls == [id])
    }

    @Test func failedDownloadIsFailedWithAPlainMessageAndNothingOnDisk() async {
        let d = MockModelDownloader()
        d.fail = LocalLLMDownloadError.checksumMismatch(expected: "a", actual: "b")
        let m = manager(d)
        await m.download(LocalLLMCatalog.qwen35_4B.id)
        #expect(m.state(LocalLLMCatalog.qwen35_4B.id) == .failed("The download was damaged. Try again."))
        #expect(m.activeModel == nil)
        d.fail = LocalLLMDownloadError.transport("offline")
        await m.download(LocalLLMCatalog.qwen35_2B.id)
        #expect(m.state(LocalLLMCatalog.qwen35_2B.id) == .failed("Download failed. Check your connection and try again."))
    }

    @Test func refusesWhenTheDiskIsTooFull() async {
        let d = MockModelDownloader()
        let m = manager(d, free: 1 << 30)
        await m.download(LocalLLMCatalog.qwen35_4B.id)
        guard case .failed(let why) = m.state(LocalLLMCatalog.qwen35_4B.id) else { Issue.record("not failed"); return }
        #expect(why.contains("disk space"))
        #expect(d.calls.isEmpty)
    }

    @Test func deleteUnloadsRemovesAndFallsBackToTheOtherModel() async throws {
        let d = MockModelDownloader()
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let m = manager(d, residency: residency)
        let two = LocalLLMCatalog.qwen35_2B.id, four = LocalLLMCatalog.qwen35_4B.id
        await m.download(two)
        await m.download(four)
        m.setPreferred(four)
        #expect(m.activeModel?.id == four)
        // A resident 4B is unloaded before its file goes.
        let unloaded = StateLog()
        await residency.register("llm.qwen3.5-4b", tier: .onDemand, estimatedBytes: 1, load: {}, unload: { unloaded.add(.notDownloaded) })
        try await residency.acquire("llm.qwen3.5-4b")
        try await m.delete(four)
        #expect(unloaded.all.count == 1)
        #expect(m.state(four) == .notDownloaded)
        #expect(m.activeModel?.id == two)
        #expect(m.preferredID == nil)
        try await m.delete(two)
        #expect(m.activeModel == nil)
        await m.download(four)                       // redownload after delete
        #expect(m.state(four) == .ready)
    }

    @Test func recommendsFourBOnlyFrom24GB() {
        let m = manager(MockModelDownloader())
        #expect(m.recommended(physicalMemory: 16 << 30)?.id == LocalLLMCatalog.qwen35_2B.id)
        #expect(m.recommended(physicalMemory: 24 << 30)?.id == LocalLLMCatalog.qwen35_4B.id)
    }
}

@Suite struct ModelOfferPolicyTests {
    @Test func pickedInOnboardingNeverOffersInTheNotch() {
        let p = ModelOfferPolicy(store: .inMemory())
        #expect(p.stage == .undecided)
        p.recordOnboardingChoice()
        #expect(p.shouldOfferInNotch(hasReadyModel: false) == false)
    }

    @Test func skippedOnboardingOffersOnceThenSettingsOnly() {
        let store = ModelOfferPolicy.Persistence.inMemory()
        let p = ModelOfferPolicy(store: store)
        p.recordOnboardingSkipped()
        #expect(p.shouldOfferInNotch(hasReadyModel: true) == false)   // a model is already here
        #expect(p.shouldOfferInNotch(hasReadyModel: false))
        p.recordNotchOfferShown()
        #expect(p.shouldOfferInNotch(hasReadyModel: false) == false)
        #expect(ModelOfferPolicy(store: store).stage == .settingsOnly)   // persisted
    }

    @Test func neverAskedCountsAsSkipped() {
        #expect(ModelOfferPolicy(store: .inMemory()).shouldOfferInNotch(hasReadyModel: false))
    }
}
