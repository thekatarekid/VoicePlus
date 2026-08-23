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

    public static func showLab(registry: LabRegistry, database: AppDatabase?) {
        if let labWindow { front(labWindow); return }
        let model = LabPanelViewModel(registry: registry, database: database)
        labModel = model
        labWindow = makeWindow(title: "VoicePlus Lab", view: LabPanelView(model: model), size: NSSize(width: 720, height: 560))
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
