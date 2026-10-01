import Foundation

// MARK: - V5 CU2 · CUA-S1 element chooser — model-facing types
//
// CUA-S1-4B (`FluidInference/cua-s1-4b-coreml`, Apache-2.0: Qwen3.5-4B + Cua's LoRA) is a one-pass
// *chooser*: given the goal and the accessibility tree as text, it scores up to 26 lettered
// (element, action) options and returns a softmax over them. No pixels, no generation.
//
// The published Swift runtime is FluidUse's `CuaS1FourBManager`
// (`load(configuration: .init(modality: .text, variant: "gptq"))` → `decide(CuaS1FourBState)`).
// The FluidUse revision pinned by J6 (c9e967f) predates it, so Actions talks to the model through
// `CuaS1Deciding`, whose types mirror `CuaS1FourBState` / its options one to one. When the pin moves
// past the manager, the adapter is a field-for-field copy (see `CuaS1Backend`).

/// One lettered option: an element of the AX tree and what to do with it.
public struct CuaS1Option: Equatable, Hashable, Sendable, Codable {
    /// Stable id inside one decision, `el_<n>` (the tree lines carry the same id).
    public var elementId: String
    public var role: String
    public var label: String
    /// `click`, `fill`, `check`, `select`, `focus`, `skip`.
    public var action: String
    /// For `fill`: which entity (value) goes in, `ent_<n>`.
    public var entityId: String?

    public init(elementId: String, role: String, label: String, action: String, entityId: String? = nil) {
        self.elementId = elementId; self.role = role; self.label = label; self.action = action; self.entityId = entityId
    }

    /// Prompt line for the option (Cua's readout format: `<letter>. <action> <role> "<label>"`).
    public var promptText: String {
        "\(action) \(role) \"\(label)\"" + (entityId.map { " with \($0)" } ?? "")
    }
}

/// What the model sees for one decision (`CuaS1FourBState`).
public struct CuaS1State: Equatable, Sendable {
    public var app: String
    /// Cua's task family, e.g. `navigation`, `form_fill`, `login_auth`; free text for us.
    public var taskFamily: String
    public var goal: String
    /// `- [el_0] Button "Log in"` lines.
    public var accessibilityTree: String
    /// 1…26 options.
    public var options: [CuaS1Option]

    public static let maxOptions = 26

    public init(app: String, taskFamily: String, goal: String, accessibilityTree: String, options: [CuaS1Option]) {
        self.app = app; self.taskFamily = taskFamily; self.goal = goal
        self.accessibilityTree = accessibilityTree; self.options = options
    }
}

/// The model's answer: a probability per option, in option order.
public struct CuaS1Decision: Equatable, Sendable {
    public var probabilities: [Double]
    public init(probabilities: [Double]) { self.probabilities = probabilities }

    public var bestIndex: Int? {
        probabilities.indices.max { probabilities[$0] < probabilities[$1] }
    }
}

public enum CuaS1Error: Error, Equatable, Sendable {
    /// The CoreML snapshot is not on this Mac (nothing downloads implicitly).
    case notInstalled
    /// This build's FluidUse has no `CuaS1FourBManager` yet.
    case runtimeMissing
    case tooManyOptions(Int)
    case noCandidates
    case invalidOutput(String)
}

/// The model. Implemented by the FluidUse adapter in production and by mocks in tests.
public protocol CuaS1Deciding: Sendable {
    func decide(_ state: CuaS1State) async throws -> CuaS1Decision
}

/// Load/unload/decide — the shape `ModelResidency` drives. `load` must not download.
public protocol CuaS1Backend: Actor {
    var isLoaded: Bool { get }
    func load() async throws
    func unload()
    func decide(_ state: CuaS1State) async throws -> CuaS1Decision
}
