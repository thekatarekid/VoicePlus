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
                                biasing: BiasingController?) -> LabRegistry {
        var registry = LabRegistry.mocks
        for stage in StageRegistry.allStages() {
            registry.stages[stage.id.rawValue] = { stage }
        }
        registry.stages["pipeline"] = { PipelineStageChain(runner: PipelineRunner.standard()) }
        if let repair { registry.stages[StageID.repair.rawValue] = { RepairStage(session: repair) } }

        if let modelManager {
            registry.transcribers["engine"] = { _ in try makeEngineTranscriber(manager: modelManager, biasing: biasing) }
        }
        return registry
    }

    static func makeEngineTranscriber(manager: ModelManager, biasing: BiasingController?) throws -> any FixtureTranscriber {
        let feed = FileFeedAudioSource()
        let provider = BiasingRecognizerProvider(inner: ModelManagerRecognizerProvider(manager: manager))
        let engine = RealEngine(audio: feed, provider: provider)
        return EngineFixtureTranscriber(name: "engine", engine: engine) { url in
            provider.install(biasing?.makeBiaser())
            try feed.feed(url: url)
        }
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

/// Lab + Data Panel windows off the status menu (SwiftUI panels from P1.11 in plain NSWindows).
@MainActor
public enum LabWindowController {
    private static var labWindow: NSWindow?
    private static var dataWindow: NSWindow?
    private static var labModel: LabPanelViewModel?
    private static var dataModel: Lab.DataPanelViewModel?

    public static func showLab(registry: LabRegistry, database: AppDatabase?, personalWER: PersonalWERTracker? = nil) {
        if let labWindow { front(labWindow); return }
        let model = LabPanelViewModel(registry: registry, database: database)
        labModel = model
        // P6.1 — "you" tab: personal WER trend next to the fixture runs.
        let view = TabView {
            LabPanelView(model: model).tabItem { Label("Runs", systemImage: "chart.bar") }
            PersonalWERView(tracker: personalWER).tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        labWindow = makeWindow(title: "VoicePlus Lab", view: view, size: NSSize(width: 720, height: 560))
    }

    public static func showDataPanel(database: AppDatabase?, gate: EgressGate) {
        if let dataWindow { front(dataWindow); return }
        let model = Lab.DataPanelViewModel(database: database, gate: gate)
        dataModel = model
        dataWindow = makeWindow(title: "Data Panel", view: DataPanelView(model: model), size: NSSize(width: 560, height: 480))
    }

    private static func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let host = NSHostingController(rootView: view.frame(minWidth: size.width, minHeight: size.height))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        front(w)
        return w
    }

    private static func front(_ w: NSWindow) {
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
