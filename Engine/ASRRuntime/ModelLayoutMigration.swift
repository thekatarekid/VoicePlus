import FluidAudio
import Foundation
import Shared

extension ModelCatalog {
    /// FluidAudio's own folder name for the repo behind `id` — the name its loaders resolve to from
    /// the *parent* of whatever directory they are handed — or nil for a model FluidAudio does not
    /// resolve through `ModelHub` at all.
    ///
    /// `folderName` must equal this wherever it is non-nil, or the load re-downloads the model into a
    /// second folder. Read from upstream rather than copied into a string here, so that a rename in
    /// FluidAudio fails a test instead of quietly costing every user another 468 MB.
    static func fluidAudioFolderName(for id: ModelID) -> String? {
        switch id {
        case .parakeetTDTv3: return Repo.parakeetV3.folderName
        case .parakeetTDTCTC110m: return Repo.parakeetTdtCtc110m.folderName
        // Loaded file-by-file out of the directory we pass (`StreamingEouAsrManager.loadModels(from:)`
        // / no FluidAudio runtime at all), so no name to agree with.
        case .parakeetEOU160, .whisperSmall: return nil
        }
    }
}

/// Moves an existing install from the pre-1.7.13 folder layout onto the one FluidAudio resolves to,
/// and reclaims the duplicate the old layout caused.
///
/// # What the old layout did
///
/// `ModelManager.folder(for:)` used to be `<root>/<ModelID.rawValue>`, i.e.
/// `Models/parakeet-tdt-0.6b-v3-coreml`. We downloaded 468 MB into it and handed that URL to
/// `AsrModels.load(from:)` — which ignores it, takes its *parent* as a models root, and asks
/// `ModelHub` for `Repo.parakeetV3.folderName`, and `folderName` strips `-coreml`. So the load
/// resolved to `Models/parakeet-tdt-0.6b-v3`, found nothing, and downloaded the whole model again.
/// The result on a real user's disk: two byte-identical 468 MB trees, one with our
/// `voiceplus-manifest.json` and one without, and ~81 s of "Warming up…" on first launch. Fast
/// duplicated 110 MB the same way.
///
/// # What this does
///
/// For every model whose folder was renamed, at most one directory survives, under the new name:
///
/// - **Only the legacy folder exists** → rename it. No download, nothing else touched.
/// - **Both exist** → the unnamed one is FluidAudio's duplicate. Keep whichever is *complete*,
///   preferring the legacy copy because it carries our manifest (the byte sizes `ModelIntegrity`
///   checks truncation against); delete the other. Either way the user re-downloads nothing.
/// - **Only the new folder exists** → already migrated, or FluidAudio's copy is all that is left.
///   Adopt it as-is.
///
/// Whichever branch runs, the surviving folder is left carrying a `voiceplus-manifest.json` before
/// this returns — see `ModelManifest.ensure`. That is not decoration: the manifest's byte counts are
/// the only thing `ModelIntegrity` can check a *truncated* file against, and a branch that keeps the
/// manifest-less copy and deletes the manifest-bearing one (which is exactly what the both-exist
/// case can do) would otherwise blind that check for that model permanently, since nothing else in
/// the app ever writes a manifest for an already-installed model.
///
/// The publish is a swap, not a delete-then-move — the same shape as `FluidAudioFetcher.fetch` — so
/// a failure at any point leaves the user with a working model under *some* name rather than none.
/// The cost of that shape is a `.superseded-<uuid>` directory left behind by a crash mid-swap;
/// `ParkedModelDirectories.sweep` is what eventually collects it.
public enum ModelLayoutMigration {
    /// What happened to one model. Values are logged and asserted on; keep them stable.
    public enum Outcome: String, Equatable, Sendable {
        /// Legacy folder renamed onto the new name; nothing was in the way.
        case renamed
        /// Legacy folder kept, FluidAudio's duplicate at the new name deleted.
        case replacedDuplicate
        /// The copy at the new name was kept and the legacy folder deleted.
        case adoptedExisting
        /// Nothing to do: no legacy folder for this model.
        case nothingToDo
        /// A move or delete failed; both folders are still there and the model still loads.
        case failed
    }

    public struct Result: Equatable, Sendable {
        public var id: ModelID
        public var outcome: Outcome
        /// Bytes freed by deleting a duplicate. 0 for a plain rename.
        public var reclaimedBytes: Int64
        /// What it took to leave the surviving folder with a `voiceplus-manifest.json`. Every branch
        /// that keeps a model ends by settling this; see `ModelManifest.ensure`.
        public var manifest: ModelManifest.EnsureOutcome
        public init(id: ModelID, outcome: Outcome, reclaimedBytes: Int64 = 0,
                    manifest: ModelManifest.EnsureOutcome = .alreadyPresent) {
            self.id = id; self.outcome = outcome; self.reclaimedBytes = reclaimedBytes
            self.manifest = manifest
        }
    }

    /// Run the migration over `root`. Cheap and idempotent: a `stat` per model on an already-migrated
    /// install. Never touches directories that are not a `ModelID`'s current or legacy folder, and
    /// never touches anything outside `root` — FluidAudio's own cache is somebody else's directory.
    @discardableResult
    public static func migrate(root: URL, fileManager: FileManager = .default) -> [Result] {
        ModelID.allCases.compactMap { id in
            let result = migrate(id, root: root, fileManager: fileManager)
            // A no-op is only worth reporting when it healed something anyway — a model left with no
            // manifest by an earlier build's `adoptedExisting`, which nothing else ever repairs.
            guard result.outcome != .nothingToDo else {
                return [.rebuilt, .adopted].contains(result.manifest) ? result : nil
            }
            return result
        }
    }

    static func migrate(_ id: ModelID, root: URL, fileManager: FileManager) -> Result {
        let d = ModelCatalog.descriptor(id)
        let target = ModelCatalog.folder(for: id, in: root)
        guard let legacy = d.legacyFolderNames
            .map({ root.appendingPathComponent($0, isDirectory: true) })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else {
            // Nothing to move. Still settle the manifest: an install that already went through the
            // 1.7.13 migration's `adoptedExisting` branch kept FluidAudio's manifest-less copy and
            // deleted ours, and would otherwise stay un-checkable for truncation forever.
            return Result(id: id, outcome: .nothingToDo,
                          manifest: ModelManifest.ensure(for: d, at: target, fileManager: fileManager))
        }

        guard fileManager.fileExists(atPath: target.path) else {
            guard move(legacy, to: target, fileManager) else { return Result(id: id, outcome: .failed) }
            Log.engine.notice("model layout: renamed \(legacy.lastPathComponent) → \(target.lastPathComponent)")
            return Result(id: id, outcome: .renamed,
                          manifest: ModelManifest.ensure(for: d, at: target, fileManager: fileManager))
        }

        // Both are here. One of them is the duplicate download this migration exists to undo.
        let legacyComplete = ModelIntegrity.isComplete(d, at: legacy, fileManager: fileManager)
        let targetComplete = ModelIntegrity.isComplete(d, at: target, fileManager: fileManager)
        // Prefer the legacy copy: identical bytes, plus the manifest that makes truncation
        // detectable later. Only step aside for it when it is the broken one.
        if !legacyComplete && targetComplete {
            // Salvage the manifest *before* the copy carrying it is deleted. Until this line the
            // branch threw away the only record of what the model's files are supposed to weigh and
            // wrote nothing in its place, which permanently disabled `ModelIntegrity`'s truncation
            // check for this model — the reason a half-downloaded model reported installed in 1.7.9.
            let manifest = ModelManifest.ensure(for: d, at: target, donor: legacy, fileManager: fileManager)
            let freed = directorySize(legacy, fileManager)
            guard (try? fileManager.removeItem(at: legacy)) != nil else { return Result(id: id, outcome: .failed, manifest: manifest) }
            Log.engine.notice("model layout: adopted \(target.lastPathComponent) (manifest \(manifest.rawValue)), removed the incomplete \(legacy.lastPathComponent) (\(freed) bytes)")
            return Result(id: id, outcome: .adoptedExisting, reclaimedBytes: freed, manifest: manifest)
        }

        let freed = directorySize(target, fileManager)
        let parked = target.appendingPathExtension("superseded-\(UUID().uuidString)")
        guard (try? fileManager.moveItem(at: target, to: parked)) != nil else { return Result(id: id, outcome: .failed) }
        guard move(legacy, to: target, fileManager) else {
            try? fileManager.moveItem(at: parked, to: target)   // put the user back where they were
            return Result(id: id, outcome: .failed)
        }
        // The kept copy is normally the manifest-bearing one, so this is a single file read. When it
        // is not, the copy about to be deleted is still on disk and can donate.
        let manifest = ModelManifest.ensure(for: d, at: target, donor: parked, fileManager: fileManager)
        try? fileManager.removeItem(at: parked)
        Log.engine.notice("model layout: \(legacy.lastPathComponent) → \(target.lastPathComponent), removed the duplicate download (\(freed) bytes reclaimed, manifest \(manifest.rawValue))")
        return Result(id: id, outcome: .replacedDuplicate, reclaimedBytes: freed, manifest: manifest)
    }

    private static func move(_ from: URL, to: URL, _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: from, to: to)
            return true
        } catch {
            Log.engine.error("model layout: could not move \(from.lastPathComponent) → \(to.lastPathComponent): \(error)")
            return false
        }
    }

    /// Total bytes of regular files under `url`. Only used to report what was reclaimed.
    static func directorySize(_ url: URL, _ fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            let rv = try? file.resourceValues(forKeys: Set(keys))
            guard rv?.isRegularFile == true else { continue }
            total += Int64(rv?.fileSize ?? 0)
        }
        return total
    }
}
