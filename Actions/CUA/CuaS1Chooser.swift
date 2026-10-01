import Foundation

// MARK: - V5 CU2 · CUA-S1 element chooser
//
// One step, no planner: read the AX summary as text, offer the model (element, action) options, take
// its pick, turn it into an `ActionRequest` and hand that to `ActionExecutor` (which re-finds the
// control by name and verifies the result — the model never touches the screen itself).
//
// The model takes at most 26 lettered options per decision. Larger windows are paged: options are
// grouped (an element's options never split across pages), each page picks its winner, and the
// winners meet in a final decision. Every page is one forward pass (~0.7 s on M5 Pro, gptq).

/// A value the goal provides for a field (`fill Email: a@b.c`).
public struct CuaS1Entity: Equatable, Sendable, Codable {
    public var label: String
    public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

public struct CuaS1Choice: Equatable, Sendable {
    public let option: CuaS1Option
    public let probability: Double
    public let request: ActionRequest
    /// Forward passes spent (pages + final rounds).
    public let decisions: Int
}

public final class CuaS1Chooser: @unchecked Sendable {
    public let model: any CuaS1Deciding
    public let pageSize: Int

    public init(model: any CuaS1Deciding, pageSize: Int = CuaS1State.maxOptions) {
        self.model = model
        self.pageSize = max(2, min(pageSize, CuaS1State.maxOptions))
    }

    // MARK: Candidates

    /// What can be done to an element of this role. Static text, images and groups are context only.
    public static func actions(forRole role: String, hasEntities: Bool) -> [String] {
        switch role {
        case "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle", "AXCell", "AXRow":
            return ["click"]
        case "AXCheckBox", "AXSwitch": return ["check"]
        case "AXTab", "AXRadioButton": return ["select"]
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return hasEntities ? ["fill"] : ["focus"]
        default: return []
        }
    }

    /// The AX tree text and the options for one observation. Elements are numbered in tree order.
    public static func candidates(from observation: AXSummary, entities: [CuaS1Entity])
        -> (tree: String, options: [CuaS1Option]) {
        var lines: [String] = []
        var options: [CuaS1Option] = []
        for (i, e) in observation.elements.enumerated() {
            let id = "el_\(i)"
            var line = "- [\(id)] \(e.role.replacingOccurrences(of: "AX", with: "")) \"\(e.title)\""
            if !e.value.isEmpty { line += " value=\"\(e.value)\"" }
            if e.isSelected { line += " selected" }
            if !e.isEnabled { line += " disabled" }
            lines.append(line)
            guard e.isEnabled, !e.title.isEmpty else { continue }
            let role = e.role.replacingOccurrences(of: "AX", with: "")
            for action in actions(forRole: e.role, hasEntities: !entities.isEmpty) {
                if action == "fill" {
                    for (j, _) in entities.enumerated() {
                        options.append(CuaS1Option(elementId: id, role: role, label: e.title, action: "fill", entityId: "ent_\(j)"))
                    }
                } else {
                    options.append(CuaS1Option(elementId: id, role: role, label: e.title, action: action))
                }
            }
        }
        return (lines.joined(separator: "\n"), options)
    }

    /// Pages of ≤ `size` options; an element's options stay on one page when they fit.
    public static func pages(_ options: [CuaS1Option], size: Int = CuaS1State.maxOptions) -> [[CuaS1Option]] {
        var groups: [[CuaS1Option]] = []
        for o in options {
            if let last = groups.last?.last, last.elementId == o.elementId, groups[groups.count - 1].count < size {
                groups[groups.count - 1].append(o)
            } else {
                groups.append([o])
            }
        }
        var pages: [[CuaS1Option]] = []
        var current: [CuaS1Option] = []
        for g in groups {
            if current.count + g.count > size, !current.isEmpty { pages.append(current); current = [] }
            current += g
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    // MARK: Choosing

    /// Pick one (element, action) for `goal`. Throws `noCandidates` when nothing is actionable.
    public func choose(goal: String, observation: AXSummary, entities: [CuaS1Entity] = [],
                       taskFamily: String? = nil) async throws -> CuaS1Choice {
        let (tree, options) = Self.candidates(from: observation, entities: entities)
        guard !options.isEmpty else { throw CuaS1Error.noCandidates }
        let family = taskFamily ?? (entities.isEmpty ? "navigation" : "form_fill")
        var decisions = 0
        func state(_ opts: [CuaS1Option]) -> CuaS1State {
            CuaS1State(app: observation.app, taskFamily: family, goal: goal, accessibilityTree: tree, options: opts)
        }
        func best(_ opts: [CuaS1Option]) async throws -> (CuaS1Option, Double) {
            if opts.count == 1 { return (opts[0], 1) }
            let decision = try await model.decide(state(opts))
            decisions += 1
            guard decision.probabilities.count == opts.count, let i = decision.bestIndex else {
                throw CuaS1Error.invalidOutput("expected \(opts.count) probabilities, got \(decision.probabilities.count)")
            }
            return (opts[i], decision.probabilities[i])
        }
        var round = Self.pages(options, size: pageSize)
        var winner: (CuaS1Option, Double)
        while true {
            var winners: [(CuaS1Option, Double)] = []
            for page in round { winners.append(try await best(page)) }
            if winners.count == 1 { winner = winners[0]; break }
            // Final round(s) among the page winners: the model re-scores them side by side.
            let next = winners.map(\.0)
            if next.count <= pageSize {
                winner = try await best(next)
                break
            }
            round = Self.pages(next, size: pageSize)
        }
        guard let request = Self.request(for: winner.0, entities: entities) else {
            throw CuaS1Error.invalidOutput("no action for \(winner.0.action)")
        }
        return CuaS1Choice(option: winner.0, probability: winner.1, request: request, decisions: decisions)
    }

    /// (element, action) → the executor's vocabulary. Name-based: the executor re-finds the control.
    public static func request(for option: CuaS1Option, entities: [CuaS1Entity]) -> ActionRequest? {
        switch option.action {
        case "click", "check":
            return ActionRequest(kind: .click, params: ["name": option.label])
        case "select":
            return ActionRequest(kind: .focusTab, params: ["target": option.label])
        case "fill":
            guard let ent = option.entityId, let idx = Int(ent.dropFirst(4)), entities.indices.contains(idx) else { return nil }
            return ActionRequest(kind: .fillField, params: ["name": option.label, "value": entities[idx].value])
        case "focus":
            // Pressing a text field focuses it; never a fill with "" (that would clear it).
            return ActionRequest(kind: .click, params: ["name": option.label])
        default:
            return nil
        }
    }

    /// Choose, then run through the executor (consent is the caller's: `ActRouter` submits the
    /// request through `ConsentEngine` like any catalogue action).
    public func chooseAndRun(goal: String, observation: AXSummary, entities: [CuaS1Entity] = [],
                             executor: ActionExecutor) async throws -> (CuaS1Choice, ActionResult) {
        let choice = try await choose(goal: goal, observation: observation, entities: entities)
        return (choice, executor.run(choice.request))
    }
}
