import Foundation
import Shared

/// Screenshot-free observation: what the planner sees. Built from the AX tree via `ActionSystem` only.
public struct AXSummary: Equatable, Sendable, Codable {
    public struct Element: Equatable, Sendable, Codable {
        public let role: String, title: String, value: String, isSelected: Bool, isEnabled: Bool
    }
    public var app: String
    public var window: String
    public var focusedElement: String?
    public var elements: [Element]
    public var runningApps: [String]
    public static let maxElements = 80

    public init(app: String, window: String, focusedElement: String? = nil, elements: [Element] = [], runningApps: [String] = []) {
        self.app = app; self.window = window; self.focusedElement = focusedElement; self.elements = elements; self.runningApps = runningApps
    }

    public init(system: ActionSystem) {
        let s = system.snapshot()
        app = s.frontmostApp?.name ?? "(none)"
        window = s.focusedWindow?.title ?? "(none)"
        focusedElement = s.focusedElement.map { "\($0.role) \($0.title)" }
        elements = (s.focusedWindow.map(system.elements(in:)) ?? []).prefix(Self.maxElements)
            .map { Element(role: $0.role, title: $0.title, value: String($0.value.prefix(60)), isSelected: $0.isSelected, isEnabled: $0.isEnabled) }
        runningApps = system.runningApps().map(\.name)
    }

    /// Compact prompt text for a provider planner.
    public var promptText: String {
        var s = "app: \(app)\nwindow: \(window)\nfocused: \(focusedElement ?? "-")\nelements:\n"
        for e in elements { s += "- \(e.role) \"\(e.title)\"\(e.value.isEmpty ? "" : " = \"\(e.value)\"")\(e.isSelected ? " [selected]" : "")\(e.isEnabled ? "" : " [disabled]")\n" }
        return s + "apps: \(runningApps.joined(separator: ", "))"
    }
}

/// The action vocabulary exposed to the planner as tools: exactly the deterministic kinds, nothing pixel-based.
public struct AgentTool: Equatable, Sendable, Codable {
    public let kind: ActionKind
    public let description: String
    public let params: [String]
    public static let vocabulary: [AgentTool] = [
        .init(kind: .click, description: "Press a control by its accessible name", params: ["name"]),
        .init(kind: .fillField, description: "Set a text field's value", params: ["name", "value"]),
        .init(kind: .focusApp, description: "Activate or launch an app", params: ["target"]),
        .init(kind: .focusWindow, description: "Raise a window by title", params: ["target"]),
        .init(kind: .focusTab, description: "Select a tab by title, or next/previous", params: ["target"]),
        .init(kind: .windowOp, description: "minimize/close/zoom/fullscreen/restore the focused window", params: ["op"]),
        .init(kind: .switchSpace, description: "left/right/<index>/missionControl/showDesktop", params: ["move"]),
        .init(kind: .scroll, description: "Scroll up/down/left/right/top/bottom", params: ["direction", "amount"]),
        .init(kind: .shortcut, description: "Send a key chord, e.g. cmd+shift+t", params: ["keys"]),
        .init(kind: .typeText, description: "Type text into the focused input", params: ["value"]),
        .init(kind: .openURL, description: "Open a URL in the default browser", params: ["url"]),
        .init(kind: .openFile, description: "Open a file or folder path", params: ["path"]),
    ]
}

/// One planned step. `compensating` is the action that reverses it, used on stop/rollback.
public struct PlanStep: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let request: ActionRequest
    public let compensating: ActionRequest?
    public init(id: String = UUID().uuidString, title: String, request: ActionRequest, compensating: ActionRequest? = nil) {
        self.id = id; self.title = title; self.request = request; self.compensating = compensating
    }
}

public struct StepPlan: Equatable, Sendable {
    public let goal: String
    public var steps: [PlanStep]
    public var rationale: String
    public init(goal: String, steps: [PlanStep], rationale: String = "") { self.goal = goal; self.steps = steps; self.rationale = rationale }
}

public enum AgentRunStatus: Equatable, Sendable {
    case completed(summary: String)
    case stopped                       // "stop" spoken or pill tapped
    case timedOut
    case declined                      // user cancelled a confirmation card
    case failed(reason: String)
    case gaveUp(reason: String)        // planner could not make progress
}

public struct StepRecord: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case done(verified: Bool), failed(String), skipped, rolledBack }
    public let step: PlanStep
    public let outcome: Outcome
}

public struct AgentRunReport: Equatable, Sendable {
    public let goal: String
    public let status: AgentRunStatus
    public let records: [StepRecord]
    public let rounds: Int
    public var executedSteps: [PlanStep] { records.compactMap { if case .done = $0.outcome { return $0.step }; return nil } }
}

/// P4.5 backend contract. `NativeAgentBackend` is the shipped implementation; a Cua-backed one can be slotted later
/// (license verified MIT — see README) without touching the router.
public protocol AgentActionBackend: AnyObject, Sendable {
    func run(goal: String) async -> AgentRunReport
    /// Sacred: cancels anything in flight, drops queued steps and rolls back what it can.
    func stop() async
    var isRunning: Bool { get }
}
