import Foundation
import Testing
import Shared
@testable import Lab

@Suite struct DataPanelTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func rec(_ hoursAgo: Double, host: String = "api.example.com", out: Int, inBytes: Int = 0) -> NetworkLogRecord {
        NetworkLogRecord(timestamp: now.addingTimeInterval(-hoursAgo * 3600), stage: "pipeline", provider: "p", host: host,
                         bytesOut: out, bytesIn: inBytes, purpose: "test")
    }

    @Test func defaultConfigIsClean() throws {
        let db = try AppDatabase.inMemory()
        let gate = EgressGate(defaults: UserDefaults(suiteName: "lab-test-\(UUID().uuidString)")!)
        let m = try DataPanelModel.load(db: db, gate: gate, now: now)
        #expect(m.isClean && m.totalBytesOut == 0 && !m.killSwitchOn)
        #expect(m.hourlyRollup().count == 24)
        #expect(m.hourlyRollup().allSatisfy { $0.requests == 0 })
    }

    @Test func hourlyRollupMath() {
        let m = DataPanelModel(records: [
            rec(0.1, out: 100, inBytes: 10), rec(0.2, host: "b.com", out: 50), rec(1.5, out: 1000), rec(23.0, out: 7), rec(30, out: 999),
        ], killSwitchOn: false, generatedAt: now)
        let buckets = m.hourlyRollup(hours: 24, calendar: Calendar(identifier: .gregorian))
        #expect(buckets.count == 24)
        #expect(buckets.map(\.hour) == buckets.map(\.hour).sorted())
        let current = buckets.last!
        #expect(current.requests == 2 && current.bytesOut == 150 && current.bytesIn == 10 && Set(current.hosts) == ["api.example.com", "b.com"])
        #expect(buckets.reduce(0) { $0 + $1.bytesOut } == 1157, "30h-old record excluded")
        #expect(buckets.filter { $0.requests > 0 }.count == 3)
        #expect(m.bytesOut(lastHours: 1) == 150)
        #expect(m.bytesOut(lastHours: 24) == 1157)
        #expect(m.byHost().first?.host == "api.example.com" && m.byHost().first?.bytesOut == 2106)
    }

    @Test func egressGateKillSwitch() throws {
        let defaults = UserDefaults(suiteName: "lab-gate-\(UUID().uuidString)")!
        let db = try AppDatabase.inMemory()
        let gate = EgressGate(defaults: defaults, database: db)
        #expect(gate.isAllowed(host: "api.openai.com"))
        gate.isKillSwitchOn = true
        #expect(defaults.bool(forKey: EgressGate.killSwitchKey))
        #expect(!gate.isAllowed(host: "api.openai.com"))
        #expect(throws: EgressGate.Denied.killSwitch(host: "x")) { try gate.check(host: "x") }
        #expect(gate.blockedAttempts.map(\.1) == ["api.openai.com", "x"])
        // Closure-injection shape Providers use:
        let allowed: @Sendable (String) -> Bool = { gate.isAllowed(host: $0) }
        #expect(allowed("anything") == false)
        gate.isKillSwitchOn = false
        #expect(allowed("anything"))
        let logged = try gate.log(stage: "asr", provider: "cloud", host: "h", bytesOut: 12, bytesIn: 3, purpose: "t")
        #expect(logged?.id != nil)
        #expect(try db.bytesEgressed(since: .distantPast) == 12)
        let m = try DataPanelModel.load(db: db, gate: gate)
        #expect(!m.isClean && m.records.count == 1)
    }

    @Test @MainActor func viewModelsWork() async throws {
        let db = try AppDatabase.inMemory()
        let gate = EgressGate(defaults: UserDefaults(suiteName: "lab-vm-\(UUID().uuidString)")!)
        let vm = DataPanelViewModel(database: db, gate: gate)
        vm.reload()
        #expect(vm.model.isClean)
        vm.killSwitch = true
        #expect(gate.isKillSwitchOn && vm.model.killSwitchOn)

        let zero = ZeroEditViewModel(database: db)
        zero.reload()
        #expect(zero.stat.trend.count == 14 && zero.stat.today.words == 0)

        struct FixedThermal: ThermalSource { func current() -> ProcessInfo.ThermalState { .serious } }
        let lab = LabPanelViewModel(choices: LabPanelViewModel.defaultChoices().map { var c = $0; c.config.suites = ["entity"]; return c },
                                    thermalSource: FixedThermal(), database: db,
                                    runner: LabRunner(clock: { 0 }, hardware: "vm", thermal: { .serious }))
        #expect(lab.thermal.name == "serious" && lab.thermal.level == 2)
        #expect(lab.selectedConfigs.map(\.name) == ["repair on", "repair off"])
        await lab.run()
        #expect(lab.phase == .finished)
        #expect(lab.reports.count == 2)
        #expect(lab.reports.allSatisfy { $0.overall.wer == 0 })
        #expect(try db.labRuns().count == 2)
        #expect(lab.comparisonMarkdown.contains("repair on"))
        #expect(LabPanelViewModel.waterfall(lab.reports[0]).first?.label == "asr (perfect)")
        #expect(lab.lastItem?.suite == "entity")
        #expect(lab.thermalHistory.count == 4)
    }
}
