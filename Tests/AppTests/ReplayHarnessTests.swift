import Foundation
import Testing
import Engine
import Pipeline
import Shared
@testable import VoicePlusApp

// T-replay — the recorded-dictation replay tool: raw vs boosted text, swaps, the three channels and
// the surface-formatted final text, all from MockDecoder + a scripted booster (no model, no injection).

private func tok(_ id: Int, _ text: String, _ start: Double) -> DecodedToken {
    DecodedToken(tokenId: id, text: text, logProb: -0.05, startTime: start, endTime: start + 0.2)
}

private let script = [tok(1, "▁there", 0.1), tok(2, "▁is", 0.4), tok(3, "▁no", 0.7), tok(4, "▁budget", 1.0)]
private let samples = [Float](repeating: 0, count: 32_000)

private func runner(booster: VocabularyBooster?, decorate: @escaping (StageContext) -> StageContext = { $0 },
                    cleanup: ((inout StageContext) -> Void)? = nil) -> ReplayRunner {
    let stages = FieldRolePipeline.replacingFormatters(in: StageRegistry.allStages().filter { $0.id != .gatekeeper })
    return ReplayRunner(recognizer: DecoderFinalRecognizer(decoder: MockDecoder(script: script)),
                        makeBooster: { booster }, pipeline: PipelineRunner(stages: stages),
                        decorate: decorate, cleanupContext: cleanup)
}

struct ReplayHarnessTests {
    @Test func reportsRawBoostedSwapsAndChannels() async throws {
        let booster = ScriptedVocabularyBooster(terms: ["Bucket", "Akash"], rewrites: ["budget": "Bucket"])
        let r = runner(booster: booster,
                       decorate: { var c = $0; c.extra[Personalisation.dictionaryKey] = "Bucket\nDOCUBE"; return c },
                       cleanup: { $0.extra[ContextPromptKeys.prompt] = "Bucket, Cab" })
        let report = await r.run(samples: samples, source: "t.wav", surface: try #require(ReplaySurface.named("prose")))
        #expect(report.error == nil)
        #expect(report.rawText == "there is no budget")
        #expect(report.boostedText == "there is no Bucket")
        #expect(report.swaps == [.init(from: "budget", to: "Bucket")])
        #expect(report.channels.boost == ["Bucket", "Akash"])
        #expect(report.channels.spell == ["Bucket", "DOCUBE"])
        #expect(report.channels.cleanup == "Bucket, Cab")
        #expect(report.finalText.contains("Bucket"))
        #expect(report.rendered.contains("budget → Bucket"))
        #expect(abs(report.seconds - 2) < 0.001)
    }

    @Test func noBoosterMeansBoostedEqualsRaw() async throws {
        let report = await runner(booster: nil).run(samples: samples, source: "t.wav",
                                                    surface: try #require(ReplaySurface.named("chat")))
        #expect(report.rawText == report.boostedText)
        #expect(report.swaps.isEmpty && report.channels.boost.isEmpty && report.channels.cleanup == nil)
        #expect(!report.finalText.isEmpty)
    }

    @Test func surfaceChangesFormatting() async throws {
        let prose = await runner(booster: nil).run(samples: samples, source: "t", surface: try #require(ReplaySurface.named("notes")))
        let terminal = await runner(booster: nil).run(samples: samples, source: "t", surface: try #require(ReplaySurface.named("terminal")))
        #expect(prose.finalText.hasPrefix("There"))
        #expect(!terminal.finalText.hasSuffix("."))
        #expect(terminal.appBundleID == "com.apple.Terminal")
    }

    @Test func surfacesAndAppOverride() {
        for kind in ReplaySurface.kinds { #expect(ReplaySurface.named(kind) != nil) }
        #expect(ReplaySurface.named("bogus") == nil)
        #expect(ReplaySurface.named("chat", app: "com.x")?.field.appBundleID == "com.x")
        #expect(ReplaySurface.named("chat")?.field.submitsOnReturn == true)
    }

    @Test func cliParse() {
        #expect(ReplayCLI.parse(["app"]) == nil)
        let o = ReplayCLI.parse(["app", "--replay", "11:34:44", "--surface", "terminal", "--json", "/tmp/x.jsonl"])
        #expect(o?.target == "11:34:44" && o?.surface == "terminal" && o?.json == "/tmp/x.jsonl" && o?.app == nil)
        #expect(ReplayCLI.parse(["app", "--replay", "a.wav"])?.surface == "prose")
    }

    @Test func resolvesRecordingsFixturesAndTimes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("Recordings"), fix = root.appendingPathComponent("Fixtures/audio")
        try fm.createDirectory(at: rec, withIntermediateDirectories: true)
        try fm.createDirectory(at: fix, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for n in ["2026-10-01-113444-001-raw.wav", "2026-10-01-113444-001-processed.wav", "2026-10-02-113444-500-raw.wav",
                  "2026-10-02-113444-500-processed.wav", "2026-10-02-091822-100-raw.wav", "2026-10-02-091822-100.json"] {
            fm.createFile(atPath: rec.appendingPathComponent(n).path, contents: Data())
        }
        fm.createFile(atPath: fix.appendingPathComponent("b.wav").path, contents: Data())
        fm.createFile(atPath: fix.appendingPathComponent("a.wav").path, contents: Data())
        let fixtures = root.appendingPathComponent("Fixtures")
        func names(_ arg: String, turn: @escaping (String) -> String? = { _ in nil }) -> [String] {
            ReplaySources.resolve(arg, recordings: rec, fixtures: fixtures, turnAudio: turn).map(\.lastPathComponent)
        }
        #expect(names("11:34:44") == ["2026-10-02-113444-500-processed.wav"])            // newest at that second
        #expect(names("2026-10-01-113444") == ["2026-10-01-113444-001-processed.wav"])   // stamp prefix
        #expect(names("091822") == ["2026-10-02-091822-100-raw.wav"])                    // raw when no processed
        #expect(names(rec.path).count == 2)                                               // folder → processed only
        #expect(names("audio") == ["a.wav", "b.wav"])                                     // fixture folder
        #expect(names("audio/b.wav") == ["b.wav"])
        #expect(names("12:00:00").isEmpty)
        let turnWav = fix.appendingPathComponent("a.wav").path
        #expect(names("1A2B3C4D", turn: { $0 == "1A2B3C4D" ? turnWav : nil }) == ["a.wav"])
    }
}
