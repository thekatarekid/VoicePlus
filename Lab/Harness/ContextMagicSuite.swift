import Foundation
import Shared

// Context Writer plan §10.1 / investigation 2026-10-06 §5 — the `context-magic` Lab suite.
//
// The owner's real dictation failures (plus must-not-change controls) as `ContextPacket`s with
// expectations, scored exactly like `tools/correction-bakeoff/bakeoff.py`. The manifest is generated
// from the bake-off's `cases.jsonl` by `export_manifest.py`; the audio is private (the Recordings
// folder) and resolved at run time. The App registers the writer (it owns engine + pipeline) through
// `ContextMagicRunning`; this file only loads, resolves, scores and reports.

// MARK: Manifest

/// One row of `Fixtures/context-magic/manifest.json`.
public struct ContextMagicCase: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case fix, control }

    public struct Expectation: Codable, Equatable, Sendable {
        public var mustContain: [String]
        public var mustNotContain: [String]
        /// A control: the output must equal the heard text after normalisation.
        public var unchanged: Bool

        enum CodingKeys: String, CodingKey { case mustContain = "must_contain", mustNotContain = "must_not_contain", unchanged }

        public init(mustContain: [String] = [], mustNotContain: [String] = [], unchanged: Bool = false) {
            self.mustContain = mustContain; self.mustNotContain = mustNotContain; self.unchanged = unchanged
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mustContain = try c.decodeIfPresent([String].self, forKey: .mustContain) ?? []
            mustNotContain = try c.decodeIfPresent([String].self, forKey: .mustNotContain) ?? []
            unchanged = try c.decodeIfPresent(Bool.self, forKey: .unchanged) ?? false
        }
    }

    public var id: String
    public var kind: Kind
    public var source: String?
    /// A stamp in the owner's Recordings folder (`2026-10-06-233509-411`); private, never committed.
    public var recording: String?
    /// A committed synthetic clip, path under `Fixtures/audio`.
    public var wav: String?
    /// The raw recogniser text, for runs without the audio.
    public var heard: String?
    public var packet: ContextPacket
    public var expect: Expectation

    public init(id: String, kind: Kind, source: String? = nil, recording: String? = nil, wav: String? = nil,
                heard: String? = nil, packet: ContextPacket, expect: Expectation) {
        self.id = id; self.kind = kind; self.source = source; self.recording = recording; self.wav = wav
        self.heard = heard; self.packet = packet; self.expect = expect
    }

    /// What the recogniser wrote: the `heard` field, else the packet's raw 1-best.
    public var heardText: String { heard ?? packet.heard.raw }
    public var namesAudio: Bool { recording != nil || wav != nil }
}

public struct ContextMagicManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var suite: String
    public var generatedFrom: String?
    public var cases: [ContextMagicCase]

    public init(version: Int = 1, suite: String = ContextMagicSuite.name, generatedFrom: String? = nil, cases: [ContextMagicCase]) {
        self.version = version; self.suite = suite; self.generatedFrom = generatedFrom; self.cases = cases
    }
}

// MARK: Runner contract (the App implements this)

/// What one run of a case gets: the case, and the audio when the suite found it. `audioURL == nil`
/// means text-only: run the writer on `item.packet` as it stands (`heard` already filled in).
/// With audio, the App recognises the clip first, replaces `packet.heard` with what the recogniser
/// wrote, then runs the writer on that packet.
public struct ContextMagicInput: Sendable, Equatable {
    public var item: ContextMagicCase
    public var audioURL: URL?
    public init(item: ContextMagicCase, audioURL: URL? = nil) { self.item = item; self.audioURL = audioURL }
}

/// Registered by the App in `LabRegistry.contextMagicWriters` (`LabWiring`). `ms` is the writer's
/// own added latency — packet render + model call + guard — not the recognition time, because the
/// gate is "added p50 ≤ 400 ms cloud / 600 ms local" over the existing path.
public protocol ContextMagicRunning: Sendable {
    func run(_ input: ContextMagicInput) async throws -> (text: String, ms: Double)
}

/// The baseline writer: lands the heard text untouched. Controls 100 %, fixes 0 %, 0 ms.
public struct EchoContextMagicRunner: ContextMagicRunning {
    public init() {}
    public func run(_ input: ContextMagicInput) async throws -> (text: String, ms: Double) {
        (input.item.heardText, 0)
    }
}

// MARK: Scorer — the bake-off's, ported verbatim

public enum ContextMagicScorer {
    public struct Verdict: Equatable, Sendable {
        public var ok: Bool
        public var why: String
    }

    /// `bakeoff.norm`: drop `[[ ]]`, lowercase, collapse whitespace, then strip everything that is
    /// not a word character or whitespace, then trim. The order matters: a removed dash leaves a
    /// double space behind, exactly as the Python does.
    public static func normalize(_ s: String) -> String {
        let unmarked = s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").lowercased()
        var collapsed = ""
        var inSpace = false
        for ch in unmarked {
            if ch.isWhitespace {
                if !inSpace { collapsed.append(" ") }
                inSpace = true
            } else {
                collapsed.append(ch); inSpace = false
            }
        }
        let kept = collapsed.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0.isWhitespace }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `bakeoff.score`: controls must come back unchanged; otherwise every `must_contain` present and
    /// no `must_not_contain`, case-insensitive substring tests on the raw output.
    public static func score(_ expect: ContextMagicCase.Expectation, heard: String, output: String) -> Verdict {
        if expect.unchanged {
            let ok = normalize(output) == normalize(heard)
            return Verdict(ok: ok, why: ok ? "" : "changed a clean dictation")
        }
        let low = output.lowercased()
        for t in expect.mustContain where !low.contains(t.lowercased()) { return Verdict(ok: false, why: "missing '\(t)'") }
        for t in expect.mustNotContain where low.contains(t.lowercased()) { return Verdict(ok: false, why: "still has '\(t)'") }
        return Verdict(ok: true, why: "")
    }
}

// MARK: Suite — load and resolve

public struct ContextMagicSuite: Sendable {
    public static let name = "context-magic"

    public var manifest: ContextMagicManifest
    public var fixturesDirectory: URL?
    public var recordingsDirectory: URL

    public init(manifest: ContextMagicManifest, fixturesDirectory: URL?, recordingsDirectory: URL = ContextMagicSuite.defaultRecordingsDirectory) {
        self.manifest = manifest; self.fixturesDirectory = fixturesDirectory; self.recordingsDirectory = recordingsDirectory
    }

    /// Where `UtteranceRecorder` writes `<stamp>-raw.wav` / `<stamp>-processed.wav`.
    public static var defaultRecordingsDirectory: URL {
        AppPaths.supportDirectory().appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func manifestURL(fixturesDirectory: URL?) -> URL? {
        fixturesDirectory?.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
    }

    public static func isAvailable(fixturesDirectory: URL?) -> Bool {
        manifestURL(fixturesDirectory: fixturesDirectory).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public static func load(fixturesDirectory: URL? = AppPaths.fixturesDirectory(),
                            recordingsDirectory: URL = defaultRecordingsDirectory) throws -> ContextMagicSuite {
        guard let url = manifestURL(fixturesDirectory: fixturesDirectory) else { throw LabError.fixturesUnavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LabError.suiteNotFound(name) }
        let manifest = try JSONDecoder().decode(ContextMagicManifest.self, from: Data(contentsOf: url))
        let ids = manifest.cases.map(\.id)
        guard Set(ids).count == ids.count else { throw LabError.badArguments("\(name): duplicate case ids") }
        return ContextMagicSuite(manifest: manifest, fixturesDirectory: fixturesDirectory, recordingsDirectory: recordingsDirectory)
    }

    /// The clip for a case when it exists: `wav` under `Fixtures/audio`, else the recording's
    /// `-processed.wav` (what the recogniser was handed), else its `-raw.wav`.
    public func audioURL(for item: ContextMagicCase) -> URL? {
        let fm = FileManager.default
        if let wav = item.wav, let root = FixtureSuite.audioRoot(fixturesDirectory: fixturesDirectory) {
            let url = root.appendingPathComponent(wav)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        if let stamp = item.recording {
            for suffix in ["-processed.wav", "-raw.wav"] {
                let url = recordingsDirectory.appendingPathComponent(stamp + suffix)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public enum Resolution: Equatable, Sendable {
        case audio(URL)
        case text
        case skipped(String)
    }

    /// A case that names audio needs it (skipped when missing — never silently run from text
    /// instead); `textOnly` runs every case from its heard text, which is what the bake-off does.
    public func resolve(_ item: ContextMagicCase, textOnly: Bool) -> Resolution {
        if textOnly || !item.namesAudio { return .text }
        if let url = audioURL(for: item) { return .audio(url) }
        let what = item.wav.map { "Fixtures/audio/\($0)" } ?? "recording \(item.recording ?? "?") in \(recordingsDirectory.path)"
        return .skipped("missing \(what)")
    }

    public func run(writer: any ContextMagicRunning, writerName: String, tier: ContextMagicReport.Tier = .cloud,
                    budgetMs: Double? = nil, textOnly: Bool = false,
                    progress: (@Sendable (Int, Int, ContextMagicResult) -> Void)? = nil) async -> ContextMagicReport {
        let startedAt = Date()
        var results: [ContextMagicResult] = []
        for item in manifest.cases {
            var r = ContextMagicResult(id: item.id, kind: item.kind, status: .skipped, why: "", text: "", ms: 0, input: "text")
            switch resolve(item, textOnly: textOnly) {
            case .skipped(let why):
                r.why = why
            case .audio(let url):
                r.input = "audio"
                await Self.execute(writer, ContextMagicInput(item: item, audioURL: url), into: &r)
            case .text:
                await Self.execute(writer, ContextMagicInput(item: item, audioURL: nil), into: &r)
            }
            results.append(r)
            progress?(results.count, manifest.cases.count, r)
        }
        return ContextMagicReport(writer: writerName, tier: tier, budgetMs: budgetMs ?? tier.budgetMs, textOnly: textOnly,
                                  startedAt: startedAt, finishedAt: Date(), results: results)
    }

    private static func execute(_ writer: any ContextMagicRunning, _ input: ContextMagicInput, into r: inout ContextMagicResult) async {
        do {
            let out = try await writer.run(input)
            let v = ContextMagicScorer.score(input.item.expect, heard: input.item.heardText, output: out.text)
            r.status = v.ok ? .pass : .fail; r.why = v.why; r.text = out.text; r.ms = out.ms
        } catch {
            r.status = .error; r.why = "\(error)"
        }
    }
}

// MARK: Report

public struct ContextMagicResult: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pass, fail, skipped, error }
    public var id: String
    public var kind: ContextMagicCase.Kind
    public var status: Status
    public var why: String
    public var text: String
    /// The writer's added latency (see `ContextMagicRunning`).
    public var ms: Double
    /// `audio` or `text`.
    public var input: String

    public init(id: String, kind: ContextMagicCase.Kind, status: Status, why: String = "", text: String = "", ms: Double = 0, input: String = "text") {
        self.id = id; self.kind = kind; self.status = status; self.why = why; self.text = text; self.ms = ms; self.input = input
    }

    public var attempted: Bool { status != .skipped }
}

public struct ContextMagicReport: Codable, Equatable, Sendable {
    public enum Tier: String, Codable, Sendable {
        case cloud, local
        /// Plan §4: added p50 ≤ 400 ms (cloud) / ≤ 600 ms (local, prefix-cached).
        public var budgetMs: Double { self == .cloud ? 400 : 600 }
    }
    /// Investigation §5: ≥ 80 % of the targets fixed, 0 changes to the controls.
    public static let fixesFloor = 0.8

    public var writer: String
    public var tier: Tier
    public var budgetMs: Double
    public var textOnly: Bool
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [ContextMagicResult]

    public init(writer: String, tier: Tier, budgetMs: Double, textOnly: Bool, startedAt: Date, finishedAt: Date, results: [ContextMagicResult]) {
        self.writer = writer; self.tier = tier; self.budgetMs = budgetMs; self.textOnly = textOnly
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.results = results
    }

    // Counts. Skipped cases are reported, never folded into a denominator; an error counts as attempted and failed.
    public var fixesPassed: Int { results.filter { $0.kind == .fix && $0.status == .pass }.count }
    public var fixesAttempted: Int { results.filter { $0.kind == .fix && $0.attempted }.count }
    public var controlsKept: Int { results.filter { $0.kind == .control && $0.status == .pass }.count }
    public var controlsAttempted: Int { results.filter { $0.kind == .control && $0.attempted }.count }
    public var skipped: Int { results.filter { $0.status == .skipped }.count }
    public var errors: Int { results.filter { $0.status == .error }.count }
    public var fixRate: Double { fixesAttempted == 0 ? 0 : Double(fixesPassed) / Double(fixesAttempted) }

    /// Over scored results only (pass/fail); a skipped or errored case has no writer latency.
    public var latencies: [Double] { results.filter { $0.status == .pass || $0.status == .fail }.map(\.ms) }
    public var p50Ms: Double { Percentile.value(latencies, p: 50) }
    public var p90Ms: Double { Percentile.value(latencies, p: 90) }

    public struct Gates: Equatable, Sendable {
        public var fixes: Bool
        public var controls: Bool
        public var latency: Bool
        public var passed: Bool { fixes && controls && latency }
    }

    /// Each gate needs something to judge: an empty category fails its gate rather than passing vacuously.
    public var gates: Gates {
        Gates(fixes: fixesAttempted > 0 && fixRate >= Self.fixesFloor,
              controls: controlsAttempted > 0 && controlsKept == controlsAttempted,
              latency: !latencies.isEmpty && p50Ms <= budgetMs)
    }
    public var passed: Bool { gates.passed }

    static func pct(_ v: Double) -> String { String(format: "%.0f %%", v * 100) }
    static func ms(_ v: Double) -> String { String(format: "%.0f ms", v) }

    public var summaryLine: String {
        "fixes \(fixesPassed)/\(fixesAttempted) (\(Self.pct(fixRate))) · controls kept \(controlsKept)/\(controlsAttempted) · skipped \(skipped) · errors \(errors) · added p50 \(Self.ms(p50Ms)) · p90 \(Self.ms(p90Ms))"
    }

    public func markdown() -> String {
        var out = "# Lab report — context-magic\n\n"
        out += "- Writer: `\(writer)`\n- Tier: \(tier.rawValue) (added p50 budget \(Self.ms(budgetMs)))\n"
        out += "- Input: \(textOnly ? "heard text only (bake-off equivalent)" : "audio where found, else heard text")\n"
        out += "- Cases: \(results.count)\n\n"
        out += summaryLine + "\n\n"
        let g = gates
        out += "| Gate | Target | Actual | Result |\n|---|---|---|---|\n"
        out += "| fixes | ≥ \(Self.pct(Self.fixesFloor)) | \(Self.pct(fixRate)) (\(fixesPassed)/\(fixesAttempted)) | \(g.fixes ? "PASS" : "FAIL") |\n"
        out += "| controls | 100 % | \(controlsKept)/\(controlsAttempted) | \(g.controls ? "PASS" : "FAIL") |\n"
        out += "| added p50 | ≤ \(Self.ms(budgetMs)) (\(tier.rawValue)) | \(Self.ms(p50Ms)) | \(g.latency ? "PASS" : "FAIL") |\n\n"
        out += "**\(passed ? "PASS" : "FAIL")**\(skipped > 0 ? " (\(skipped) skipped: audio not on this Mac)" : "")\n\n"
        out += "## Cases\n\n| Case | Kind | Input | Status | ms | Output | Why |\n|---|---|---|---|---|---|---|\n"
        for r in results {
            out += "| \(r.id) | \(r.kind.rawValue) | \(r.input) | \(r.status.rawValue.uppercased()) | \(r.status == .skipped ? "—" : Self.ms(r.ms)) | \(Self.cell(r.text)) | \(Self.cell(r.why)) |\n"
        }
        return out
    }

    static func cell(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
        return one.count > 90 ? String(one.prefix(90)) + "…" : one
    }

    public func json() throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return String(decoding: try e.encode(self), as: UTF8.self)
    }
}

// MARK: CLI glue — `lab run --suites context-magic`

extension LabCLI {
    /// `lab run --suites context-magic [--writer echo] [--tier cloud|local] [--budget-ms N] [--text-only]
    ///  [--gate] [--format md|json] [--out FILE]`. The suite runs alone (it is packets, not WAV suites).
    static func runContextMagic(_ opts: [String: String], registry: LabRegistry, fixturesDirectory: URL?) async throws -> Output {
        guard list(opts["suites"]) == [ContextMagicSuite.name] else {
            throw LabError.badArguments("\(ContextMagicSuite.name) runs on its own: --suites \(ContextMagicSuite.name)")
        }
        let writerName = opts["writer"] ?? "echo"
        guard let make = registry.contextMagicWriters[writerName] else {
            throw LabError.badArguments("unknown writer '\(writerName)'; known: \(registry.contextMagicWriters.keys.sorted())")
        }
        let tierName = opts["tier"] ?? ContextMagicReport.Tier.cloud.rawValue
        guard let tier = ContextMagicReport.Tier(rawValue: tierName) else { throw LabError.badArguments("--tier cloud|local, not '\(tierName)'") }
        let budget = try opts["budget-ms"].map { s -> Double in
            guard let v = Double(s), v > 0 else { throw LabError.badArguments("--budget-ms needs a positive number") }
            return v
        }
        let suite = try ContextMagicSuite.load(fixturesDirectory: fixturesDirectory)
        let report = await suite.run(writer: try make(), writerName: writerName, tier: tier, budgetMs: budget,
                                     textOnly: opts["text-only"] == "true")
        let text = opts["format"] == "json" ? try report.json() : report.markdown()
        try write(text, opts: opts)
        let gateFailed = opts["gate"] == "true" && !report.passed
        return Output(exitCode: gateFailed ? 1 : 0, text: text, reports: [], contextMagic: report)
    }
}
