import Foundation
import Shared

/// Thermal readout abstracted so tests can script it (Risk 10 measurement).
public protocol ThermalSource: Sendable {
    func current() -> ProcessInfo.ThermalState
}

public struct SystemThermalSource: ThermalSource {
    public init() {}
    public func current() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

public struct ThermalReadout: Equatable, Sendable {
    public var state: ProcessInfo.ThermalState
    public var name: String { LabRunner.thermalName(state) }
    /// 0…3 severity for a gauge.
    public var level: Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

/// One configuration row the user can toggle in the panel (flags × transcribers × stages).
public struct LabConfigChoice: Identifiable, Equatable, Sendable {
    public var id: String { config.name }
    public var config: LabConfig
    public var selected: Bool
    public init(config: LabConfig, selected: Bool = true) { self.config = config; self.selected = selected }
}

/// Drives `LabPanelView`. Pure state machine — no AppKit; `run()` is async and injectable.
@MainActor
public final class LabPanelViewModel: ObservableObject {
    public enum Phase: Equatable { case idle, running(done: Int, total: Int), finished, failed(String) }

    @Published public var choices: [LabConfigChoice]
    @Published public var phase: Phase = .idle
    @Published public var reports: [LabReport] = []
    @Published public var thermal: ThermalReadout
    @Published public var thermalHistory: [ThermalReadout] = []
    @Published public var lastItem: ItemScore?

    public let registry: LabRegistry
    public let thermalSource: any ThermalSource
    public let database: AppDatabase?
    public var runner: LabRunner

    public init(choices: [LabConfigChoice] = LabPanelViewModel.defaultChoices(), registry: LabRegistry = .mocks,
                thermalSource: any ThermalSource = SystemThermalSource(), database: AppDatabase? = nil,
                runner: LabRunner = LabRunner()) {
        self.choices = choices
        self.registry = registry
        self.thermalSource = thermalSource
        self.database = database
        self.runner = runner
        self.thermal = ThermalReadout(state: thermalSource.current())
    }

    /// The acceptance comparison: voice repair on vs off. (The old "biasing on/off" pair compared the
    /// `contextBiasing` flag, deleted by V5 A1/B1; boosting is measured by `lab eval` on public sets.)
    nonisolated public static func defaultChoices(transcriber: String = "perfect", stages: [String] = []) -> [LabConfigChoice] {
        [
            LabConfigChoice(config: LabConfig(name: "repair on", transcriber: transcriber, stages: stages, flags: [FeatureFlag.voiceRepair.id: true])),
            LabConfigChoice(config: LabConfig(name: "repair off", transcriber: transcriber, stages: stages, flags: [FeatureFlag.voiceRepair.id: false])),
        ]
        // R1.5 preview candidates, offered but not selected: the default run stays the repair comparison.
        + LabConfigChoice.previewBackendChoices(transcriber: transcriber, stages: stages)
    }

    public var selectedConfigs: [LabConfig] { choices.filter(\.selected).map(\.config) }
    public var isRunning: Bool { if case .running = phase { return true } else { return false } }

    public func refreshThermal() {
        thermal = ThermalReadout(state: thermalSource.current())
        thermalHistory.append(thermal)
        if thermalHistory.count > 120 { thermalHistory.removeFirst() }
    }

    /// Runs every selected configuration sequentially, persisting each to the database if present.
    public func run() async {
        let configs = selectedConfigs
        guard !configs.isEmpty, !isRunning else { return }
        reports = []
        thermalHistory = []
        phase = .running(done: 0, total: configs.count)
        for (idx, config) in configs.enumerated() {
            do {
                refreshThermal()
                let suites = try runner.loadSuites(config)
                let transcriber = try registry.transcriber(config.transcriber, suites: suites)
                let stages = try registry.stages(config.stages)
                var lab = runner
                let box = ProgressBox()
                lab.progress = { _, _, item in box.last = item }
                let report = try await lab.run(config: config, transcriber: transcriber, stages: stages)
                lastItem = box.last
                if let database { try report.persist(to: database) }
                reports.append(report)
                refreshThermal()
                phase = .running(done: idx + 1, total: configs.count)
            } catch {
                phase = .failed("\(config.name): \(error)")
                return
            }
        }
        phase = .finished
    }

    public var comparisonMarkdown: String { ReportWriter.comparison(reports) }

    /// Waterfall rows: ASR then each stage, mean ms, for a report.
    nonisolated public static func waterfall(_ report: LabReport) -> [(label: String, ms: Double)] {
        let asr = report.items.isEmpty ? 0 : report.items.reduce(0) { $0 + $1.asrLatencyMs } / Double(report.items.count)
        return [(label: "asr (\(report.config.transcriber))", ms: asr)]
            + report.config.stages.map { (label: $0, ms: report.stageLatencyMs[$0] ?? 0) }
    }

    private final class ProgressBox: @unchecked Sendable { var last: ItemScore? }
}

/// Drives `DataPanelView`.
@MainActor
public final class DataPanelViewModel: ObservableObject {
    @Published public var model: DataPanelModel
    @Published public var error: String?
    public let database: AppDatabase?
    public let gate: EgressGate

    public init(database: AppDatabase?, gate: EgressGate = .shared) {
        self.database = database
        self.gate = gate
        self.model = DataPanelModel(records: [], killSwitchOn: gate.isKillSwitchOn)
    }

    public func reload(now: Date = Date()) {
        guard let database else { model = DataPanelModel(records: [], killSwitchOn: gate.isKillSwitchOn, generatedAt: now); return }
        do { model = try DataPanelModel.load(db: database, gate: gate, now: now) } catch { self.error = "\(error)" }
    }

    public var killSwitch: Bool {
        get { model.killSwitchOn }
        set { gate.isKillSwitchOn = newValue; model.killSwitchOn = newValue }
    }
}

/// Drives the menu-bar zero-edit stat.
@MainActor
public final class ZeroEditViewModel: ObservableObject {
    @Published public var stat: ZeroEditStat
    public let database: AppDatabase?

    public init(database: AppDatabase?, now: Date = Date()) {
        self.database = database
        self.stat = ZeroEditStats.rollup([], days: 14, now: now)
    }

    public func reload(now: Date = Date()) {
        guard let database, let s = try? ZeroEditStats.trend(db: database, now: now) else { return }
        stat = s
    }
}
