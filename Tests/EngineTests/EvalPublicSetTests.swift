import Darwin
import Foundation
import Testing
import Shared
@testable import Engine

/// V5 V1/V3/V4 — runs real on-disk models over a public-set manifest built by `lab fetch` /
/// `lab mix` and writes one hypothesis file per model, which the Lab scores with
/// `lab eval --set <name> --model <id> --hyp <file>` (the Lab target cannot link Engine).
///
/// Opt-in, never part of the normal gate: `VOICEPLUS_EVAL_SET=<set>` (optionally
/// `VOICEPLUS_EVAL_LIMIT=N`, `VOICEPLUS_EVAL_CACHE=dir`,
/// `VOICEPLUS_EVAL_MODELS=parakeet-tdt-v3,parakeet-ultra,parakeet-redux,preview-eou,preview-polling,micquality`).
/// Output: `<cache>/<set>/hyp-<model>.json`.
///
/// - `parakeet-tdt-v3`: the final recognizer, whole utterance (latency = compute).
/// - `preview-eou` / `preview-polling`: the R1.5 preview candidates fed in 100 ms chunks as
///   `RealEngine` feeds live capture; text = last preview, latency = first word after speech onset.
/// - `micquality`: `MicQualityAnalyzer` + `EnergyVAD` in VAD lockstep (as `AudioPipeline`); label =
///   verdict, metrics `snrDB` (the analyzer's estimate).
/// Every item also carries `audioSeconds` (for duration segment classes).
@Suite("Public-set replay (real model)", .serialized)
struct EvalPublicSetTests {
    struct Manifest: Decodable {
        struct Item: Decodable { let id: String; let audio: String? }
        let set: String
        let audioRoot: String
        let items: [Item]
    }
    struct HypItem: Encodable {
        var text: String?
        var label: String?
        var latencyMs: Double?
        var audioSeconds: Double
        var metrics: [String: Double]?
    }
    struct HypFile: Encodable { let model: String; let set: String; let peakRSSBytes: UInt64; let items: [String: HypItem] }

    static func cache() -> URL {
        if let c = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_CACHE"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return AppPaths.supportDirectory().appendingPathComponent("Eval", isDirectory: true)
    }

    static func peakRSS() -> UInt64 {
        var u = rusage()
        return getrusage(RUSAGE_SELF, &u) == 0 ? UInt64(max(0, u.ru_maxrss)) : 0
    }

    /// Analyzer verdict the way `AudioPipeline.process` produces it (one VAD frame at a time).
    static func micQuality(_ audio: [Float]) async throws -> MicQuality? {
        let vad = EnergyVAD()
        let analyzer = MicQualityAnalyzer()
        await vad.reset()
        var verdict: MicQuality?
        var i = 0
        while i < audio.count {
            let end = min(i + vad.frameSize, audio.count)
            if let q = analyzer.feed(Array(audio[i..<end])), verdict == nil { verdict = q }
            var frame = Array(audio[i..<end])
            frame.append(contentsOf: [Float](repeating: 0, count: vad.frameSize - frame.count))
            if let event = try await vad.process(frame: frame).event { analyzer.note(event) }
            i = end
        }
        if verdict == nil { verdict = analyzer.flush() }
        return verdict
    }

    @Test(.timeLimit(.minutes(120)))
    func replayPublicSet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["VOICEPLUS_EVAL_SET"], !set.isEmpty else {
            print("SKIPPED: set VOICEPLUS_EVAL_SET=<set> (after `lab fetch` / `lab mix`) to replay a public set through real models.")
            return
        }
        let models = (env["VOICEPLUS_EVAL_MODELS"] ?? "parakeet-tdt-v3").split(separator: ",").map(String.init)
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk.")
            return
        }
        let setDir = Self.cache().appendingPathComponent(set, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: setDir.appendingPathComponent("manifest.json")))
        let root = manifest.audioRoot.hasPrefix("/") ? URL(fileURLWithPath: manifest.audioRoot) : Self.cache().appendingPathComponent(manifest.audioRoot)
        var items = manifest.items
        if let limit = env["VOICEPLUS_EVAL_LIMIT"].flatMap(Int.init) { items = Array(items.prefix(limit)) }

        let final = try await RecognizerFactory.makeFinal(manager: manager)
        #expect(final.name == "fluidaudio.tdt.v3")
        var eou: PreviewRecognizer?
        if models.contains("preview-eou") {
            eou = await PreviewReplayTests.eouPreview(manager)
            if eou == nil { print("NOTE: parakeet-realtime-eou-120m not on disk — preview-eou skipped, not estimated.") }
        }
        // V5 B5 — the optional final models, replayed exactly like v3 when they are on disk.
        var optionalFinals: [String: FinalRecognizer] = [:]
        for (model, id, label) in [("parakeet-ultra", ModelID.parakeetUltra, "fluidaudio.tdt.ultra"),
                                   ("parakeet-redux", ModelID.parakeetRedux, "fluidaudio.tdt.redux")] where models.contains(model) {
            // `VOICEPLUS_LIVE_MODELS=1` fetches a missing one (Redux ~220 MB, Ultra ~632 MB).
            if env["VOICEPLUS_LIVE_MODELS"] == "1", await !manager.isPresent(id) { _ = try? await manager.ensureAvailable(id) }
            guard await manager.isPresent(id), ModelCatalog.isSupportedOnThisOS(id),
                  let m = try await manager.load(id).asrModels else {
                print("NOTE: \(id.rawValue) not on disk (or not loadable on this OS) — \(model) skipped."); continue
            }
            optionalFinals[model] = DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: m, name: label))
        }
        var out: [String: [String: HypItem]] = [:]
        for (n, item) in items.enumerated() {
            guard let audio = item.audio else { continue }
            let url = audio.hasPrefix("/") ? URL(fileURLWithPath: audio) : root.appendingPathComponent(audio)
            let samples = try SampleAudioSource.load16k(url: url)
            let seconds = Double(samples.count) / 16_000
            for model in models {
                switch model {
                case "parakeet-tdt-v3":
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let spans = try await final.recognize(samples)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                    out[model, default: [:]][item.id] = HypItem(text: spans.joinedText, latencyMs: ms, audioSeconds: seconds)
                case "parakeet-ultra", "parakeet-redux":
                    guard let r = optionalFinals[model] else { continue }
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let spans = try await r.recognize(samples)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                    out[model, default: [:]][item.id] = HypItem(text: spans.joinedText, latencyMs: ms, audioSeconds: seconds)
                case "preview-eou":
                    guard let eou else { continue }
                    let t = try await PreviewReplayTests.replay(samples, through: eou)
                    out[model, default: [:]][item.id] = HypItem(text: t.text, latencyMs: t.firstWordMs, audioSeconds: seconds,
                                                               metrics: ["cpuSeconds": t.cpuSeconds])
                case "preview-polling":
                    let t = try await PreviewReplayTests.replay(samples, through: PollingPreviewRecognizer(recognizer: final))
                    out[model, default: [:]][item.id] = HypItem(text: t.text, latencyMs: t.firstWordMs, audioSeconds: seconds,
                                                               metrics: ["cpuSeconds": t.cpuSeconds])
                case "micquality":
                    let q = try await Self.micQuality(samples)
                    out[model, default: [:]][item.id] = HypItem(label: q?.verdict.rawValue ?? "none", latencyMs: 0, audioSeconds: seconds,
                                                               metrics: q.map { ["snrDB": Double($0.snr), "clipping": Double($0.clipping)] })
                default:
                    Issue.record("unknown model \(model)")
                    return
                }
            }
            if n % 50 == 0 { print("eval \(set): \(n)/\(items.count)") }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        for (model, hyps) in out {
            let file = HypFile(model: model, set: set, peakRSSBytes: Self.peakRSS(), items: hyps)
            let url = setDir.appendingPathComponent("hyp-\(model).json")
            try enc.encode(file).write(to: url)
            print("wrote \(hyps.count) hypotheses → \(url.path)")
        }
        #expect(out["parakeet-tdt-v3"].map { $0.count == items.filter { $0.audio != nil }.count } ?? true)
    }
}
