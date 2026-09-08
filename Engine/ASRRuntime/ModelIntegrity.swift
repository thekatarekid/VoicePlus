import Foundation
import Shared

/// Is what is on disk a *complete, loadable* model — not merely a directory with the right name?
///
/// This exists because of the 1.7.9 report: onboarding downloaded the Fast tier, said "Using
/// Parakeet TDT-CTC 110M (tiny)", and the first "Dictate now" died with
///
///     The file "weight.bin.partial" doesn't exist.
///
/// `weight.bin.partial` is not ours. It is FluidAudio's `FileDownloader` scratch file: it streams a
/// HuggingFace body into `<destination>.partial` (so a dropped connection resumes by byte range) and
/// then moves it onto `<destination>`. A `.partial` still sitting inside a `.mlmodelc` bundle means
/// exactly one thing — that file never finished.
///
/// `ModelManager` used to answer "is this model installed?" with
/// `FileManager.fileExists(atPath:)` over the descriptor's `requiredPaths`. Every one of those paths
/// is a `.mlmodelc` *directory*, and a directory exists the moment the downloader starts writing the
/// first file into it. So a half-downloaded bundle reported installed, the tier picker said the model
/// was ready, and the failure only arrived at first use — as a raw Cocoa file error.
///
/// FluidAudio hit the same class of bug upstream (issue #819) and fixed it the same way: judge the
/// cache per required file, and treat a leftover `*.partial` as "incomplete", never as "warm".
public enum ModelIntegrity {
    /// Download scratch suffixes that must never survive into an installed model.
    /// `partial`/`etag` are FluidAudio's `FileDownloader`; `part` is our own `HFDownloader`.
    public static let scratchExtensions: Set<String> = ["partial", "part", "etag"]

    /// Human-readable reasons this folder is not a usable model. Empty means it is.
    ///
    /// Deliberately cheap — `stat` and one directory walk, no hashing — because it runs on every
    /// presence check, including the ones behind a hotkey press. `ModelManifest.verify` is the
    /// expensive, re-hash-everything cousin and stays opt-in.
    public static func problems(for descriptor: ModelDescriptor, at folder: URL,
                               fileManager: FileManager = .default) -> [String] {
        var problems: [String] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            return ["\(folder.lastPathComponent) is not on disk"]
        }
        guard isDirectory.boolValue else {
            return ["\(folder.lastPathComponent) is a file, not a model folder"]
        }

        // 1. Interrupted-download debris anywhere beneath the folder. This is the check that would
        //    have caught the reported bug before the user ever pressed the key.
        for scratch in scratchFiles(under: folder, fileManager: fileManager).prefix(3) {
            problems.append("\(scratch) is an unfinished download")
        }

        // 2. Every file the loader needs.
        for path in descriptor.requiredPaths {
            let url = folder.appendingPathComponent(path)
            var pathIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &pathIsDirectory) else {
                problems.append("\(path) is missing")
                continue
            }
            // A CoreML bundle without its root `coremldata.bin` cannot be opened, however many
            // weight files landed. Only applied when the path really is a directory: a fixture that
            // stands a plain file in for a bundle is a test's business, not a corruption report.
            if path.hasSuffix(".mlmodelc"), pathIsDirectory.boolValue,
               !fileManager.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path) {
                problems.append("\(path) is missing coremldata.bin")
            }
        }

        // 3. Truncation, when we have something to compare against. The manifest is written at the
        //    end of a successful install, so its byte counts are the sizes that actually worked.
        if let manifest = ModelManifest.load(from: folder) {
            for short in manifest.undersizedFiles(in: folder, fileManager: fileManager).prefix(3) {
                problems.append(short)
            }
        }
        return problems
    }

    public static func isComplete(_ descriptor: ModelDescriptor, at folder: URL,
                                  fileManager: FileManager = .default) -> Bool {
        problems(for: descriptor, at: folder, fileManager: fileManager).isEmpty
    }

    /// Every `*.partial` / `*.part` / `*.etag` beneath `folder`, as (path relative to `folder`, URL),
    /// sorted by path.
    ///
    /// Walked by hand rather than by `FileManager.enumerator` + prefix arithmetic. On macOS the same
    /// file has two spellings (`/var/...` and `/private/var/...`) and `resolvingSymlinksInPath`
    /// rewrites between them, so subtracting one path string from another silently produced bare
    /// filenames — which turned "delete the debris" into a no-op and left the bug in place.
    static func scratchEntries(under folder: URL, fileManager: FileManager = .default) -> [(path: String, url: URL)] {
        var found: [(path: String, url: URL)] = []
        func walk(_ directory: URL, _ prefix: [String]) {
            let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in contents {
                let components = prefix + [url.lastPathComponent]
                if scratchExtensions.contains(url.pathExtension) {
                    found.append((components.joined(separator: "/"), url))
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walk(url, components)
                }
            }
        }
        walk(folder, [])
        return found.sorted { $0.path < $1.path }
    }

    /// Paths of the scratch files beneath `folder`, relative to it, sorted.
    public static func scratchFiles(under folder: URL, fileManager: FileManager = .default) -> [String] {
        scratchEntries(under: folder, fileManager: fileManager).map(\.path)
    }

    /// Delete the interrupted-download debris under `folder`, along with the CoreML bundle each
    /// piece of debris sits in, and return what was removed (paths relative to `folder`).
    ///
    /// Removing the enclosing `.mlmodelc` matters as much as removing the `.partial`. A bundle
    /// caught mid-download is missing an interior weight file that no `requiredPaths` list names,
    /// so deleting only the scratch file leaves a bundle that passes every check and still cannot
    /// load — the original bug, one step further along. Dropping the bundle makes the model report
    /// *not installed*, which is both true and the thing that gets it re-downloaded. Its intact
    /// siblings stay, so a retry costs one bundle rather than the whole model.
    @discardableResult
    public static func removeIncompleteParts(under folder: URL, fileManager: FileManager = .default) -> [String] {
        var removed: Set<String> = []
        for entry in scratchEntries(under: folder, fileManager: fileManager) {
            // The outermost `.mlmodelc` between `folder` and the scratch file, if any.
            var components: [String] = []
            var target = entry.url
            for component in entry.path.split(separator: "/").map(String.init) {
                components.append(component)
                if component.hasSuffix(".mlmodelc") {
                    target = components.reduce(folder) { $0.appendingPathComponent($1) }
                    break
                }
            }
            let relative = target == entry.url ? entry.path : components.joined(separator: "/")
            guard (try? fileManager.removeItem(at: target)) != nil else { continue }
            removed.insert(relative)
        }
        return removed.sorted()
    }

    /// Delete only the interrupted-download scratch files under `folder`, leaving every real file
    /// in place. For staging directories, where the surrounding tree is not yet anybody's model.
    @discardableResult
    public static func removeScratchFiles(under folder: URL, fileManager: FileManager = .default) -> [String] {
        var removed: [String] = []
        for entry in scratchEntries(under: folder, fileManager: fileManager) {
            guard (try? fileManager.removeItem(at: entry.url)) != nil else { continue }
            removed.append(entry.path)
        }
        return removed
    }
}

public extension ModelManifest {
    /// Manifest entries that are missing or smaller than the size recorded at install time,
    /// as `"<path> is truncated (<local>/<recorded> bytes)"`. Cheap: `stat`, no hashing.
    func undersizedFiles(in folder: URL, fileManager: FileManager = .default) -> [String] {
        files.compactMap { entry in
            let path = folder.appendingPathComponent(entry.path).path
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64
            guard let size else { return "\(entry.path) is missing" }
            guard size < entry.size else { return nil }
            return "\(entry.path) is truncated (\(size)/\(entry.size) bytes)"
        }.sorted()
    }
}

// MARK: - How much we actually know

public extension ModelIntegrity {
    /// What a check of a model folder is *entitled* to conclude.
    ///
    /// The distinction `problems(for:at:)` alone cannot make: an empty problem list means "nothing
    /// we can see is wrong", and without a manifest the set of things we can see is strictly
    /// smaller. `voiceplus-manifest.json` carries the byte count every file had when the install
    /// succeeded, and it is the only reason a *silently truncated* file — right name, right place,
    /// half the bytes — is detectable at all. A folder with no manifest can be structurally sound
    /// and still be short 200 MB, and nothing here would know.
    ///
    /// So a manifest-less model reports `.unverifiable`, never `.verified`. Callers that only need
    /// "can I load this?" ask `isUsable`; callers reporting on integrity must not flatten the two.
    enum Verification: Equatable, Sendable {
        /// Structurally complete *and* covered by a manifest, so recorded byte counts agreed too.
        case verified
        /// Complete as far as the checks that are possible without a manifest can tell.
        case unverifiable(reason: String)
        /// Not loadable. Carries `problems(for:at:)`'s findings, in the order it found them.
        case incomplete([String])

        /// Is this a model we would hand to CoreML? True for `.verified` and `.unverifiable`.
        public var isUsable: Bool { if case .incomplete = self { return false }; return true }
        /// Only `.verified`. Deliberately not true for `.unverifiable` — that is the whole point.
        public var isManifestBacked: Bool { self == .verified }
        /// One line for the log.
        public var summary: String {
            switch self {
            case .verified: return "verified against its manifest"
            case .unverifiable(let reason): return "usable but unverified — \(reason)"
            case .incomplete(let problems): return "incomplete: \(problems.joined(separator: ", "))"
            }
        }
    }

    /// `problems(for:at:)` plus the honest caveat about what was not checked.
    static func assess(_ descriptor: ModelDescriptor, at folder: URL,
                       fileManager: FileManager = .default) -> Verification {
        let problems = problems(for: descriptor, at: folder, fileManager: fileManager)
        guard problems.isEmpty else { return .incomplete(problems) }
        guard ModelManifest.load(from: folder) != nil else {
            return .unverifiable(reason: "no \(ModelManifest.fileName), so truncated files cannot be detected")
        }
        return .verified
    }
}

// MARK: - Guaranteeing a manifest exists

public extension ModelManifest {
    /// What `ensure(for:at:donor:)` did. Logged and asserted on; keep the raw values stable.
    enum EnsureOutcome: String, Equatable, Sendable {
        /// A manifest was already there. The overwhelmingly common case; costs one file read.
        case alreadyPresent
        /// Taken from `donor` — the copy of the same model we were about to throw away — after
        /// checking that every file it records is present at exactly the recorded size.
        case adopted
        /// Rebuilt by hashing what is on disk, because no usable manifest existed anywhere.
        case rebuilt
        /// The folder is not a complete model. Writing a manifest here would record the damage as
        /// if it were the intended contents, which is worse than having none.
        case notRebuilt
        /// There is nothing at that path.
        case noFolder
        /// Hashing or writing failed. The model still loads; integrity checking stays degraded.
        case failed
    }

    /// Guarantee that `folder` ends up with a `voiceplus-manifest.json`.
    ///
    /// Exists because a migration that *keeps the manifest-less copy of a model and deletes the
    /// manifest-bearing one* silently and permanently blinds `ModelIntegrity`'s truncation check for
    /// that model: nothing else in the app ever writes a manifest for an already-installed model, so
    /// the degradation never heals. See `ModelLayoutMigration`.
    ///
    /// Order of preference is cost-ordered and truth-ordered at once:
    ///
    /// 1. A manifest already there — nothing to do.
    /// 2. `donor`'s manifest, if every file it records is present in `folder` at *exactly* the
    ///    recorded size. The two folders in this migration are byte-identical copies of one
    ///    download, so the donor's counts are the counts, and adopting them costs a `stat` per file
    ///    instead of a SHA-256 pass over 468 MB. An exact whole-tree size match is strong evidence;
    ///    a single byte off anywhere and we fall through to rebuilding rather than record a guess.
    /// 3. Rebuild with `ModelManifest.build` — the same writer both fetchers use, never a second one.
    ///
    /// Never writes a manifest for a folder `ModelIntegrity` calls incomplete: a manifest built over
    /// a truncated file records the truncated length as correct, which converts a detectable fault
    /// into a permanent lie.
    @discardableResult
    static func ensure(for descriptor: ModelDescriptor, at folder: URL, donor: URL? = nil,
                       fileManager: FileManager = .default) -> EnsureOutcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .noFolder
        }
        if load(from: folder) != nil { return .alreadyPresent }

        if let donor, let candidate = load(from: donor), candidate.modelID == descriptor.id,
           candidate.describesExactly(folder, fileManager: fileManager) {
            do {
                try candidate.save(to: folder)
                return .adopted
            } catch {
                Log.engine.error("manifest: could not adopt \(donor.lastPathComponent)'s manifest into \(folder.lastPathComponent): \(error)")
            }
        }

        guard ModelIntegrity.isComplete(descriptor, at: folder, fileManager: fileManager) else {
            Log.engine.notice("manifest: not writing one for \(folder.lastPathComponent) — it is not a complete model")
            return .notRebuilt
        }
        do {
            try build(modelID: descriptor.id, hfRepo: descriptor.hfRepo, folder: folder,
                      fileManager: fileManager).save(to: folder)
            Log.engine.notice("manifest: rebuilt \(fileName) for \(folder.lastPathComponent) from what is on disk")
            return .rebuilt
        } catch {
            Log.engine.error("manifest: could not rebuild one for \(folder.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// Is every file this manifest records present in `folder` at exactly the recorded size?
    /// Stat-only, and deliberately exact rather than `>=`: this decides whether a manifest may be
    /// adopted by a *different* directory, so "close enough" is not a standard worth having.
    func describesExactly(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        !files.isEmpty && files.allSatisfy { entry in
            let path = folder.appendingPathComponent(entry.path).path
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64
            return size == entry.size
        }
    }
}
