import FluidAudio
import Foundation
import Testing
@testable import Engine
@testable import Shared

/// V5 C1b — LocalVQE as the neural AEC slot. The bridge (non-blocking `process`, lossless `flush`,
/// passthrough on failure) is tested against a scripted backend; the real CoreML model runs only when
/// `VOICEPLUS_LOCALVQE_DIR` points at a folder holding `localvqe-v1.3-4.8M-256ms.mlmodelc`.
/// Untested here: enhancement quality and the V1 gate (VOiCES + MUSAN-mixed) → T1.
@Suite("V5 C1b — LocalVQE stage")
struct LocalVQEStageTests {
    /// Emits input delayed by whole 4096-sample chunks, scaled by 0.5 — the shape of `LocalVqeStream`.
    actor ChunkedBackend: LocalVQEBackend {
        let chunk = 4_096
        var pending: [Float] = []
        var failAfter: Int?
        var calls = 0
        init(failAfter: Int? = nil) { self.failAfter = failAfter }
        func enhance(mic: [Float]) async throws -> [Float] {
            calls += 1
            if let f = failAfter, calls > f { throw CancellationError() }
            pending += mic
            let n = (pending.count / chunk) * chunk
            let out = pending.prefix(n).map { $0 * 0.5 }
            pending.removeFirst(n)
            return out
        }
        func flush() async throws -> [Float] { let out = pending.map { $0 * 0.5 }; pending.removeAll(); return out }
        func reset() async { pending.removeAll(); calls = 0 }
    }

    private func ramp(_ n: Int, from: Int = 0) -> [Float] { (from..<from + n).map { Float($0 % 1000) / 1000 } }

    private func run(_ stage: LocalVQEStage, blocks: Int, size: Int = 800) async -> [Float] {
        var out: [Float] = []
        for b in 0..<blocks {
            out += stage.process(ramp(size, from: b * size))
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return out + stage.flush()
    }

    @Test func conservesEverySampleInOrder() async {
        let stage = LocalVQEStage(backend: ChunkedBackend())
        let out = await run(stage, blocks: 20)
        #expect(out.count == 16_000)
        #expect(out == ramp(16_000).map { $0 * 0.5 }, "enhanced, in order, nothing dropped")
        #expect(stage.name.hasSuffix("-aec"), "counts as the neural AEC in effectiveAEC")
    }

    @Test func processNeverWaitsForTheModel() {
        let stage = LocalVQEStage(backend: ChunkedBackend())
        let t0 = Date()
        for b in 0..<50 { _ = stage.process(ramp(800, from: b * 800)) }
        #expect(Date().timeIntervalSince(t0) < 0.5, "capture thread is never blocked")
        _ = stage.flush()
    }

    @Test func aFailingModelPassesAudioThroughForTheRestOfTheCapture() async {
        let stage = LocalVQEStage(backend: ChunkedBackend(failAfter: 3))
        let out = await run(stage, blocks: 20)
        #expect(stage.hasFailed)
        #expect(out.count == 16_000, "what the failed model held comes back raw: \(out.count)")
        #expect(Array(out.prefix(2_400)) == ramp(2_400), "un-enhanced, in order")
        #expect(Array(out.suffix(800)) == ramp(800, from: 15_200), "raw audio after the failure")
    }

    @Test func resetStartsAFreshClip() async {
        let stage = LocalVQEStage(backend: ChunkedBackend())
        _ = stage.process(ramp(3_000))
        stage.reset()
        let out = await run(stage, blocks: 10)
        #expect(out.count == 8_000)
    }

    @Test func profileAndPlan() {
        #expect(RobustnessProfile.localVQE.aec == .neural)
        #expect(!RobustnessProfile.localVQE.noiseSuppression)
        let plan = CaptureGraphPlan.plan(for: .localVQE, localVQEAvailable: true)
        #expect(plan.usesNeuralStage && !plan.usesVoiceProcessingSource)
        #expect(CaptureGraphPlan.plan(for: .localVQE, localVQEAvailable: false) == CaptureGraphPlan.plan(for: .off),
                "no weights → the plain tap, never a broken capture")
        let stage = LocalVQEStage(backend: ChunkedBackend())
        let capture = plan.makeCaptureSource(plainTap: { CaptureEnhancementTests.FakeSource("tap", vp: false) },
                                             voiceProcessing: { CaptureEnhancementTests.FakeSource("vp", vp: true) },
                                             neuralStage: stage)
        #expect(capture.chain.stages.count == 1)
        #expect(capture.effectiveAEC == .neural)
        _ = stage.flush()
    }

    @Test func catalogEntry() {
        let d = ModelCatalog.descriptor(.localVQE)
        #expect(d.hfRepo == Repo.localVqe.rawValue)
        #expect(d.folderName == Repo.localVqe.folderName)
        #expect(ModelCatalog.fluidAudioFolderName(for: .localVQE) == d.folderName)
        #expect(d.requiredPaths == [LocalVQEStage.modelFileName])
        #expect(LocalVQEStage.modelFileName == "localvqe-v1.3-4.8M-256ms.mlmodelc")
        #expect(d.role == .onDemand)
        #expect(!ModelStack.models.contains(.localVQE), "never installed with the stack")
        #expect(!ModelCatalog.userVisible(qwenRefinementEnabled: true).contains(.localVQE))
        #expect(d.license == "Apache-2.0")
    }

    @Test func locateFindsOnlyACompleteModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c1b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent(LocalVQEStage.modelFileName)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        #expect(await LocalVQEStage.locate(folders: [dir]) == nil)
        try Data([0]).write(to: model.appendingPathComponent("coremldata.bin"))
        #expect(await LocalVQEStage.locate(folders: [dir]) == dir)
        #expect(await LocalVQEStage.loadIfAvailable(folders: []) == nil)
    }

    /// Real CoreML LocalVQE over a noisy fixture: runs only with `VOICEPLUS_LOCALVQE_DIR`.
    @Test func realModelWhenWeightsAreProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEPLUS_LOCALVQE_DIR"] else { return }
        let stage = try #require(await LocalVQEStage.loadIfAvailable(folders: [URL(fileURLWithPath: path)]))
        let url = try #require(AudioFixtures.list("noisy").first)
        let samples = try WAVFile.read(url: url).samples
        var out: [Float] = []
        var i = 0
        while i < samples.count {
            out += stage.process(Array(samples[i..<min(i + 800, samples.count)]))
            i += 800
        }
        out += stage.flush()
        #expect(!stage.hasFailed)
        #expect(out.count == samples.count, "\(out.count) vs \(samples.count)")
        let allFinite = out.allSatisfy { $0.isFinite }
        #expect(allFinite)
        let rms = { (x: [Float]) in (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot() }
        print("LocalVQE real: \(url.lastPathComponent) rms in \(rms(samples)) out \(rms(out))")
        #expect(rms(out) > 0)
    }
}
