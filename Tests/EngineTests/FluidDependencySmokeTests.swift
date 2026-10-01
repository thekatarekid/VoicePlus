// V5 J6 smoke: the FluidAudio bump and the FluidUse dependency link, and the types later items
// rely on exist. No model is downloaded — every load points at an empty local directory and must
// fail fast without touching the network.
import CoreML
import FluidAudio
import FluidUse
import Foundation
import Testing

@Suite("V5 J6 dependency smoke")
struct FluidDependencySmokeTests {
    private func emptyDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-j6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("FluidAudio exposes Parakeet Ultra/Redux and LocalVQE (unlocks B5, C1b)")
    func fluidAudioSurface() {
        let versions: [AsrModelVersion] = [.v3, .ultra, .redux]
        #expect(versions.count == 3)
        _ = LocalVqeManager.self
        _ = LocalVqeConfig.default
    }

    @Test("FluidUse LayaManager: configuration builds; local load of an empty dir throws, never downloads")
    func layaManagerType() async throws {
        let config = LayaManager.Configuration()
        #expect(config.lengths == [128, 512])
        #expect(LayaManager.maximumOptions > 0)
        let dir = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await LayaManager.load(from: dir, configuration: config)
        }
    }

    @Test("FluidUse KevFastManager: local load of an empty dir throws, never downloads")
    func kevFastManagerType() async throws {
        let dir = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await KevFastManager.load(from: dir, computeUnits: .cpuOnly)
        }
    }
}
