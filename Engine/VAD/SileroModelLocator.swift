import FluidAudio
import Foundation
import Shared

/// V5 C6 (+K17) — where a Silero VAD `.mlmodelc` can be found on this machine, in priority order.
/// Read-only: never downloads, never writes. Accepts the file the pinned FluidAudio asks for and the
/// older v6.0.0 export (same I/O: `audio_input[1,4160]`, `hidden_state`/`cell_state[1,128]`), which
/// is what existing FluidAudio caches on users' disks hold.
public struct SileroModelLocator: Sendable {
    /// Newest first.
    public static let knownModelFiles = [ModelNames.VAD.sileroVadFile, "silero-vad-unified-256ms-v6.0.0.mlmodelc"]

    public var folders: [URL]
    public init(folders: [URL] = SileroModelLocator.defaultFolders()) { self.folders = folders }

    /// Our folder → app bundle → FluidAudio cache (current + `-coreml` spelling) → source checkout.
    public static func defaultFolders(fileManager: FileManager = .default) -> [URL] {
        var out = [ModelCatalog.folder(for: .sileroVAD, in: ModelCatalog.modelsRoot(fileManager: fileManager))]
        if let bundled = BundledModelResources.candidates()[.sileroVAD] { out.append(bundled) }
        let fa = MLModelConfigurationUtils.defaultModelsDirectory()
        out.append(MLModelConfigurationUtils.defaultModelsDirectory(for: .vad))
        out.append(fa.appendingPathComponent(Repo.vad.name, isDirectory: true))
        if let checkout = sourceCheckoutFolder() { out.append(checkout) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `Packaging/vad/silero-vad` in a source checkout (`swift test`, `swift run`); nil in a shipped app.
    public static func sourceCheckoutFolder(filePath: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Engine/VAD/<file> → package root
        let folder = url.appendingPathComponent("Packaging/vad/silero-vad", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// The first loadable model file in `folder` (a `.mlmodelc` with its root `coremldata.bin`).
    public func modelFile(in folder: URL, fileManager: FileManager = .default) -> URL? {
        for name in Self.knownModelFiles {
            let file = folder.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: file.appendingPathComponent("coremldata.bin").path) { return file }
        }
        return nil
    }

    public func resolve(fileManager: FileManager = .default) -> URL? {
        for folder in folders { if let f = modelFile(in: folder, fileManager: fileManager) { return f } }
        return nil
    }

    public static func resolve() -> URL? { SileroModelLocator().resolve() }
}
