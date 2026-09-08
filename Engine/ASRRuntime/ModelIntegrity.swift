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

    /// Relative paths of every `*.partial` / `*.part` / `*.etag` beneath `folder`, sorted.
    public static func scratchFiles(under folder: URL, fileManager: FileManager = .default) -> [String] {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        let prefix = folder.path + "/"
        for case let url as URL in walker where scratchExtensions.contains(url.pathExtension) {
            found.append(url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent)
        }
        return found.sorted()
    }

    /// Delete the interrupted-download debris under `folder` and return what was removed.
    ///
    /// Only the scratch files go: the whole-file siblings that *did* land stay, so a retry
    /// re-fetches one file rather than half a gigabyte. Deleting the debris is the point — a stale
    /// `.partial` is what a re-download trips over, and it is the file the user saw named in an
    /// error they could do nothing about.
    @discardableResult
    public static func removeScratchFiles(under folder: URL, fileManager: FileManager = .default) -> [String] {
        let scratch = scratchFiles(under: folder, fileManager: fileManager)
        for path in scratch { try? fileManager.removeItem(at: folder.appendingPathComponent(path)) }
        return scratch
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
