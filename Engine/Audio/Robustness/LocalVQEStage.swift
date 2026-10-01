import CoreML
import FluidAudio
import Foundation
import Shared

/// V5 C1b — the async enhancement a `LocalVQEStage` drives. The real one is FluidAudio's
/// `LocalVqeStream` (`FluidLocalVQEBackend`); tests inject a scripted one.
public protocol LocalVQEBackend: Sendable {
    /// Enhanced samples completed by this push (may be empty; output trails input by the model's
    /// chunk + `LocalVqeManager.outputDelaySamples`).
    func enhance(mic: [Float]) async throws -> [Float]
    /// The rest, so total output length equals total input length. Ends the clip.
    func flush() async throws -> [Float]
    func reset() async
}

/// V5 C1b — LocalVQE (neural AEC + noise suppression + dereverb, Apache-2.0, 4.8M params) as the
/// sample-level neural AEC slot of `AcousticChain` (`RobustnessProfile.localVQE`).
///
/// `AcousticStage.process` runs on the capture thread and must never block, while the model runs
/// in an actor at a 256 ms hop. So the stage is a non-blocking bridge: `process` queues the block for
/// a serial worker and returns whatever enhanced audio the worker has finished since the last call.
/// Latency is the hop plus inference (~256–300 ms); nothing is dropped — `flush()` (stop, off the
/// capture thread) waits for the queue and drains the model's delay line, bounded by `flushTimeout`.
/// If the backend throws, the stage stops enhancing and passes audio through for the rest of the
/// capture: a broken model must never cost the user their words.
///
/// **Far-end reference:** LocalVQE cancels echo against a loopback of what the speakers played. The
/// capture graph has no loopback tap yet, so the reference is silence: denoise + dereverb run, echo
/// cancellation proper does not (needs a system-audio reference → T1/O1).
public final class LocalVQEStage: AcousticStage, @unchecked Sendable {
    public let name = "localvqe-aec"
    public var isAvailable: Bool { true }
    public var flushTimeout: TimeInterval = 2

    private let backend: any LocalVQEBackend
    private let lock = NSLock()
    private var ready: [Float] = []
    private var failed = false
    /// Input queued while the backend is failed is passed straight through.
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var worker: Task<Void, Never>?
    private var generation = 0

    public init(backend: any LocalVQEBackend) {
        self.backend = backend
        startWorker()
    }

    /// Set by `loadIfAvailable` when the model is registered with `ModelResidency`; released on deinit.
    fileprivate var residencyKey: String?
    fileprivate var residency: ModelResidency?

    deinit {
        continuation?.finish(); worker?.cancel()
        if let residency, let key = residencyKey { Task { await residency.unregister(key) } }
    }

    /// `previous`/`resetBackend`: a reset waits for the old worker's in-flight call, then resets the
    /// model, before the new clip's first block — so nothing from the old clip leaks into the new one.
    private func startWorker(after previous: Task<Void, Never>? = nil, resetBackend: Bool = false) {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        let gen: Int = lock.withLock { generation += 1; continuation = cont; return generation }
        let backend = self.backend
        worker = Task.detached(priority: .userInteractive) { [weak self] in
            await previous?.value
            if resetBackend { await backend.reset() }
            // Raw input the model holds but has not returned yet (it conserves sample count), so a
            // failure hands *those* samples back un-enhanced instead of losing them.
            var held: [Float] = []
            for await block in stream {
                guard let self else { return }
                if self.lock.withLock({ self.failed || self.generation != gen }) {
                    self.lock.withLock { if self.generation == gen { self.ready.append(contentsOf: block) } }
                    continue
                }
                do {
                    held.append(contentsOf: block)
                    let out = try await backend.enhance(mic: block)
                    held.removeFirst(min(out.count, held.count))
                    self.lock.withLock { if self.generation == gen { self.ready.append(contentsOf: out) } }
                } catch {
                    Log.engine.error("localvqe: enhancement failed, passing audio through: \(error)")
                    let raw = held
                    held.removeAll()
                    self.lock.withLock { self.failed = true; if self.generation == gen { self.ready.append(contentsOf: raw) } }
                }
            }
        }
    }

    public var hasFailed: Bool { lock.withLock { failed } }

    public func process(_ samples: [Float]) -> [Float] {
        if !samples.isEmpty { _ = lock.withLock { continuation }?.yield(samples) }
        return lock.withLock { let out = ready; ready.removeAll(keepingCapacity: true); return out }
    }

    /// Blocks (≤ `flushTimeout`) until queued audio is enhanced and the delay line drained.
    public func flush() -> [Float] {
        let cont = lock.withLock { () -> AsyncStream<[Float]>.Continuation? in let c = continuation; continuation = nil; return c }
        cont?.finish()
        let task = worker
        let backend = self.backend
        let done = DispatchSemaphore(value: 0)
        let tail = TailBox()
        Task.detached(priority: .userInteractive) { [weak self] in
            await task?.value
            if self?.hasFailed == false { tail.value = (try? await backend.flush()) ?? [] }
            done.signal()
        }
        if done.wait(timeout: .now() + flushTimeout) == .timedOut {
            Log.engine.error("localvqe: flush timed out after \(flushTimeout)s")
        }
        let out = lock.withLock { () -> [Float] in let o = ready + tail.value; ready.removeAll(); return o }
        startWorker()
        return out
    }

    public func reset() {
        let cont = lock.withLock { () -> AsyncStream<[Float]>.Continuation? in
            let c = continuation; continuation = nil; ready.removeAll(); failed = false; return c
        }
        cont?.finish()
        let old = worker
        old?.cancel()
        startWorker(after: old, resetBackend: true)
    }

    private final class TailBox: @unchecked Sendable { var value: [Float] = [] }

    // MARK: loading

    /// The weights V5 C1b ships against (catalog `.localVQE`): v1.3, 4.8M params, 256 ms chunk.
    public static let config = LocalVqeConfig(variant: .v13, chunk: .batch256ms, computeUnits: .cpuOnly)
    public static var modelFileName: String { ModelNames.LocalVQE.modelFile(variant: config.variant, chunk: config.chunk) }

    /// Folders searched, in order: ours (`ModelCatalog`), then FluidAudio's cache. Never downloads.
    public static func candidateFolders() -> [URL] {
        [ModelCatalog.folder(for: .localVQE, in: ModelCatalog.modelsRoot()),
         MLModelConfigurationUtils.defaultModelsDirectory().appendingPathComponent(Repo.localVqe.folderName, isDirectory: true)]
    }

    public static func locate(manager: ModelManager? = nil, folders: [URL] = candidateFolders()) async -> URL? {
        if let manager, let folder = await manager.locate(.localVQE) { return folder }
        return folders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(modelFileName)
            .appendingPathComponent("coremldata.bin").path) }
    }

    /// Resident size for the residency budget: 4.8M params plus the CoreML runtime, ~50 MB.
    public static let approxBytes: Int64 = 50_000_000

    /// The real stage when the weights are on disk, else nil (the plan then falls back to the plain
    /// tap). §10: the load goes through `ModelResidency` as `.always` — a capture stage holds the
    /// model for the whole capture graph, so it is budgeted but never idle/pressure-evicted from under
    /// the mic thread. `residency: nil` keeps a bare load (tests).
    public static func loadIfAvailable(manager: ModelManager? = nil, folders: [URL] = candidateFolders(),
                                       residency: ModelResidency? = .shared) async -> LocalVQEStage? {
        guard let folder = await locate(manager: manager, folders: folders) else {
            Log.engine.notice("localvqe: weights not installed (\(modelFileName)); capture stays a plain tap")
            return nil
        }
        let box = BackendBox()
        let load: @Sendable () async throws -> Void = {
            if box.value == nil { box.value = try await FluidLocalVQEBackend(modelDirectory: folder) }
        }
        let key = "vqe.localvqe#\(UUID().uuidString.prefix(8))"
        do {
            if let residency {
                await residency.register(key, tier: .always, estimatedBytes: approxBytes, owner: "audio.localvqe",
                                         load: load, unload: { box.value = nil })
                try await residency.acquire(key)
            } else {
                try await load()
            }
            guard let backend = box.value else { throw CancellationError() }
            Log.engine.info("localvqe: loaded \(modelFileName) from \(folder.path)")
            let stage = LocalVQEStage(backend: backend)
            stage.residencyKey = residency == nil ? nil : key
            stage.residency = residency
            return stage
        } catch {
            if let residency { await residency.unregister(key) }
            Log.engine.error("localvqe: load failed, capture stays a plain tap: \(error)")
            return nil
        }
    }

    private final class BackendBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: FluidLocalVQEBackend?
        var value: FluidLocalVQEBackend? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }
}

/// `LocalVqeStream` over FluidAudio's `LocalVqeManager`, reference = silence (see `LocalVQEStage`).
public actor FluidLocalVQEBackend: LocalVQEBackend {
    private let manager: LocalVqeManager
    private var stream: LocalVqeStream

    public init(modelDirectory: URL, config: LocalVqeConfig = LocalVQEStage.config) async throws {
        manager = try LocalVqeManager(config: config, modelDirectory: modelDirectory)
        stream = try await manager.makeStream()
    }

    public func enhance(mic: [Float]) async throws -> [Float] {
        try await stream.enhance(mic: mic, reference: [Float](repeating: 0, count: mic.count))
    }

    public func flush() async throws -> [Float] { try await stream.flush() }

    public func reset() async {
        if let fresh = try? await manager.makeStream() { stream = fresh }
    }
}
