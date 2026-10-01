import AppKit
import Engine
import Foundation
import Lab
import Pipeline
import Shared
import SwiftUI

/// P1.12 — the Lab registry with the real pieces: every `StageRegistry` stage by id, the
/// repair stage, and (when a recogniser exists) an `engine` transcriber that replays WAV
/// fixtures through a `RealEngine` fed by `FileFeedAudioSource` — same decoder as dictation,
/// no microphone.
public enum LabWiring {
    public static func registry(modelManager: ModelManager?, repair: RepairSession?,
                                boosting: BoostingController?) -> LabRegistry {
        var registry = LabRegistry.mocks
        for stage in StageRegistry.allStages() {
            registry.stages[stage.id.rawValue] = { stage }
        }
        registry.stages["pipeline"] = { PipelineStageChain(runner: PipelineRunner.standard()) }
        if let repair { registry.stages[StageID.repair.rawValue] = { RepairStage(session: repair) } }

        if let modelManager {
            registry.transcribers["engine"] = { _ in try makeEngineTranscriber(manager: modelManager, boosting: boosting) }
            registry.evalBackends["parakeet-tdt-v3"] = { FinalRecognizerEvalBackend(modelID: "parakeet-tdt-v3", manager: modelManager) }
            LanguageASRRouting.registerEvalBackends(&registry)   // V5 G1/G2
        }
        return registry
    }

    static func makeEngineTranscriber(manager: ModelManager, boosting: BoostingController?) throws -> any FixtureTranscriber {
        let feed = FileFeedAudioSource()
        let provider = BiasingRecognizerProvider(inner: ModelManagerRecognizerProvider(manager: manager))
        let engine = RealEngine(audio: feed, provider: provider)
        return EngineFixtureTranscriber(name: "engine", engine: engine) { url in
            provider.install(boosting?.makeBoosterForUtterance())
            try feed.feed(url: url)
        }
    }
}

/// V5 V1 — `lab eval --model parakeet-tdt-v3`: the dictation final-pass recognizer on public-set
/// audio (batch, same decoder as dictation). Created lazily on first item.
final class FinalRecognizerEvalBackend: EvalBackend, @unchecked Sendable {
    let modelID: String
    let manager: ModelManager
    private var recognizer: FinalRecognizer?

    init(modelID: String, manager: ModelManager) { self.modelID = modelID; self.manager = manager }

    func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput {
        guard stage == .asr, let audioURL else { throw EvalError.stageUnsupported("\(modelID) does \(EvalStage.asr.rawValue) only") }
        if recognizer == nil { recognizer = try await RecognizerFactory.makeFinal(manager: manager) }
        let samples = try SampleAudioSource.load16k(url: audioURL)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let spans = try await recognizer!.recognize(samples)
        return EvalOutput(text: spans.joinedText, latencyMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
}

/// Whole `PipelineRunner` as one Lab stage (gatekeeper + register-routed formatters + style).
public struct PipelineStageChain: PipelineStage {
    public let id: StageID = "pipeline"
    public let runner: PipelineRunner
    public init(runner: PipelineRunner) { self.runner = runner }
    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        try await runner.run(spans, context: context).spans
    }
}

/// R7.2 — the Lab and the Data Panel are sections of the one window now (`DESIGN.md` §9.4, §9.5):
/// Lab → Voice › Benchmarks, Data Panel → Privacy › Diagnostics. This enum is the shim the composition
/// root still calls; it forwards what it was handed to `MainWindowController.environment` and opens
/// the window at the disclosure itself (W3H), not merely its section — the menu's "Lab…" and "Data
/// Panel…" land on what they name, expanded. Neither function creates an `NSWindow` any more.
@MainActor
public enum LabWindowController {
    /// Voice › Benchmarks (design §8.4): stage, result and diagnostics — the old Lab window.
    public static let labRoute = WindowRoute(.voice, disclosure: .benchmarks)
    /// Privacy › Diagnostics (design §8.5): feature flags and the data panel — the old Data Panel.
    public static let dataPanelRoute = WindowRoute(.privacy, disclosure: .diagnostics)

    /// `open` defaults to the live window; tests pass a recorder.
    public static func showLab(registry: LabRegistry, database: AppDatabase?, personalWER: PersonalWERTracker? = nil,
                               open: @MainActor (WindowRoute) -> Void = { _ = MainWindowController.show(route: $0) }) {
        MainWindowController.environment.labRegistry = registry
        MainWindowController.environment.personalWER = personalWER
        open(labRoute)
    }

    public static func showDataPanel(database: AppDatabase?, gate: EgressGate,
                                     open: @MainActor (WindowRoute) -> Void = { _ = MainWindowController.show(route: $0) }) {
        MainWindowController.environment.egressGate = gate
        open(dataPanelRoute)
    }
}

/// P6.1 — the Lab "you" tab: personal WER per day, day-1 vs latest, sample counts.
struct PersonalWERView: View {
    let tracker: PersonalWERTracker?

    var body: some View {
        let days = tracker?.report() ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your recognition, day by day").font(.headline)
            Text("Word error rate over your own corrections and edits — lower is better. The bet: day-30 beats day-1.")
                .font(.caption).foregroundStyle(.secondary)
            if days.isEmpty {
                Spacer()
                Text("No data yet — corrections and post-dictation edits feed this table.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                if let first = days.first, let last = days.last, days.count > 1 {
                    let improved = last.wer < first.wer
                    Label(String(format: "day 1: %.1f%%  →  latest: %.1f%% %@",
                                 first.wer * 100, last.wer * 100, improved ? "(improving)" : ""),
                          systemImage: improved ? "arrow.down.right.circle.fill" : "minus.circle")
                        .foregroundStyle(improved ? .green : .secondary)
                }
                HStack {
                    Text("Day").frame(width: 90, alignment: .leading)
                    Text("WER").frame(width: 60, alignment: .trailing)
                    Text("Words").frame(width: 60, alignment: .trailing)
                    Text("Errors").frame(width: 60, alignment: .trailing)
                    Text("Utterances").frame(width: 80, alignment: .trailing)
                }.font(.caption.bold())
                List(days, id: \.day) { d in
                    HStack {
                        Text(d.day).frame(width: 90, alignment: .leading)
                        Text(String(format: "%.1f%%", d.wer * 100)).frame(width: 60, alignment: .trailing)
                        Text("\(d.referenceWords)").frame(width: 60, alignment: .trailing)
                        Text("\(d.errors)").frame(width: 60, alignment: .trailing)
                        Text("\(d.utterances)").frame(width: 80, alignment: .trailing)
                    }.font(.caption.monospacedDigit())
                }
            }
        }
        .padding(12)
    }
}
