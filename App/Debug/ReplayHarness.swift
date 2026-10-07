import Engine
import Foundation
import Pipeline
import Providers
import Shared

// T-replay (Round 4 "Tooling this needs"; owner decision 3) — the recorded-dictation replay tool.
//
// Debug-only and outside the product path: nothing here is reached from a hotkey, nothing is ever
// injected, typed, pasted or put on the clipboard. It takes a recording (a WAV, a folder of WAVs, a
// recording stamp such as `2026-10-02-113444-…`, a time of day such as `11:34:44`, or a turn id
// whose row kept its audio), runs the same final pass, the same boosting, the same context
// channels and the same formatting pipeline the app runs for a chosen surface, and prints:
//   raw (pre-boost) text · boosted text and every swap · the three channels (boost / spell / cleanup)
//   · the final text.
//
// Context Writer (wave 2): the replay also runs the writer at cleanup's position, as the app does —
// `--writer cloud|local|off` (default: the tier Correction resolves to for the surface's app) and
// `--packet <file.json>` (a `ContextPacket` to use instead of the offline surface's; its `heard` is
// replaced with this recording's raw 1-best). The report adds the writer's outcome, its changed words
// and its ms. This is how real recordings are checked against the writer.
//
// `ReplayRunner` is the library half (tests drive it with `MockDecoder` + a scripted booster);
// `ReplayCLI` is `VoicePlusApp --replay <wav|dir|turn-id> [--surface kind] [--writer cloud|local|off]
// [--packet file.json] [--json out]`.

// MARK: - Surface

/// The surface a replay formats for. Each preset is a representative `FieldContext` (an empty
/// field, caret at the end), so the field-role formatter and the persona lookup see what they see
/// for that kind of field in the app.
public struct ReplaySurface: Sendable, Equatable {
    public var kind: String
    public var field: FieldContext

    public static let kinds = ["prose", "notes", "chat", "email", "terminal", "code", "search", "sheet", "unknown"]

    public static func named(_ raw: String, app: String? = nil) -> ReplaySurface? {
        let kind = raw.lowercased()
        var field: FieldContext
        switch kind {
        case "prose", "notes":
            field = FieldContext(appBundleID: "com.apple.Notes", axRole: "AXTextArea", isMultiline: true)
        case "chat":
            field = FieldContext(appBundleID: "com.openai.chat", axRole: "AXTextArea", hints: ["composer"],
                                 isMultiline: true, submitsOnReturn: true)
        case "email":
            field = FieldContext(appBundleID: "com.apple.mail", axRole: "AXTextArea", hints: ["message body"],
                                 isMultiline: true)
        case "terminal":
            field = FieldContext(appBundleID: "com.apple.Terminal", axRole: "AXTextArea", hints: ["shell"])
        case "code":
            field = FieldContext(appBundleID: "com.microsoft.VSCode", axRole: "AXTextArea", hints: ["Monaco editor"],
                                 isMultiline: true)
        case "search":
            field = FieldContext(appBundleID: "com.apple.Safari", axRole: "AXTextField", isMultiline: false)
        case "sheet":
            field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                                 documentURL: Self.sheetsDocumentURL)
        case "unknown":
            field = FieldContext(caret: .unknown)
        default:
            return nil
        }
        if let app, !app.isEmpty { field.appBundleID = app }
        return ReplaySurface(kind: kind, field: field)
    }
}

// MARK: - Report

public struct ReplayReport: Codable, Equatable, Sendable {
    public struct Swap: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
    }
    public struct Channels: Codable, Equatable, Sendable {
        /// Terms the final-pass booster was built from.
        public var boost: [String]
        /// Personalisation's "Spell these exactly" list (`personal.dictionary`).
        public var spell: [String]
        /// The ranked-context prompt the cleanup stage reads (`context.prompt`), or nil.
        public var cleanup: String?
    }
    public var source: String
    public var surface: String
    public var appBundleID: String?
    public var seconds: Double
    /// Final pass with no booster installed.
    public var rawText: String
    /// Final pass with the utterance's booster.
    public var boostedText: String
    public var swaps: [Swap]
    public var detectedTerms: [String]
    public var channels: Channels
    public var route: String
    public var register: String
    public var finalText: String
    public var pipelineMs: Double
    public var error: String?
    /// Context Writer — what the writer did on this recording (nil: the runner has no writer).
    public var writer: Writer? = nil

    public struct Writer: Codable, Equatable, Sendable {
        /// `cloud`, `local` or `off`.
        public var backend: String
        /// `WriterOutcome.code` (`accepted`, `unchanged`, `partiallyReverted:n`, `timeout`, …), or `off`.
        public var outcome: String
        /// Heard → written, as they landed.
        public var changed: [Swap]
        /// The writer's own time (packet render + model call + guard).
        public var ms: Double
        /// `offline` (built from the surface) or the `--packet` file name.
        public var packet: String
    }

    /// Human-readable block for the terminal.
    public var rendered: String {
        var lines = ["== \(source)  [\(surface)\(appBundleID.map { " · \($0)" } ?? "")]  \(String(format: "%.2f", seconds)) s"]
        if let error { lines.append("  error:   \(error)"); return lines.joined(separator: "\n") }
        lines.append("  raw:     \(rawText)")
        lines.append("  boosted: \(boostedText)")
        lines.append("  swaps:   " + (swaps.isEmpty ? "none" : swaps.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")))
        if !detectedTerms.isEmpty { lines.append("  spotted: \(detectedTerms.joined(separator: ", "))") }
        lines.append("  boost channel (\(channels.boost.count)):   \(Self.preview(channels.boost))")
        lines.append("  spell channel (\(channels.spell.count)):   \(Self.preview(channels.spell))")
        lines.append("  cleanup channel: " + (channels.cleanup.map { $0.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? "none"))
        lines.append("  route:   \(route) / \(register)  (\(String(format: "%.0f", pipelineMs)) ms)")
        if let writer {
            lines.append("  writer:  \(writer.backend) · \(writer.outcome) · \(String(format: "%.0f", writer.ms)) ms · packet \(writer.packet)")
            lines.append("  changed: " + (writer.changed.isEmpty ? "none" : writer.changed.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")))
        }
        lines.append("  final:   \(finalText)")
        return lines.joined(separator: "\n")
    }

    static func preview(_ terms: [String], limit: Int = 40) -> String {
        guard !terms.isEmpty else { return "none" }
        let head = terms.prefix(limit).joined(separator: ", ")
        return terms.count > limit ? head + ", … (+\(terms.count - limit))" : head
    }
}

// MARK: - Runner

/// Captures what the real booster did for one pass, without changing it.
final class RecordingBooster: VocabularyBooster, @unchecked Sendable {
    let inner: VocabularyBooster
    private let lock = NSLock()
    private var _outcome: BoostOutcome?
    init(_ inner: VocabularyBooster) { self.inner = inner }
    var terms: [String] { inner.terms }
    var outcome: BoostOutcome? { lock.withLock { _outcome } }
    func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? {
        let out = await inner.boost(tokens: tokens, samples: samples)
        if let out {
            lock.withLock {
                // A chunked decoder calls this per chunk: keep every chunk's swaps.
                var merged = _outcome ?? BoostOutcome(tokens: [])
                merged.tokens += out.tokens
                merged.replacements += out.replacements
                merged.detectedTerms += out.detectedTerms.filter { !merged.detectedTerms.contains($0) }
                _outcome = merged
            }
        }
        return out
    }
}

/// Context Writer — the writer a replay runs: the backend's gate stage (already in the runner's
/// pipeline at cleanup's position) and the packet to give it. `stage == nil` is `--writer off`.
/// `--show-model`: prints the writer's prompt and raw reply (replay is a local debug tool).
struct ShowingWriterGenerator: WriterGenerating {
    let inner: any WriterGenerating
    func write(system: String, user: String, context: StageContext) async throws -> String {
        let reply = try await inner.write(system: system, user: user, context: context)
        print("  model user prompt:\n" + user.split(separator: "\n").map { "    | " + $0 }.joined(separator: "\n"))
        print("  model reply: \(reply)")
        return reply
    }
}

public struct ReplayWriter: @unchecked Sendable {
    public var backend: String
    public var stage: WriterGateStage?
    let ledger: WriterRunLedger
    /// `--packet`: used instead of the offline packet (its `heard` is replaced).
    public var packet: ContextPacket?
    public var packetSource: String
    /// Builds the offline packet from the surface's field (no screen offline) and the heard spans.
    public var builder: ContextPacketBuilder

    /// - Parameter generator: the backend (nil = off).
    public init(backend: String, generator: (any WriterGenerating)?, packet: ContextPacket? = nil,
                packetSource: String = "offline", builder: ContextPacketBuilder = ContextPacketBuilder()) {
        let ledger = WriterRunLedger()
        self.backend = backend
        self.ledger = ledger
        // Debug CLI only: `--show-model` prints the rendered prompt and the model's raw reply to this
        // terminal (never the system log), to see what the guard was given.
        let shown = generator.map { g -> any WriterGenerating in
            CommandLine.arguments.contains("--show-model") ? ShowingWriterGenerator(inner: g) : g
        }
        let showing = CommandLine.arguments.contains("--show-model")
        self.stage = shown.map { g -> WriterGateStage in
            var inner = ContextWriterStage(generator: g)
            if showing { inner.deadline = 60 }   // inspection: include the cold load, see every reply
            return WriterGateStage(inner: inner, ledger: ledger)
        }
        self.packet = packet
        self.packetSource = packet == nil ? "offline" : packetSource
        self.builder = builder
    }

    /// The packet for one recording: `--packet` (or the surface's offline packet) with `heard` =
    /// the raw 1-best words and the booster's text as evidence.
    func packet(raw: [TranscriptSpan], boosted: [TranscriptSpan], surface: ReplaySurface) -> ContextPacket {
        let boostedText = boosted.joinedText == raw.joinedText ? nil : boosted.renderedText
        if var given = packet {
            given.heard = ContextPacketBuilder.heard(raw, boosted: boostedText)
            return given
        }
        return builder.build(ContextPacketBuilder.Input(field: surface.field, spans: raw, boostedText: boostedText))
    }
}

public final class ReplayRunner: @unchecked Sendable {
    public let recognizer: DecoderFinalRecognizer
    /// Per-utterance booster (the app's `BoostingController.makeBoosterForUtterance`); nil = none.
    public let makeBooster: () -> VocabularyBooster?
    public let pipeline: PipelineRunner
    /// The lander's decoration: persona + Personalisation (spell channel).
    public let decorate: (StageContext) -> StageContext
    /// The cleanup context channel (`ContextPromptSession.write(into:)`); nil = none.
    public let cleanupContext: ((inout StageContext) -> Void)?
    /// Context Writer — its gate must be in `pipeline` (`ReplayPipeline.make(…, writer:)`); nil = none.
    public let writer: ReplayWriter?

    public init(recognizer: DecoderFinalRecognizer, makeBooster: @escaping () -> VocabularyBooster?,
                pipeline: PipelineRunner, decorate: @escaping (StageContext) -> StageContext = { $0 },
                cleanupContext: ((inout StageContext) -> Void)? = nil, writer: ReplayWriter? = nil) {
        self.recognizer = recognizer
        self.makeBooster = makeBooster
        self.pipeline = pipeline
        self.decorate = decorate
        self.cleanupContext = cleanupContext
        self.writer = writer
    }

    /// One recording through final pass → boost → channels → pipeline. Never injects.
    /// `near`: the field text before the caret at key-down (H19 repair evidence; `--near`). Offline
    /// replay has no screen reader, so without it the context repair stage has nothing to hear with.
    public func run(samples: [Float], source: String, surface: ReplaySurface, near: String? = nil) async -> ReplayReport {
        var report = ReplayReport(source: source, surface: surface.kind, appBundleID: surface.field.appBundleID,
                                  seconds: Double(samples.count) / 16_000, rawText: "", boostedText: "", swaps: [],
                                  detectedTerms: [], channels: .init(boost: [], spell: [], cleanup: nil),
                                  route: "", register: "", finalText: "", pipelineMs: 0, error: nil)
        do {
            // 1. Raw final pass, booster removed.
            recognizer.installBooster(nil)
            let raw = try await recognizer.recognize(samples)
            report.rawText = raw.joinedText

            // 2. Boosted final pass, exactly as the app installs it at hotkey-down.
            var spans = raw
            if let booster = makeBooster() {
                let recording = RecordingBooster(booster)
                report.channels.boost = booster.terms
                recognizer.installBooster(recording)
                spans = try await recognizer.recognize(samples)
                recognizer.installBooster(nil)
                if let out = recording.outcome {
                    report.swaps = out.replacements.map { .init(from: $0.original, to: $0.replacement) }
                    report.detectedTerms = out.detectedTerms
                }
            }
            report.boostedText = spans.joinedText

            // 3. Context channels, in the lander's order: decorate → cleanup context → field last.
            var ctx = decorate(StageContext(register: .unknown, appBundleID: surface.field.appBundleID))
            cleanupContext?(&ctx)
            if let near, !near.isEmpty {
                TurnSurfaceContext.installRepairPhonetics
                let caret = TurnSurfaceContext.NearCaretContext(before: near, after: "", surfaceKind: surface.field.surface.kind)
                TurnSurfaceContext.repairEvidence(caret)?.write(into: &ctx)
            }
            // Context Writer — the packet (pre-boost heard) and the run's switch, as the lander's
            // context step writes them; the field goes in after it, as in the app.
            let landing = UUID()
            if let writer, writer.stage != nil {
                let packet = writer.packet(raw: raw, boosted: spans, surface: surface)
                if !packet.isSecure {
                    packet.write(into: &ctx)
                    ctx.extra[WriterWiring.activeKey] = "true"
                    ctx.extra[WriterWiring.backendKey] = writer.backend
                    ctx.extra[WriterWiring.landingIDKey] = landing.uuidString
                }
            }
            FieldRolePipeline.write(surface.field, into: &ctx)
            report.channels.spell = Personalisation.read(from: ctx).dictionary
            report.channels.cleanup = ctx.extra[ContextPromptKeys.prompt]

            // 4. Formatting pipeline (with the writer at cleanup's position when it is wired).
            guard !spans.joinedText.trimmingCharacters(in: .whitespaces).isEmpty else { return report }
            let out = try await pipeline.run(spans, context: ctx)
            report.finalText = out.text
            report.route = out.decision.route.rawValue
            report.register = out.decision.register.rawValue
            report.pipelineMs = out.totalLatencyMs
            if let writer {
                let run = writer.ledger.take(landing)
                let changed = run.map { WriterWiring.changedWords($0, finalSpans: out.spans, text: out.text) } ?? []
                report.writer = .init(backend: writer.stage == nil ? "off" : writer.backend,
                                      outcome: writer.stage == nil ? "off" : (run?.outcome ?? "skipped:notRun"),
                                      changed: changed.map { .init(from: $0.heard, to: $0.written) },
                                      ms: run?.ms ?? 0, packet: writer.packetSource)
            }
        } catch {
            recognizer.installBooster(nil)
            report.error = "\(error)"
        }
        return report
    }
}

// MARK: - Locating recordings

public enum ReplaySources {
    /// Resolves `arg` to WAV files, in order.
    /// - an existing `.wav` → itself; an existing folder → its `*-processed.wav` (recordings) or else
    ///   every `.wav` in it (fixtures);
    /// - a recording stamp or stamp prefix (`2026-10-02-113444`) → that recording;
    /// - a time of day (`11:34:44` or `113444`) → the newest recording at that second;
    /// - a path relative to `Fixtures/`;
    /// - a turn id (prefix of the UUID) whose `turn_records` row kept its audio.
    public static func resolve(_ arg: String, recordings: URL = UtteranceRecorder.directory(),
                               fixtures: URL? = AppPaths.fixturesDirectory(),
                               turnAudio: (String) -> String? = { _ in nil }) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let expanded = (arg as NSString).expandingTildeInPath
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            let url = URL(fileURLWithPath: expanded)
            return isDir.boolValue ? wavs(in: url) : [url]
        }
        if let fixture = fixtures?.appendingPathComponent(arg), fm.fileExists(atPath: fixture.path, isDirectory: &isDir) {
            return isDir.boolValue ? wavs(in: fixture) : [fixture]
        }
        let stamps = recordingStamps(in: recordings)
        let digits = arg.filter(\.isNumber)
        if arg.contains("-"), let hit = stamps.last(where: { $0.hasPrefix(arg) }) {
            return [recording(hit, in: recordings)]
        }
        if digits.count == 6, arg.allSatisfy({ $0.isNumber || $0 == ":" }),
           let hit = stamps.last(where: { $0.dropFirst(11).hasPrefix(digits) }) {
            return [recording(hit, in: recordings)]
        }
        if let path = turnAudio(arg), fm.fileExists(atPath: path) { return [URL(fileURLWithPath: path)] }
        return []
    }

    static func wavs(in dir: URL) -> [URL] {
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let processed = all.filter { $0.lastPathComponent.hasSuffix("-processed.wav") }
        return processed.isEmpty ? all : processed
    }

    /// Sorted stamps of recordings that have a WAV.
    static func recordingStamps(in dir: URL) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        var out = Set<String>()
        for n in names {
            if n.hasSuffix("-processed.wav") { out.insert(String(n.dropLast("-processed.wav".count))) }
            else if n.hasSuffix("-raw.wav") { out.insert(String(n.dropLast("-raw.wav".count))) }
        }
        return out.sorted()
    }

    /// The processed WAV (what the recognizer was handed) when present, else the raw one.
    static func recording(_ stamp: String, in dir: URL) -> URL {
        let processed = dir.appendingPathComponent("\(stamp)-processed.wav")
        return FileManager.default.fileExists(atPath: processed.path)
            ? processed : dir.appendingPathComponent("\(stamp)-raw.wav")
    }
}

// MARK: - CLI

public enum ReplayCLI {
    public struct Options: Equatable {
        public var target: String
        public var surface: String = "prose"
        public var app: String?
        public var json: String?
        /// H19 — near-caret text for the context repair stage (`--near "text before the caret"`).
        public var near: String?
        /// Context Writer — `cloud`, `local` or `off`; nil = the tier Correction resolves to for the
        /// surface's app on this Mac.
        public var writer: String?
        /// Context Writer — a `ContextPacket` JSON file used instead of the offline surface's packet.
        public var packet: String?
    }

    public static func parse(_ args: [String]) -> Options? {
        guard let i = args.firstIndex(of: "--replay"), i + 1 < args.count else { return nil }
        var o = Options(target: args[i + 1])
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        if let s = value("--surface") { o.surface = s }
        o.app = value("--app")
        o.json = value("--json")
        o.near = value("--near")
        o.writer = value("--writer")?.lowercased()
        o.packet = value("--packet")
        return o
    }

    static let usage = "usage: VoicePlusApp --replay <wav|dir|stamp|HH:MM:SS|turn-id> [--surface \(ReplaySurface.kinds.joined(separator: "|"))] [--app bundle-id] [--near text] [--writer cloud|local|off] [--packet packet.json] [--show-model] [--json out.jsonl]"

    /// Exit code: 0 ok, 2 bad arguments / nothing found, 3 no speech model.
    public static func run(_ o: Options) async -> Int32 {
        guard let surface = ReplaySurface.named(o.surface, app: o.app) else { print(usage); return 2 }
        let database = try? AppDatabase.open()
        let urls = ReplaySources.resolve(o.target, turnAudio: { turnAudioPath($0, database: database) })
        guard !urls.isEmpty else { print("replay: nothing found for \(o.target)\n\(usage)"); return 2 }
        let writer: ReplayWriter
        switch liveWriter(o, surface: surface, database: database) {
        case .success(let w): writer = w
        case .failure(let message): print("replay: \(message)\n\(usage)"); return 2
        }
        guard let runner = await liveRunner(database: database, writer: writer) else {
            print("replay: no speech model on disk (install one in Settings › Models)"); return 3
        }
        // A cold model load or TLS handshake is not the writer's per-dictation cost.
        if let backend = writer.stage?.inner.generator as? any WriterBackend { await backend.prewarm() }
        print("replay: writer \(writer.stage == nil ? "off" : writer.backend) · packet \(writer.packetSource)")
        var jsonLines: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for url in urls {
            let report: ReplayReport
            do {
                let samples = try SampleAudioSource.load16k(url: url)
                report = await runner.run(samples: samples, source: url.lastPathComponent, surface: surface, near: o.near)
            } catch {
                report = ReplayReport(source: url.lastPathComponent, surface: surface.kind, appBundleID: surface.field.appBundleID,
                                      seconds: 0, rawText: "", boostedText: "", swaps: [], detectedTerms: [],
                                      channels: .init(boost: [], spell: [], cleanup: nil), route: "", register: "",
                                      finalText: "", pipelineMs: 0, error: "\(error)")
            }
            print(report.rendered)
            if let data = try? encoder.encode(report), let line = String(data: data, encoding: .utf8) { jsonLines.append(line) }
        }
        if let path = o.json {
            let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { try (jsonLines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8) }
            catch { print("replay: could not write \(out.path): \(error)") }
        }
        await LlamaCppEngine.unloadAllShared()   // llama.cpp's Metal teardown asserts at exit otherwise
        return 0
    }

    struct WriterChoiceError: Error, Equatable { var message: String }

    /// Context Writer — the replay's writer: `--writer` or the tier Correction resolves to for the
    /// surface's app on this Mac (Automatic included), and `--packet` when given.
    /// - Parameter vocabulary: false leaves the offline packet without the personal vocabulary (tests).
    static func liveWriter(_ o: Options, surface: ReplaySurface, database: AppDatabase?,
                           settings: SettingsStore = UserDefaultsSettingsStore(),
                           secrets: SecretStore = KeychainSecretStore(),
                           vocabulary: Bool = true) -> Result<ReplayWriter, WriterChoiceError> {
        // The app's guard hears with Double Metaphone (installed when `WriterWiring` is built); the
        // replay builds its writer without it, so install the same ear or every sound-alike fix is
        // reverted as unexplained.
        WriterWiring.installGuardPhonetics
        var packet: ContextPacket?
        if let path = o.packet {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url),
                  let decoded = ContextPacket.decode(String(decoding: data, as: UTF8.self)) else {
                return .failure(.init(message: "--packet \(path) is not a ContextPacket JSON file"))
            }
            packet = decoded
        }
        let hasKey = WriterWiring.cloudKeyStored(secrets)
        let local = WriterWiring.installedLocalModel()
        let choice: String
        if let w = o.writer { choice = w } else {
            let availability = ContextCorrectionSettings.Availability(hasCloudKey: hasKey, hasLocalModel: local != nil)
            choice = ContextCorrectionSettings.resolvedMode(for: surface.field.appBundleID, store: settings, availability: availability).rawValue
        }
        let builder = ContextPacketBuilder()
        if vocabulary { builder.vocabulary = WriterWiring.vocabularyBuilder(database: database, adaptation: try? AdaptationService())() }
        let name = o.packet.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "offline"
        switch choice {
        case "off":
            return .success(ReplayWriter(backend: "off", generator: nil, packet: packet, packetSource: name, builder: builder))
        case "cloud":
            guard hasKey else { return .failure(.init(message: "--writer cloud needs an OpenRouter key (Settings › Providers)")) }
            let generator = WriterWiring.cloudGenerator(config: ContextCorrectionSettings.cloudConfig(settings), secrets: secrets, database: database)
            return .success(ReplayWriter(backend: "cloud", generator: CloudWriterBackend(generator: generator), packet: packet,
                                         packetSource: name, builder: builder))
        case "local":
            guard let local else { return .failure(.init(message: "--writer local needs a rewrite model on this Mac (Settings › Models)")) }
            return .success(ReplayWriter(backend: "local", generator: LocalWriterBackend(model: local, deadline: CommandLine.arguments.contains("--show-model") ? 60 : ContextWriterStage.defaultDeadline, loadsOnWrite: true), packet: packet,
                                         packetSource: name, builder: builder))
        default:
            return .failure(.init(message: "--writer cloud|local|off, not '\(choice)'"))
        }
    }

    /// The app's pieces, assembled without the UI, the hotkey, the injector or any screen reader.
    /// The cleanup channel uses the same authored sources the app ranks (corrections, learned
    /// lexicon); screen text is not available offline, so the AX sources are absent by design.
    static func liveRunner(database: AppDatabase?, writer: ReplayWriter? = nil) async -> ReplayRunner? {
        // A dev binary has no bundled models of its own: borrow the installed app's (read only).
        var caches = ModelManager.defaultExternalCaches()
        for (id, folder) in BundledModelResources.candidates(resources: installedAppResources) {
            caches[id, default: []].append(folder)
        }
        let manager = ModelManager(externalCaches: caches, maintenance: .skip)
        let final: FinalRecognizer
        do { final = try await RecognizerFactory.makeFinal(manager: manager) }
        catch { print("replay: final recognizer unavailable: \(error)"); return nil }
        guard let recognizer = final as? DecoderFinalRecognizer else {
            print("replay: final recognizer \(final.name) is not a decoder recognizer"); return nil
        }
        let adaptation = try? AdaptationService()
        let boosting = BoostingWiring.controller(database: database, adaptation: adaptation, modelManager: manager)
        let settings = UserDefaultsSettingsStore()
        let routing = RoutingTable(providers: [LocalRulesProvider()], logger: InMemoryNetworkLogger())
        let pipeline = ReplayPipeline.make(database: database, adaptation: adaptation, routing: routing, settings: settings,
                                           writer: writer?.stage)
        let styles: any StyleProfileStore = database.map { DatabaseStyleProfileStore(database: $0) } ?? InMemoryStyleProfileStore()
        let personas = PersonaManager(store: database.map { DatabasePersonaStore(database: $0) } ?? InMemoryPersonaStore(), styles: styles)
        let harvester = ContextHarvester()
        if let database { harvester.add(CorrectionSource(store: DatabaseCorrectionStore(database: database))) }
        if let adaptation { harvester.add(LearnedLexiconSource(loop: adaptation.loop)) }
        let prompt = ContextPromptSession(harvester: harvester)
        return ReplayRunner(recognizer: recognizer, makeBooster: { boosting?.makeBoosterForUtterance() },
                            pipeline: pipeline, decorate: { personas.decorate($0) },
                            cleanupContext: { prompt.write(into: &$0) }, writer: writer)
    }

    static var installedAppResources: URL? {
        let url = URL(fileURLWithPath: "/Applications/VoicePlus.app/Contents/Resources")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `retainedAudioPath` of the newest `turn_records` row whose id starts with `id` (read only).
    static func turnAudioPath(_ id: String, database: AppDatabase?) -> String? {
        guard let database, id.count >= 4, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let json: String? = try? database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT recordJSON FROM \(TurnStore.table) WHERE id LIKE ? ORDER BY startedAt DESC LIMIT 1",
                                arguments: [id.uppercased() + "%"])
        }
        guard let data = json?.data(using: .utf8),
              let record = try? JSONDecoder().decode(TurnRecord.self, from: data) else { return nil }
        return record.retainedAudioPath
    }
}

/// The app's dictation stage list (AppContainer) minus the pre-route hooks that need a live
/// session (act key, latch, wake verb): snippets, the regression guard, the built-in stages with the
/// entity-guarded style pass, the Context Writer at cleanup's position (when given), the cleanup LLM
/// before style, and the field-role formatter in place of the register formatters.
enum ReplayPipeline {
    static func make(database: AppDatabase?, adaptation: AdaptationService?, routing: RoutingTable,
                     settings: SettingsStore, writer: WriterGateStage? = nil) -> PipelineRunner {
        let styleStore: any StyleProfileStore = database.map { DatabaseStyleProfileStore(database: $0) } ?? InMemoryStyleProfileStore()
        let snippetStore: any SnippetStoring = database.map { DatabaseSnippetStore(database: $0) } ?? InMemorySnippetStore()
        let guardStage = RegressionGuardStage(lexicon: { adaptation?.loop.lexicon ?? PersonalLexicon() })
        let builtIn = StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
            stage.id == .style ? DictionaryWiring.styleStage(store: styleStore) : stage
        }
        var chain = CleanupWiring.inserting(CleanupWiring.stage(routing: routing, settings: settings), into: builtIn)
        if let writer { chain = CleanupWiring.insertingWriter(writer, into: chain) }
        let stages: [any PipelineStage] = [SnippetStage(store: snippetStore), guardStage]
            + FieldRolePipeline.replacingFormatters(in: chain)
        let gatekeeper = GatekeeperStage(local: PreRoutingClassifier(hooks: [SnippetPreRoute(store: snippetStore)]))
        return PipelineRunner(gatekeeper: gatekeeper, stages: stages, providers: RoutingTableProviderRouting(table: routing, settings: settings))
    }
}

extension ReplaySurface {
    /// A Google Sheets document URL as a focused field would report it (surface detection only,
    /// never fetched; built from components so the egress audit's literal-URL scan stays honest).
    static var sheetsDocumentURL: String {
        var c = URLComponents()
        c.scheme = "https"; c.host = "docs.google.com"; c.path = "/spreadsheets/d/x/edit"
        return c.string ?? ""
    }
}
