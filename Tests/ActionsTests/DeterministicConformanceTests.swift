import Testing
import Foundation
@testable import Actions

/// Phase gate: 15 mock apps × every applicable catalogued action, fresh desktop per cell, phrase → catalogue → execute → readback.
@Suite struct DeterministicConformanceTests {
    @Test func conformanceMatrixMeetsPhaseGate() throws {
        let catalog = try ActionCatalog.load()
        var total = 0, ok = 0, verified = 0, failures: [String] = []
        var perApp: [String: (Int, Int)] = [:]
        for app in DeterministicMockApps.apps {
            for e in catalog.entries where e.applies(to: app.kind) {
                let sys = DeterministicMockApps.desktop(catalog: catalog, front: app.bundle)
                let layer = DeterministicActionLayer(catalog: catalog, system: sys)
                let phrase = DeterministicMockApps.phrase(for: e)
                total += 1; perApp[app.name, default: (0, 0)].1 += 1
                guard let (m, _) = layer.resolve(phrase, appKind: app.kind), m.entry.id == e.id else { failures.append("\(app.name)/\(e.id): resolved to \(layer.resolve(phrase, appKind: app.kind)?.0.entry.id ?? "nil")"); continue }
                guard let r = layer.perform(phrase, appKind: app.kind) else { failures.append("\(app.name)/\(e.id): no match"); continue }
                if case .success(let v) = r.outcome { ok += 1; perApp[app.name]!.0 += 1; if v { verified += 1 } }
                else { failures.append("\(app.name)/\(e.id) '\(phrase)': \(r.outcome)") }
            }
        }
        let rate = Double(ok) / Double(total)
        print("P4.1 conformance: \(ok)/\(total) = \(String(format: "%.2f", rate * 100))% success (\(verified) readback-verified, \(ok - verified) delivery-only) across \(perApp.count) apps × \(catalog.entries.count) actions")
        for (a, c) in perApp.sorted(by: { $0.key < $1.key }) { print("  \(a): \(c.0)/\(c.1)") }
        if !failures.isEmpty { print("  failures: \(failures)") }
        #expect(perApp.count == 15)
        #expect(rate >= 0.99, "phase gate ≥99%; failures: \(failures)")
    }
}
