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
