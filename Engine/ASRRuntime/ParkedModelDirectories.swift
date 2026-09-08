import FluidAudio
import Foundation
import Shared

/// Deletes the model directories VoicePlus *parks* and then fails to collect.
///
/// # Why there is anything to collect
///
/// Two places replace an installed model, and both do it as a swap rather than a delete-then-move,
/// so that a failure halfway leaves the user with a working model under some name instead of none:
///
/// - `FluidAudioFetcher.fetch` parks the outgoing copy as `<folder>.replaced-<uuid>`.
/// - `ModelLayoutMigration` parks the duplicate it is undoing as `<folder>.superseded-<uuid>`.
///
/// Each removes its own park immediately afterwards — *if it gets that far*. Killed mid-swap (quit,
/// crash, power loss, the migration that now runs on every launch), the park survives, and until
/// this existed nothing ever looked at it again: 468 MB stranded under a name no presence check
/// reads and `ModelManager.repair` never visits. It is not even visible as a model in Settings,
/// because it is not one.
///
/// # Why deleting is delicate
///
/// A park is only ever safe to delete once the process that made it is done with it, and there is no
/// handshake to ask. So the rules below are all conservative, and each one is load-bearing:
///
/// 1. **Only direct children of the models root.** No recursion, and never a path assembled from
///    anything but `root` plus one name read out of it.
/// 2. **Only names this app itself parks**: `<a model folder name we own>.<kind>-<a parsable UUID>`.
///    A user's unrelated `qwen3-asr-0.6b`, our own `.staging-<id>` (where a cancelled download's
///    resumable `.partial` files deliberately live), and any real model folder all fail this.
/// 3. **Never `~/Library/Application Support/FluidAudio/Models`.** That is a different application's
///    directory that we only ever read from; the guard is explicit rather than implied.
/// 4. **Never symlinks** — following one would delete something outside the root.
/// 5. **A grace period.** A park is live for exactly as long as one `rename(2)` plus one `unlink`
///    sweep of the tree, so anything still young might belong to a process mid-swap right now.
///    Age is measured from the *newest* of creation, content-modification and attribute-modification
///    time. The last of those is the one that matters and the reason this is not just `mtime`: a
///    rename bumps `st_ctime` and leaves `st_mtime` and birth time alone, so a park made by moving a
///    year-old model tree reads as a year old by `mtime` and as seconds old by `ctime`. Taking the
///    maximum means a fresh park is always young, whatever the tree inside it claims.
/// 6. **Claim before deleting.** Each victim is first renamed to `.sweeping-<uuid>` — one atomic
///    step that exactly one racing sweeper can win — and only then removed. A reader holding an open
///    descriptor keeps reading its own inode, POSIX-style, rather than watching files vanish under a
///    path it is walking. `sweeping` is itself a recognised park kind, so a claim interrupted before
///    the delete is collected by the next sweep instead of becoming new litter.
public enum ParkedModelDirectories {
    /// The suffixes we park under. `sweeping` is this sweeper's own claim marker (rule 6).
    static let kinds: Set<String> = ["superseded", "replaced", "sweeping"]

    /// How long a parked directory must have sat untouched before it is fair game. Generous on
    /// purpose: the cost of waiting is disk space we were going to reclaim anyway, and the cost of
    /// being wrong is deleting a model out from under a running process.
    public static let defaultGracePeriod: TimeInterval = 15 * 60

    public struct Swept: Equatable, Sendable {
        public var name: String
        public var bytes: Int64
        public init(name: String, bytes: Int64) { self.name = name; self.bytes = bytes }
    }

    /// Remove every stale parked directory directly inside `root`. Returns what went.
    ///
    /// Cheap on the normal install: one `contentsOfDirectory`, and nothing matches.
    @discardableResult
    public static func sweep(root: URL,
                             gracePeriod: TimeInterval = defaultGracePeriod,
                             now: Date = Date(),
                             fileManager: FileManager = .default) -> [Swept] {
        guard isSweepableRoot(root) else {
            Log.engine.error("parked models: refusing to sweep \(root.path) — that is not our models root")
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey,
                                      .contentModificationDateKey, .attributeModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                options: [.skipsSubdirectoryDescendants]) else { return [] }
        var swept: [Swept] = []
        for entry in entries {
            guard let base = parkedFolderName(entry.lastPathComponent) else { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let touched = [values.creationDate, values.contentModificationDate, values.attributeModificationDate]
                .compactMap { $0 }.max() ?? .distantPast
            guard now.timeIntervalSince(touched) >= gracePeriod else {
                Log.engine.info("parked models: leaving \(entry.lastPathComponent) — parked too recently to be sure nobody is using it")
                continue
            }
            let bytes = ModelLayoutMigration.directorySize(entry, fileManager)
            // Claim it with an atomic rename before removing anything (rule 6).
            let claimed = root.appendingPathComponent("\(base).sweeping-\(UUID().uuidString)", isDirectory: true)
            guard (try? fileManager.moveItem(at: entry, to: claimed)) != nil else {
                Log.engine.info("parked models: \(entry.lastPathComponent) went away before we could claim it")
                continue
            }
            guard (try? fileManager.removeItem(at: claimed)) != nil else {
                Log.engine.error("parked models: could not remove \(entry.lastPathComponent); it will be retried next launch")
                continue
            }
            swept.append(Swept(name: entry.lastPathComponent, bytes: bytes))
        }
        if !swept.isEmpty {
            let total = swept.reduce(0) { $0 + $1.bytes }
            Log.engine.notice("parked models: removed \(swept.count) leftover director\(swept.count == 1 ? "y" : "ies") (\(total) bytes reclaimed): \(swept.map(\.name).joined(separator: ", "))")
        }
        return swept
    }

    /// The model folder name behind a parked directory name, or nil if this is not one of ours.
    ///
    /// Parsed from the right, because model folder names contain dots of their own
    /// (`parakeet-tdt-0.6b-v3`): the last path extension is the whole `<kind>-<uuid>` suffix, and a
    /// UUID has no dots, so `deletingPathExtension` gives the base name back exactly.
    static func parkedFolderName(_ name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        let suffix = url.pathExtension
        guard let dash = suffix.firstIndex(of: "-") else { return nil }
        guard kinds.contains(String(suffix[..<dash])),
              UUID(uuidString: String(suffix[suffix.index(after: dash)...])) != nil else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        return ownedFolderNames.contains(base) ? base : nil
    }

    /// Every directory name this app has ever called a model of its own — current and legacy. Legacy
    /// names are included so that a park made by an older build is still recognisably ours.
    static let ownedFolderNames: Set<String> = Set(
        ModelID.allCases.flatMap { id -> [String] in
            let d = ModelCatalog.descriptor(id)
            return [d.folderName] + d.legacyFolderNames
        })

    /// `root` must be a directory we own. Explicitly not FluidAudio's cache: `ModelManager` reads
    /// models out of `~/Library/Application Support/FluidAudio/Models` as a warm-start courtesy, and
    /// deleting anything in another application's directory is never ours to do.
    static func isSweepableRoot(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let foreign = MLModelConfigurationUtils.defaultModelsDirectory()
            .standardizedFileURL.resolvingSymlinksInPath().path
        return path != foreign && !path.hasPrefix(foreign + "/")
    }
}
