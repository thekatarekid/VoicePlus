import Foundation

/// V5 V1 — the public evaluation sets (V5 §V table) and their on-demand downloaders. Audio lands in
/// the eval cache (`~/Library/Application Support/VoicePlus/Eval/<set>/`), never in the repo; the
/// downloader writes `<cache>/<set>/manifest.json` next to it.
///
/// `fetchable` sets download and build a manifest unattended. `gated` sets need the owner to accept
/// a licence / log in once (T1 note). `large` sets are catalogued with their source but are not
/// pulled by default (disk budget, V5 §0); a subset recipe is recorded in `note`.
public struct DatasetEntry: Equatable, Sendable {
    public enum Access: String, Sendable { case fetchable, gated, large }
    public var name: String
    public var condition: String
    public var licence: String
    public var source: String
    public var access: Access
    public var sizeNote: String
    public var note: String
}

public enum DatasetCatalog {
    static let librispeech = "https://www.openslr.org/resources/12/"
    static let librispeechPC = "https://www.openslr.org/resources/145/manifests.tar.gz"
    static let fleurs = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/"

    public static let entries: [DatasetEntry] = [
        .init(name: "librispeech-test-clean", condition: "clean read", licence: "CC-BY-4.0", source: librispeech + "test-clean.tar.gz",
              access: .fetchable, sizeNote: "346 MB", note: "2620 utterances"),
        .init(name: "librispeech-test-other", condition: "clean read (harder)", licence: "CC-BY-4.0", source: librispeech + "test-other.tar.gz",
              access: .fetchable, sizeNote: "328 MB", note: "2939 utterances"),
        .init(name: "librispeech-pc-test-clean", condition: "punctuation + casing", licence: "CC-BY-4.0", source: librispeechPC,
              access: .fetchable, sizeNote: "26 MB manifests + LibriSpeech audio", note: "score with --raw"),
        .init(name: "librispeech-pc-test-other", condition: "punctuation + casing", licence: "CC-BY-4.0", source: librispeechPC,
              access: .fetchable, sizeNote: "26 MB manifests + LibriSpeech audio", note: "score with --raw"),
        .init(name: "fleurs-en_us", condition: "multilingual (en)", licence: "CC-BY-4.0", source: fleurs + "en_us/",
              access: .fetchable, sizeNote: "290 MB", note: "test split"),
        .init(name: "fleurs-hi_in", condition: "multilingual (hi)", licence: "CC-BY-4.0", source: fleurs + "hi_in/",
              access: .fetchable, sizeNote: "~250 MB", note: "test split"),
        .init(name: "earnings22", condition: "real calls, entities", licence: "CC-BY-SA-4.0",
              source: "https://github.com/revdotcom/speech-datasets/tree/main/earnings22", access: .large, sizeNote: "~14 GB (125 calls)",
              note: "subset recipe: 5 calls, segmented by the HF `distil-whisper/earnings22` chunked test split"),
        .init(name: "voices-subset", condition: "far-field + TV/music/babble", licence: "CC-BY-4.0",
              source: "https://iqtlabs.github.io/voices/", access: .large, sizeNote: "~250 GB full", note: "subset: dev distant mics, 1 room"),
        .init(name: "notsofar1", condition: "meetings", licence: "CC-BY-4.0", source: "https://github.com/microsoft/NOTSOFAR",
              access: .large, sizeNote: "~100 GB", note: "subset: eval set, single-channel"),
        .init(name: "ami", condition: "meetings / diarization", licence: "CC-BY-4.0", source: "https://groups.inf.ed.ac.uk/ami/corpus/",
              access: .large, sizeNote: "~100 GB", note: "subset: test IHM-mix, 4 meetings (HF edinburghcstr/ami)"),
        .init(name: "voxconverse-test", condition: "diarization", licence: "CC-BY-4.0", source: "https://github.com/joonson/voxconverse",
              access: .large, sizeNote: "~3 GB", note: "RTTMs on GitHub; subset of 10 files"),
        .init(name: "common-voice-en-IN", condition: "Indian-accented English", licence: "CC0", source: "https://commonvoice.mozilla.org/",
              access: .gated, sizeNote: "per-locale tarball", note: "owner downloads once (account + terms)"),
        .init(name: "common-voice-hi", condition: "Hindi", licence: "CC0", source: "https://commonvoice.mozilla.org/",
              access: .gated, sizeNote: "per-locale tarball", note: "owner downloads once (account + terms)"),
        .init(name: "mucs2021", condition: "Hinglish", licence: "CC-BY-4.0", source: "https://www.openslr.org/104/",
              access: .large, sizeNote: "~10 GB", note: "subset: Hindi-English test"),
        .init(name: "hiacc", condition: "Hinglish", licence: "verify", source: "https://huggingface.co/datasets (HiACC)",
              access: .gated, sizeNote: "unknown", note: "licence to verify before use"),
        .init(name: "musan", condition: "noise (V3)", licence: "CC-BY-4.0", source: "https://www.openslr.org/17/ (FluidInference mirror)",
              access: .large, sizeNote: "11 GB", note: "V3 pulls the noise subset only"),
        .init(name: "svarah", condition: "Indian-accented English", licence: "CC-BY-4.0", source: "https://github.com/AI4Bharat/Svarah",
              access: .gated, sizeNote: "~1 GB", note: "gated: owner downloads once (T1)"),
    ]

    public static func entry(_ name: String) -> DatasetEntry? { entries.first { $0.name == name } }

    public static func listing() -> String {
        entries.map { "\($0.name)\t\($0.access.rawValue)\t\($0.sizeNote)\t\($0.licence)\t\($0.condition)" }.joined(separator: "\n")
    }
}

/// Downloads and unpacks archives; injectable for tests.
public protocol DatasetTransport: Sendable {
    func download(_ url: URL, to file: URL) async throws
    func untar(_ archive: URL, into dir: URL) throws
}

public struct URLSessionTransport: DatasetTransport {
    public init() {}
    public func download(_ url: URL, to file: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EvalError.downloadFailed("\(url) → \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }
    public func untar(_ archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", archive.path, "-C", dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw EvalError.downloadFailed("tar exit \(p.terminationStatus) on \(archive.lastPathComponent)") }
    }
}

public struct DatasetFetcher: Sendable {
    public var paths: EvalPaths
    public var transport: any DatasetTransport
    /// Refuse downloads that would leave less than this much free disk (V5 §0: keep ≥ 8 GB).
    public var minimumFreeBytes: Int64

    public init(paths: EvalPaths = EvalPaths(), transport: any DatasetTransport = URLSessionTransport(),
                minimumFreeBytes: Int64 = 8 * 1_073_741_824) {
        self.paths = paths; self.transport = transport; self.minimumFreeBytes = minimumFreeBytes
    }

    /// Downloads (if needed) and writes `<cache>/<set>/manifest.json`. Returns the manifest.
    @discardableResult
    public func fetch(_ set: String) async throws -> EvalManifest {
        guard let entry = DatasetCatalog.entry(set) else { throw EvalError.manifestMissing(set, hint: "unknown set") }
        guard entry.access == .fetchable else {
            throw EvalError.downloadFailed("\(set) is \(entry.access.rawValue) (\(entry.sizeNote)): \(entry.note) — source \(entry.source)")
        }
        let fm = FileManager.default
        let setDir = paths.cacheDirectory.appendingPathComponent(set, isDirectory: true)
        try fm.createDirectory(at: setDir, withIntermediateDirectories: true)
        let manifest: EvalManifest
        if set.hasPrefix("librispeech-pc-") {
            let split = String(set.dropFirst("librispeech-pc-".count))
            let audio = try await ensureLibriSpeech(split: split)
            let pcDir = paths.cacheDirectory.appendingPathComponent("librispeech-pc", isDirectory: true)
            if !fm.fileExists(atPath: pcDir.appendingPathComponent("\(split).json").path) {
                try await downloadAndUntar(URL(string: DatasetCatalog.librispeechPC)!, into: pcDir)
            }
            manifest = try ManifestBuilders.libriSpeechPC(set: set, nemoManifest: try Self.find("\(split).json", under: pcDir),
                                                          audioRoot: audio, cache: paths.cacheDirectory)
        } else if set.hasPrefix("librispeech-") {
            let split = String(set.dropFirst("librispeech-".count))
            let audio = try await ensureLibriSpeech(split: split)
            manifest = try ManifestBuilders.libriSpeech(set: set, splitDirectory: audio, cache: paths.cacheDirectory)
        } else if set.hasPrefix("fleurs-") {
            let lang = String(set.dropFirst("fleurs-".count))
            let base = URL(string: DatasetCatalog.fleurs + lang + "/")!
            let tsv = setDir.appendingPathComponent("test.tsv")
            if !fm.fileExists(atPath: tsv.path) { try await transport.download(base.appendingPathComponent("test.tsv"), to: tsv) }
            if !fm.fileExists(atPath: setDir.appendingPathComponent("test").path) {
                try await downloadAndUntar(base.appendingPathComponent("audio/test.tar.gz"), into: setDir)
            }
            manifest = try ManifestBuilders.fleurs(set: set, language: lang, tsv: tsv, audioRoot: "\(set)/test")
        } else {
            throw EvalError.downloadFailed("no downloader for \(set)")
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: setDir.appendingPathComponent("manifest.json"))
        return manifest
    }

    /// `<cache>/librispeech/LibriSpeech/<split>`; downloads the openslr tarball when absent.
    func ensureLibriSpeech(split: String) async throws -> URL {
        let root = paths.cacheDirectory.appendingPathComponent("librispeech", isDirectory: true)
        let dir = root.appendingPathComponent("LibriSpeech/\(split)", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        try await downloadAndUntar(URL(string: DatasetCatalog.librispeech + "\(split).tar.gz")!, into: root)
        return dir
    }

    func downloadAndUntar(_ url: URL, into dir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < minimumFreeBytes {
            throw EvalError.downloadFailed("only \(free / 1_073_741_824) GB free; need ≥ \(minimumFreeBytes / 1_073_741_824) GB")
        }
        let archive = dir.appendingPathComponent(url.lastPathComponent)
        try await transport.download(url, to: archive)
        defer { try? fm.removeItem(at: archive) }
        try transport.untar(archive, into: dir)
    }

    static func find(_ name: String, under dir: URL) throws -> URL {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL { if u.lastPathComponent == name { return u } }
        throw EvalError.downloadFailed("\(name) not found under \(dir.path)")
    }
}

/// Turn each dataset's native layout into an `EvalManifest`.
public enum ManifestBuilders {
    /// LibriSpeech: `<spk>/<chapter>/<spk>-<chapter>.trans.txt` lines `ID TEXT`, audio `ID.flac`.
    public static func libriSpeech(set: String, splitDirectory: URL, cache: URL) throws -> EvalManifest {
        var items: [EvalItem] = []
        let e = FileManager.default.enumerator(at: splitDirectory, includingPropertiesForKeys: nil)
        var transcripts: [URL] = []
        while let u = e?.nextObject() as? URL { if u.lastPathComponent.hasSuffix(".trans.txt") { transcripts.append(u) } }
        for t in transcripts.sorted(by: { $0.path < $1.path }) {
            let rel = relative(t.deletingLastPathComponent(), to: splitDirectory)
            for line in try String(contentsOf: t, encoding: .utf8).split(separator: "\n") {
                guard let sp = line.firstIndex(of: " ") else { continue }
                let id = String(line[..<sp])
                items.append(EvalItem(id: id, audio: "\(rel)/\(id).flac", reference: String(line[line.index(after: sp)...]),
                                      tags: ["clean-read"]))
            }
        }
        return EvalManifest(set: set, audioRoot: relative(splitDirectory, to: cache), licence: "CC-BY-4.0",
                            source: DatasetCatalog.entry(set)?.source, items: items)
    }

    /// LibriSpeech-PC: NeMo JSON-lines (`audio_filepath`, `text`) over LibriSpeech audio.
    public static func libriSpeechPC(set: String, nemoManifest: URL, audioRoot: URL, cache: URL) throws -> EvalManifest {
        struct Line: Decodable { let audio_filepath: String; let text: String }
        var items: [EvalItem] = []
        for raw in try String(contentsOf: nemoManifest, encoding: .utf8).split(separator: "\n") where !raw.isEmpty {
            let l = try JSONDecoder().decode(Line.self, from: Data(raw.utf8))
            let file = URL(fileURLWithPath: l.audio_filepath).lastPathComponent
            let id = (file as NSString).deletingPathExtension
            let parts = id.split(separator: "-")
            guard parts.count == 3 else { continue }
            items.append(EvalItem(id: id, audio: "\(parts[0])/\(parts[1])/\(id).flac", reference: l.text, tags: ["punctuation-casing"]))
        }
        return EvalManifest(set: set, audioRoot: relative(audioRoot, to: cache), licence: "CC-BY-4.0",
                            source: DatasetCatalog.librispeechPC, items: items)
    }

    /// FLEURS TSV: id, file_name, raw_transcription, transcription, … — reference = raw transcription.
    public static func fleurs(set: String, language: String, tsv: URL, audioRoot: String) throws -> EvalManifest {
        var items: [EvalItem] = []
        for line in try String(contentsOf: tsv, encoding: .utf8).split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            items.append(EvalItem(id: (cols[1] as NSString).deletingPathExtension, audio: cols[1], reference: cols[2], tags: [language]))
        }
        return EvalManifest(set: set, language: String(language.prefix(2)), audioRoot: audioRoot, licence: "CC-BY-4.0",
                            source: DatasetCatalog.fleurs + language, items: items)
    }

    static func relative(_ url: URL, to base: URL) -> String {
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path, b = base.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : p
    }
}
