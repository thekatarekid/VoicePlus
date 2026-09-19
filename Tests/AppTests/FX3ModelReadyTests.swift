import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// FX3 — "The speech model isn't ready" right after a first-run download that had succeeded.
//
// The 1.11.1 fresh install: all three models downloaded and verified; the Model step still said M07,
// 7 ms *before* the engine swap the download had already started, and "Retry loading" fixed it. The
// load asked for an engine refresh, the refresh returned at once because another one was running,
// and the box still held `UnavailableEngine`. Every onboarding test stubbed `loadModel` as always
// `.loaded`, and nothing ran two refreshes at once, so nothing saw it.

// MARK: - Fakes

/// A loadable model standing in for `RealEngine`.
final class FakeLoadableModel: PreloadableModel, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var calls = 0
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var isModelLoaded: Bool { lock.withLock { loaded } }
    var preloads: Int { lock.withLock { calls } }
    func preloadModel() async -> Bool {
        lock.withLock { calls += 1; loaded = succeeds }
        return succeeds
    }
}

/// Holds a refresh pass open until the test says so — no sleeps to race against a loaded machine.
final class PassHold: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
    func wait() async { while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) } }
}

/// The part of `AppContainer` a model load depends on: a box that starts empty, a refresh that runs
/// through the real `AppContainer.RefreshGate`, and a slow engine factory behind it. One pass reads
/// "the disk" first (as `chooseFinal` does), then spends `passNs` building, then swaps.
final class FakeEngineHost: @unchecked Sendable {
    let gate = AppContainer.RefreshGate()
    private let lock = NSLock()
    private var onDisk = false
    private var box: FakeLoadableModel?
    private var passCount = 0
    private var swapCount = 0
    let passNs: UInt64
    let hold: PassHold?

    init(passNs: UInt64 = 250_000_000, hold: PassHold? = nil) {
        self.passNs = passNs
        self.hold = hold
    }

    var filesOnDisk: Bool {
        get { lock.withLock { onDisk } }
        set { lock.withLock { onDisk = newValue } }
    }
    var model: FakeLoadableModel? { lock.withLock { box } }
    var passes: Int { lock.withLock { passCount } }
    var swaps: Int { lock.withLock { swapCount } }

    /// `AppContainer.refreshEngineIfNeeded`, minus the real models.
    func refresh() async { await gate.run { [self] in await self.pass() } }

    private func pass() async {
        let canRecognize = lock.withLock { () -> Bool in passCount += 1; return onDisk }
        try? await Task.sleep(nanoseconds: passNs)     // `EngineFactory.make` is not instant
        await hold?.wait()
        lock.withLock {
            guard canRecognize, box == nil else { return }
            box = FakeLoadableModel()
            swapCount += 1
        }
    }

    @MainActor
    func loader(swapTimeout: TimeInterval = 0, pollInterval: TimeInterval = 0.02,
                asked: FinalBox? = nil) -> InstalledModelLoader {
        InstalledModelLoader(refreshEngine: { asked?.append("refresh"); await self.refresh() },
                             isMockEngine: { false },
                             modelName: { "Parakeet TDT 0.6B v3" },
                             currentModel: { self.model },
                             stackOnDisk: { self.filesOnDisk },
                             swapTimeout: swapTimeout, pollInterval: pollInterval)
    }
}

/// A stack install that, like `ModelStackInstaller`, tells the app the models changed when it
/// lands. `awaitsEngine` picks the wiring: FX3 awaits the refresh; 1.11.1 spawned it and returned.
final class SwapOnInstallModels: ModelManaging {
    let host: FakeEngineHost
    let awaitsEngine: Bool
    private(set) var installed = false
    init(host: FakeEngineHost, awaitsEngine: Bool) { self.host = host; self.awaitsEngine = awaitsEngine }

    var isStackInstalled: Bool { installed }
    var remainingStackBytes: Int64 { installed ? 0 : ModelStack.approximateBytes }
    func downloadStack(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        guard !installed else { return }
        progress(ModelDownloadProgress(fraction: 1, bytesReceived: ModelStack.approximateBytes,
                                       bytesExpected: ModelStack.approximateBytes,
                                       modelName: ModelStack.displayNames.last ?? "", index: 3, count: 3))
        host.filesOnDisk = true
        installed = true
        let host = host
        if awaitsEngine { await host.refresh() } else { Task { await host.refresh() } }
    }
    var stackReadiness: RecognizerReadiness {
        installed ? .ready(name: "Parakeet TDT 0.6B v3") : .fallback(name: "Apple Speech (on-device)", awaiting: "Parakeet TDT 0.6B v3")
    }
}

// MARK: - The refresh gate

@Suite("FX3 — a refresh caller waits for the refresh already running")
struct FX3RefreshGateTests {
    /// The 1.11.1 race, exactly: the download's own refresh is mid-pass (slow factory) when the Model
    /// step's load asks for one. With no swap wait at all, the load must still see the real engine —
    /// it can only do that by waiting for the pass in flight. Under the old `if refreshing { return }`
    /// guard this returned `.failed` in a few milliseconds.
    @MainActor
    @Test func aLoadDuringAnInFlightRefreshSeesTheSwappedEngine() async throws {
        let hold = PassHold()
        let host = FakeEngineHost(passNs: 0, hold: hold)
        host.filesOnDisk = true
        let downloadRefresh = Task.detached { await host.refresh() }   // `onModelsChanged`
        try await waitUntil { host.passes == 1 }                       // mid-pass, held open
        let asked = FinalBox()
        final class Done: @unchecked Sendable { var outcome: OnboardingStateMachine.ModelLoadOutcome? }
        let done = Done()
        let load = Task { @MainActor in
            let outcome = await host.loader(swapTimeout: 0, asked: asked).load()
            done.outcome = outcome
            return outcome
        }
        try await waitUntil { !asked.values.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)                 // room for the old early return
        #expect(done.outcome == nil, "the load waits for the refresh in flight instead of answering now")
        hold.open()
        let outcome = await load.value
        #expect(outcome == .loaded(name: "Parakeet TDT 0.6B v3"))
        #expect(host.swaps == 1, "one swap, not one per caller")
        #expect(host.model?.preloads == 1)
        await downloadRefresh.value
    }

    /// A caller that joins also gets one pass of its own afterwards: the pass it joined may have read
    /// the disk before the files landed. Joining alone would strand it on the old answer.
    @Test func aJoinedCallerRunsOneMorePassSoAStaleReadCannotStrandIt() async throws {
        let hold = PassHold()
        let host = FakeEngineHost(passNs: 0, hold: hold)
        let early = Task.detached { await host.refresh() }
        try await waitUntil { host.passes == 1 }                 // it has read "nothing on disk"
        host.filesOnDisk = true                                  // the download lands mid-pass
        let joined = Task.detached { await host.refresh() }
        try await Task.sleep(nanoseconds: 100_000_000)           // let it join the held pass
        hold.open()
        await joined.value
        #expect(host.model != nil, "the joined caller returns with the engine swapped")
        #expect(host.passes == 2)
        await early.value
    }

    @Test func concurrentCallersShareOnePassAndTheGateClearsAfterwards() async {
        let host = FakeEngineHost(passNs: 100_000_000)
        host.filesOnDisk = true
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { await host.refresh() } }
        }
        #expect(host.swaps == 1, "six callers, one swap")
        #expect(!host.gate.isRefreshing)
        let before = host.passes
        await host.refresh()
        #expect(host.passes == before + 1, "an idle gate runs exactly one pass")
    }
}

// MARK: - The loader

@Suite("FX3 — the Model step never says M07 while a swap is pending")
struct FX3InstalledModelLoaderTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: FakeLoadableModel?
        var model: FakeLoadableModel? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @MainActor
    static func loader(box: Box, onDisk: Bool, mock: Bool = false, timeout: TimeInterval) -> InstalledModelLoader {
        InstalledModelLoader(refreshEngine: {}, isMockEngine: { mock }, modelName: { "Parakeet TDT 0.6B v3" },
                             currentModel: { box.model }, stackOnDisk: { onDisk },
                             swapTimeout: timeout, pollInterval: 0.02)
    }

    @MainActor
    @Test func aSwapThatLandsInsideTheWaitLoads() async {
        let box = Box()
        let swap = Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            box.model = FakeLoadableModel()
        }
        let outcome = await Self.loader(box: box, onDisk: true, timeout: 30).load()
        #expect(outcome == .loaded(name: "Parakeet TDT 0.6B v3"))
        await swap.value
    }

    @MainActor
    @Test func aSwapThatNeverComesIsM07WithTheRealReason() async {
        let outcome = await Self.loader(box: Box(), onDisk: true, timeout: 0.1).load()
        #expect(outcome == .failed(InstalledModelLoader.swapTimedOut))
    }

    @MainActor
    @Test func nothingOnDiskFailsAtOnceWithoutWaiting() async {
        let started = Date()
        let outcome = await Self.loader(box: Box(), onDisk: false, timeout: 30).load()
        #expect(outcome == .failed(InstalledModelLoader.nothingOnDisk))
        #expect(Date().timeIntervalSince(started) < 10, "no swap is owed, so nothing is waited for")
    }

    @MainActor
    @Test func aPreloadThatFailsIsM07AndSaysSo() async {
        let box = Box()
        box.model = FakeLoadableModel(succeeds: false)
        let outcome = await Self.loader(box: box, onDisk: true, timeout: 0).load()
        #expect(outcome == .failed(InstalledModelLoader.preloadFailed))
        #expect(box.model?.preloads == 1)
    }

    @MainActor
    @Test func aLoadedModelIsNotLoadedTwiceAndTheMockEngineNeedsNoModel() async {
        let box = Box()
        let model = FakeLoadableModel()
        _ = await model.preloadModel()
        box.model = model
        #expect(await Self.loader(box: box, onDisk: true, timeout: 0).load() == .loaded(name: "Parakeet TDT 0.6B v3"))
        #expect(model.preloads == 1)
        #expect(await Self.loader(box: Box(), onDisk: false, mock: true, timeout: 0).load() == .loaded(name: "Parakeet TDT 0.6B v3"))
    }

    /// The real installer: `downloadStack` returns only after `onModelsChanged` has finished, so
    /// `.downloadFinished` can never overtake the engine swap.
    @Test func theInstallReturnsOnlyAfterTheEngineRefreshFinished() async throws {
        let installer = ModelStackInstaller(manager: EngineSwapTests.manager(fetcher: EngineSwapTests.StubFetcher()))
        let order = FinalBox()
        installer.onModelsChanged = { @Sendable in
            try? await Task.sleep(nanoseconds: 150_000_000)     // a slow engine swap
            order.append("engine swapped")
        }
        try await installer.downloadStack { _ in }
        // Checked the instant it returns: under the 1.11.1 fire-and-forget wiring the swap was still
        // 150 ms away here.
        #expect(order.values.contains("engine swapped"), "the engine refresh finished before the install returned")
    }
}

// MARK: - The onboarding flow, with a real load (not the always-.loaded stub)

@Suite("FX3 — onboarding: install → Loading → Ready over a real load, and self-healing M07")
struct FX3OnboardingModelFlowTests {
    @MainActor
    static func deps(models: ModelManaging) -> OnboardingDependencies {
        var deps = OnboardingS8ViewModelTests.deps(resumeAt: .model)
        deps.models = models
        return deps
    }

    /// The owner's flow, end to end in the view model: the install lands, the app's refresh is
    /// slow, and the Model step's load is the real `InstalledModelLoader` (swap wait off, so only the
    /// gate can save it). Both wirings of `onModelsChanged` reach Ready — the 1.11.1 spawn-and-return
    /// one through the gate, the FX3 awaited one because the swap is done before `.downloadFinished`.
    @MainActor
    @Test(arguments: [false, true])
    func aFirstRunInstallReachesReadyWithoutARetry(awaitsEngine: Bool) async throws {
        let host = FakeEngineHost(passNs: 250_000_000)
        let models = SwapOnInstallModels(host: host, awaitsEngine: awaitsEngine)
        var deps = Self.deps(models: models)
        let loader = host.loader(swapTimeout: 0)
        final class Attempts { var n = 0 }
        let attempts = Attempts()
        deps.loadModel = { attempts.n += 1; return await loader.load() }
        let vm = OnboardingViewModel(dependencies: deps)
        try await waitUntil(timeoutMs: 10_000) {
            if case .ready = vm.machine.modelPhase { return true }
            if case .loadFailed = vm.machine.modelPhase { return true }
            return false
        }
        #expect(vm.machine.modelPhase == .ready(name: "Parakeet TDT 0.6B v3"))
        #expect(attempts.n == 1, "no Retry press, automatic or otherwise")
        #expect(host.swaps == 1)
        vm.teardown()
    }

    /// Belt and braces: if a load still fails while the swap is pending, the swap itself retries it
    /// — once. A model that really cannot load stops at M07 instead of looping on every swap.
    @MainActor
    @Test func anEngineSwapRetriesAFailedLoadOnce() async throws {
        let changes = PassthroughSubject<Void, Never>()
        var deps = Self.deps(models: OnboardingMockModelManager.installed())
        deps.engineChanges = changes.eraseToAnyPublisher()
        final class Attempts { var n = 0 }
        let attempts = Attempts()
        deps.loadModel = {
            attempts.n += 1
            return attempts.n >= 2 ? .loaded(name: "Parakeet TDT 0.6B v3") : .failed("swap pending")
        }
        let vm = OnboardingViewModel(dependencies: deps)
        try await waitUntil { vm.machine.modelPhase == .loadFailed("swap pending") }
        changes.send(())                                          // the engine swapped
        try await waitUntil { vm.machine.modelPhase == .ready(name: "Parakeet TDT 0.6B v3") }
        #expect(attempts.n == 2)
        vm.teardown()

        // A load that keeps failing: one automatic retry, then it waits for the user.
        let tries = Attempts()
        var stubbornDeps = Self.deps(models: OnboardingMockModelManager.installed())
        stubbornDeps.engineChanges = changes.eraseToAnyPublisher()
        stubbornDeps.loadModel = { tries.n += 1; return .failed("broken") }
        let stubborn = OnboardingViewModel(dependencies: stubbornDeps)
        try await waitUntil { stubborn.machine.modelPhase == .loadFailed("broken") }
        #expect(tries.n == 1)
        changes.send(())
        try await waitUntil { tries.n == 2 && stubborn.machine.modelPhase == .loadFailed("broken") }
        changes.send(())
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(tries.n == 2, "one automatic retry per failure, not one per swap")
        stubborn.send(.retryModelLoad)                            // the user can always retry
        try await waitUntil { tries.n == 3 }
        stubborn.teardown()
    }
}

// MARK: - The Try step: a new hold clears the last verdict

@Suite("FX3 — the practice step never shows a stale \"Heard you\" beside a new attempt")
struct FX3PracticeVerdictTests {
    @MainActor
    @Test func aNewHoldClearsTheLastVerdict() {
        let vm = OnboardingViewModel(dependencies: OnboardingS8ViewModelTests.deps(resumeAt: .firstDictation))
        let S = PracticeSessionTests.self
        vm.practiceEvent(.state(.starting)); vm.practiceEvent(.state(.finishing))
        vm.practiceEvent(.final([S.span("Hello there.")]))
        vm.practiceInsertionTimedOut()
        guard case .heard? = vm.machine.dictation else {
            Issue.record("expected .heard, got \(String(describing: vm.machine.dictation))"); vm.teardown(); return
        }
        vm.practiceEvent(.state(.starting))                      // the next hold begins
        #expect(vm.practice.phase == .listening)
        #expect(vm.machine.dictation == nil, "\"Heard you\" belongs to the last attempt, not this one")
        vm.teardown()
    }

    @MainActor
    @Test func aNewHoldAlsoClearsALastFailure() {
        let vm = OnboardingViewModel(dependencies: OnboardingS8ViewModelTests.deps(resumeAt: .firstDictation))
        vm.practiceEvent(.state(.starting)); vm.practiceEvent(.state(.finishing)); vm.practiceEvent(.final([]))
        #expect(vm.machine.dictation == .failed(reason: RecoveryCatalog.entry(.A06).headline))
        vm.practiceEvent(.state(.starting))
        #expect(vm.machine.dictation == nil)
        vm.teardown()
    }
}

// MARK: - The progress line

@Suite("FX3 — the progress line never pins the overall total on one model")
struct FX3DownloadProgressLineTests {
    static let total = ModelStack.approximateBytes

    struct Row: Sendable, CustomTestStringConvertible {
        let progress: ModelDownloadProgress
        let elapsed: TimeInterval
        let expected: String
        var testDescription: String { expected }
    }

    static let rows: [Row] = [
        // Start of the 3rd model of a first run — the 1.11.1 screenshot's moment, which read
        // "WeSpeaker v2 speaker embedding (3 of 3) — 900 MB of 914 MB".
        Row(progress: ModelDownloadProgress(fraction: 707_305_080.0 / Double(total), bytesReceived: 707_305_080,
                                            bytesExpected: total, modelName: "WeSpeaker v2 speaker embedding",
                                            index: 3, count: 3),
            elapsed: 0,
            expected: "Downloading model 3 of 3 · WeSpeaker v2 speaker embedding · 707 MB of 721 MB overall (98%)"),
        Row(progress: ModelDownloadProgress(fraction: 0.25, bytesReceived: total / 4, bytesExpected: total,
                                            modelName: "Parakeet TDT 0.6B v3", index: 1, count: 3),
            elapsed: 20,
            expected: "Downloading model 1 of 3 · Parakeet TDT 0.6B v3 · 180 MB of 721 MB overall (25%), about 60 seconds left"),
        // One model left to fetch: its total *is* the overall total, so no "overall" and no index.
        Row(progress: ModelDownloadProgress(fraction: 0.5, bytesReceived: 112_023_919, bytesExpected: 224_047_838,
                                            modelName: "Parakeet Realtime EOU 120M (160 ms)", index: 1, count: 1),
            elapsed: 1,
            expected: "Downloading Parakeet Realtime EOU 120M (160 ms) · 112 MB of 224 MB (50%)"),
        // No length from the server: a percentage, still never a made-up byte count.
        Row(progress: ModelDownloadProgress(fraction: 0.4, bytesReceived: 0, bytesExpected: 0,
                                            modelName: "Parakeet TDT 0.6B v3", index: 2, count: 3),
            elapsed: 1,
            expected: "Downloading model 2 of 3 · Parakeet TDT 0.6B v3 · 40%"),
    ]

    @Test(arguments: rows)
    func theLine(_ row: Row) {
        #expect(DownloadProgressText.line(row.progress, elapsed: row.elapsed) == row.expected)
    }

    @Test func theCatalogQuotesTheRealSizes() {
        #expect(ByteText.short(ModelCatalog.descriptor(.parakeetTDTv3).approxBytes) == "483 MB")
        #expect(ByteText.short(ModelCatalog.descriptor(.parakeetEOU160).approxBytes) == "224 MB")
        #expect(ByteText.short(ModelCatalog.descriptor(.speakerEmbedding).approxBytes) == "14 MB")
        #expect(ByteText.short(ModelStack.approximateBytes) == "721 MB", "was 914 MB for ~721 MB of files")
    }
}
