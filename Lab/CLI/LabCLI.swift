import Foundation
import Shared

/// Everything the CLI needs to turn names into objects. P1.12/P1.13 register the real engine
/// and pipeline stages here; tests and the default build get deterministic mocks.
public struct LabRegistry: Sendable {
    public var transcribers: [String: @Sendable ([FixtureSuite]) throws -> any FixtureTranscriber]
    public var stages: [String: @Sendable () throws -> any PipelineStage]

    public init(transcribers: [String: @Sendable ([FixtureSuite]) throws -> any FixtureTranscriber] = [:],
                stages: [String: @Sendable () throws -> any PipelineStage] = [:]) {
        self.transcribers = transcribers
        self.stages = stages
    }

    /// `perfect` echoes the manifests; `degraded` deterministically corrupts every 5th word.
    public static let mocks = LabRegistry(transcribers: [
        "perfect": { suites in ScriptedTranscriber.perfect(suites: suites) },
        "degraded": { suites in
            var t = ScriptedTranscriber.perfect(suites: suites, name: "degraded")
            t.transform = { file, ref in
                let words = ref.split(separator: " ").map(String.init)
                let offset = Int(StableHash.fnv1a(file) % 5)
                return words.enumerated().map { i, w in (i + offset) % 5 == 4 ? "um" : w }.joined(separator: " ")
            }
            return t
        },
    ])

    public func transcriber(_ name: String, suites: [FixtureSuite]) throws -> any FixtureTranscriber {
        guard let make = transcribers[name] else { throw LabError.transcriberUnavailable("unknown transcriber '\(name)'; known: \(transcribers.keys.sorted())") }
        return try make(suites)
    }

    public func stages(_ names: [String]) throws -> [any PipelineStage] {
        try names.map { name in
            guard let make = stages[name] else { throw LabError.badArguments("unknown stage '\(name)'; known: \(stages.keys.sorted())") }
            return try make()
        }
    }
}

/// `LabCLI.main(args)` — P1.13 wraps this in an executable. Returns (exit code, output).
///
///     lab run  [--name N] [--transcriber perfect] [--suites clean,entity] [--stages a,b]
///              [--flags contextBiasing=on,voiceRepair=off] [--format md|json] [--out FILE] [--db FILE]
///     lab compare --flag contextBiasing [same options]   # runs flag on vs off, prints comparison
///     lab suites                                          # list available suites
public enum LabCLI {
    public struct Output: Equatable, Sendable {
        public var exitCode: Int32
        public var text: String
        public var reports: [LabReport]
    }

    public static func main(_ args: [String], registry: LabRegistry = .mocks,
                            fixturesDirectory: URL? = AppPaths.fixturesDirectory(),
                            runner: LabRunner? = nil) async -> Output {
        do {
            return try await execute(args, registry: registry, fixturesDirectory: fixturesDirectory, runner: runner)
        } catch {
            return Output(exitCode: 2, text: "error: \(error)\n\n\(usage)", reports: [])
        }
    }

    public static let usage = """
    usage: lab run [--name N] [--transcriber T] [--suites a,b] [--stages s1,s2] [--flags f=on,g=off] [--format md|json] [--out FILE] [--db FILE]
           lab compare --flag contextBiasing [run options]
           lab suites
    """

    static func execute(_ args: [String], registry: LabRegistry, fixturesDirectory: URL?, runner: LabRunner?) async throws -> Output {
        guard let command = args.first else { return Output(exitCode: 1, text: usage, reports: []) }
        let opts = try parse(Array(args.dropFirst()))
        let lab = runner ?? LabRunner(fixturesDirectory: fixturesDirectory)

        switch command {
        case "suites":
            return Output(exitCode: 0, text: FixtureSuite.available(fixturesDirectory: fixturesDirectory).joined(separator: "\n"), reports: [])
        case "run":
            let config = try makeConfig(opts, name: opts["name"] ?? "run")
            let report = try await run(config, registry: registry, lab: lab)
            try persist(report, opts: opts)
            let text = opts["format"] == "json" ? try ReportWriter.json(report) : ReportWriter.markdown(report)
            try write(text, opts: opts)
            return Output(exitCode: 0, text: text, reports: [report])
        case "compare":
            guard let flag = opts["flag"] else { throw LabError.badArguments("compare needs --flag <id>") }
            var on = try makeConfig(opts, name: "\(flag)=on"); on.flags[flag] = true
            var off = try makeConfig(opts, name: "\(flag)=off"); off.flags[flag] = false
            let a = try await run(on, registry: registry, lab: lab)
            let b = try await run(off, registry: registry, lab: lab)
            try persist(a, opts: opts); try persist(b, opts: opts)
            let text = opts["format"] == "json" ? try ReportWriter.json([a, b]) : ReportWriter.comparison([a, b])
            try write(text, opts: opts)
            return Output(exitCode: 0, text: text, reports: [a, b])
        default:
            throw LabError.badArguments("unknown command '\(command)'")
        }
    }

    static func run(_ config: LabConfig, registry: LabRegistry, lab: LabRunner) async throws -> LabReport {
        let suites = try lab.loadSuites(config)
        let transcriber = try registry.transcriber(config.transcriber, suites: suites)
        let stages = try registry.stages(config.stages)
        return try await lab.run(config: config, transcriber: transcriber, stages: stages)
    }

    static func makeConfig(_ opts: [String: String], name: String) throws -> LabConfig {
        var flags: [String: Bool] = [:]
        for pair in list(opts["flags"]) {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { throw LabError.badArguments("bad flag '\(pair)', expected id=on|off") }
            flags[kv[0]] = ["on", "true", "1"].contains(kv[1].lowercased())
        }
        let suites = list(opts["suites"])
        return LabConfig(name: name, transcriber: opts["transcriber"] ?? "perfect", stages: list(opts["stages"]), flags: flags,
                         suites: suites.isEmpty ? FixtureSuite.defaultNames : suites,
                         register: opts["register"].flatMap(Utterance.Register.init(rawValue:)) ?? .unknown)
    }

    static func persist(_ report: LabReport, opts: [String: String]) throws {
        guard let path = opts["db"] else { return }
        try report.persist(to: try AppDatabase.open(at: URL(fileURLWithPath: path)))
    }

    static func write(_ text: String, opts: [String: String]) throws {
        guard let path = opts["out"] else { return }
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parse(_ args: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { throw LabError.badArguments("unexpected argument '\(a)'") }
            let key = String(a.dropFirst(2))
            if let eq = key.firstIndex(of: "=") {
                out[String(key[..<eq])] = String(key[key.index(after: eq)...])
            } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out[key] = args[i + 1]; i += 1
            } else {
                out[key] = "true"
            }
            i += 1
        }
        return out
    }
}
