import Darwin
import Foundation
import Testing
import Shared
@testable import Engine

/// V5 V1 — runs the real final-pass recognizer (Parakeet TDT v3) over a public-set manifest built by
/// `lab fetch --set <name>` and writes a hypothesis file the Lab scores with
/// `lab eval --set <name> --model parakeet-tdt-v3 --hyp <file>` (the Lab target cannot link Engine).
///
/// Opt-in, never part of the normal gate: set `VOICEPLUS_EVAL_SET=librispeech-test-clean`
/// (optionally `VOICEPLUS_EVAL_LIMIT=N`, `VOICEPLUS_EVAL_CACHE=dir`). Output:
/// `<cache>/<set>/hyp-parakeet-tdt-v3.json`.
@Suite("Public-set replay (real model)", .serialized)
struct EvalPublicSetTests {
    struct Manifest: Decodable {
        struct Item: Decodable { let id: String; let audio: String? }
        let set: String
        let audioRoot: String
        let items: [Item]
    }
    struct HypItem: Encodable { let text: String; let latencyMs: Double }
    struct HypFile: Encodable { let model: String; let set: String; let peakRSSBytes: UInt64; let items: [String: HypItem] }

    static func cache() -> URL {
        if let c = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_CACHE"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return AppPaths.supportDirectory().appendingPathComponent("Eval", isDirectory: true)
    }

    static func peakRSS() -> UInt64 {
        var u = rusage()
        return getrusage(RUSAGE_SELF, &u) == 0 ? UInt64(max(0, u.ru_maxrss)) : 0
    }

    @Test(.timeLimit(.minutes(60)))
    func replayParakeetTDTv3() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["VOICEPLUS_EVAL_SET"], !set.isEmpty else {
            print("SKIPPED: set VOICEPLUS_EVAL_SET=<set> (after `lab fetch --set <set>`) to replay a public set through Parakeet TDT v3.")
            return
        }
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
        var out: [String: HypItem] = [:]
        for (n, item) in items.enumerated() {
            guard let audio = item.audio else { continue }
            let samples = try SampleAudioSource.load16k(url: root.appendingPathComponent(audio))
            let t0 = DispatchTime.now().uptimeNanoseconds
            let spans = try await final.recognize(samples)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            out[item.id] = HypItem(text: spans.joinedText, latencyMs: ms)
            if n % 250 == 0 { print("eval \(set): \(n)/\(items.count)") }
        }
        let file = HypFile(model: "parakeet-tdt-v3", set: set, peakRSSBytes: Self.peakRSS(), items: out)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let url = setDir.appendingPathComponent("hyp-parakeet-tdt-v3.json")
        try enc.encode(file).write(to: url)
        print("wrote \(out.count) hypotheses → \(url.path)")
        #expect(out.count == items.filter { $0.audio != nil }.count)
    }
}
