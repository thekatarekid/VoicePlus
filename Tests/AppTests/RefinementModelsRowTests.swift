import Foundation
import Testing
import Shared
import Engine
@testable import VoicePlusApp

/// K21 — Settings › Models refinement row: says what it does, and shows "Ready" only when the
/// weights are present *and* match the publisher's byte counts.
@Suite("Models refinement row copy (K21)")
struct RefinementModelsRowTests {

    @Test func rowSaysWhatItDoes() {
        let r = RefinementReadiness(flagEnabled: false, systemReason: nil, weightsPresent: false)
        #expect(r.modelsRowDetail.hasPrefix("Second pass, English, adds ~2 s"))
        #expect(r.statusTag == "Off")
    }

    @Test func presentButUnverifiedIsNeverReady() {
        let r = RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: true, weightsVerified: false)
        #expect(!r.isAvailable)
        #expect(r.statusTag == "Not verified")
        #expect(!r.note.contains("Ready"))
    }

    @Test func verifiedIsReady() {
        let r = RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: true, weightsVerified: true)
        #expect(r.isAvailable)
        #expect(r.statusTag == "Ready")
        #expect(r.note.hasPrefix("Ready"))
    }

    @Test func verifiedRequiresPresent() {
        let r = RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: false, weightsVerified: true)
        #expect(!r.weightsVerified)
        #expect(!r.isAvailable)
    }

    /// Real disk: sparse files (no real bytes written) with the recorded sizes verify; one file a
    /// byte short is present (non-empty) but unverified.
    @Test func resolveVerifiesByteCountsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("k21-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(Qwen3WeightsLayout.folderName)
        defer { try? FileManager.default.removeItem(at: root) }
        for (i, file) in Qwen3WeightsLayout.files.enumerated() {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(i == 0 ? file.bytes - 1 : file.bytes))
            try h.close()
        }
        let store = Qwen3WeightsStore(searchPaths: [folder])
        let flags = FeatureFlagService.inMemory([ModelStack.refinementFlagID: true])
        let bad = RefinementReadiness.resolve(flags: flags, store: store)
        #expect(bad.weightsPresent)
        #expect(!bad.weightsVerified)
        #expect(bad.statusTag != "Ready")

        let first = folder.appendingPathComponent(Qwen3WeightsLayout.files[0].path)
        let h = try FileHandle(forWritingTo: first)
        try h.truncate(atOffset: UInt64(Qwen3WeightsLayout.files[0].bytes))
        try h.close()
        let good = RefinementReadiness.resolve(flags: flags, store: store)
        #expect(good.weightsVerified)
        #expect(good.isAvailable == (RefinementAvailability.unavailableReason == nil))
    }
}
