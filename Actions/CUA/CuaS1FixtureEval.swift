import Foundation
import Shared

// MARK: - V5 CU2 · GUI-360-style text-task fixture for the chooser
//
// `Fixtures/public/cua-s1-text/gui360-style-tasks.json`: hand-authored text tasks (goal + AX
// elements + the expected (element, action)). The bar for the shipped model is ≥ 80 % (vendor:
// 85.5 % gptq on the GUI-360 text split). Measured on hardware with the real model → T1; in tests
// the harness runs against mocks.

public struct CuaS1FixtureTask: Codable, Equatable, Sendable {
    public struct Element: Codable, Equatable, Sendable {
        public var role: String, title: String, value: String, selected: Bool, enabled: Bool
    }
    public struct Expect: Codable, Equatable, Sendable { public var label: String, action: String }
    public var id: String
    public var app: String
    public var window: String
    public var goal: String
    public var elements: [Element]
    public var entities: [CuaS1Entity]
    public var expect: Expect

    public var observation: AXSummary {
        AXSummary(app: app, window: window,
                  elements: elements.map { AXSummary.Element(role: $0.role, title: $0.title, value: $0.value,
                                                             isSelected: $0.selected, isEnabled: $0.enabled) })
    }
}

public struct CuaS1FixtureSet: Codable, Sendable {
    public var name: String
    public var note: String
    public var tasks: [CuaS1FixtureTask]

    public static var defaultURL: URL? {
        AppPaths.fixturesDirectory()?.appendingPathComponent("public/cua-s1-text/gui360-style-tasks.json")
    }

    public static func load(_ url: URL? = defaultURL) throws -> CuaS1FixtureSet {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(CuaS1FixtureSet.self, from: Data(contentsOf: url))
    }
}

public struct CuaS1EvalReport: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let id: String
        public let hit: Bool
        public let chosen: String
        public let decisions: Int
    }
    public let set: String
    public let model: String
    public let rows: [Row]
    public var accuracy: Double { rows.isEmpty ? 0 : Double(rows.filter(\.hit).count) / Double(rows.count) }
    /// The CU2 bar.
    public static let target = 0.80
    public var meetsTarget: Bool { accuracy >= Self.target }
}

public enum CuaS1FixtureEval {
    public static func run(_ set: CuaS1FixtureSet, chooser: CuaS1Chooser, model: String) async -> CuaS1EvalReport {
        var rows: [CuaS1EvalReport.Row] = []
        for task in set.tasks {
            do {
                let c = try await chooser.choose(goal: task.goal, observation: task.observation, entities: task.entities)
                let hit = c.option.label == task.expect.label && c.option.action == task.expect.action
                rows.append(.init(id: task.id, hit: hit, chosen: "\(c.option.action) \(c.option.label)", decisions: c.decisions))
            } catch {
                rows.append(.init(id: task.id, hit: false, chosen: "error: \(error)", decisions: 0))
            }
        }
        return CuaS1EvalReport(set: set.name, model: model, rows: rows)
    }
}
