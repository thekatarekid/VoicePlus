import CoreML
import FluidAudio
import FluidUse
import Foundation
import Shared

// MARK: - V5 CU2 · `cua-s1-forms` for form filling (`ActionKind.fillField`)
//
// Per field, the 706 K-param CUA-S1-FORMS scorer picks one of: `fill <Label>: <value>` for each
// entity the user gave, or `check` / `click` / `skip` (FluidUse `FormSchema`, ported from Cua's
// `cua_s1.schema`). ~0.9 ms per field on the ANE. The decision becomes an `ActionRequest` for the
// executor — `fillField` with the entity's value, `click` for check/click, nothing for skip.

/// The scorer. Production: `FluidCuaS1FormsScorer` (FluidAudio `CuaS1FormsManager`); tests: a mock.
public protocol FormOptionScoring: Sendable {
    /// Probabilities per option, in option order (2…32 options).
    func score(context: String, options: [String]) async throws -> [Double]
}

public struct CuaS1FormDecision: Equatable, Sendable {
    public let field: String
    public let option: String
    public let probability: Double
    /// nil = skip.
    public let request: ActionRequest?
}

public struct CuaS1FormsChooser: Sendable {
    public let scorer: any FormOptionScoring
    public init(scorer: any FormOptionScoring) { self.scorer = scorer }

    /// AX role → the role names the forms model was trained on.
    public static func formRole(_ axRole: String) -> String? {
        switch axRole {
        case "AXTextField", "AXTextArea", "AXSearchField": return "Edit"
        case "AXComboBox": return "ComboBox"
        case "AXCheckBox", "AXSwitch": return "CheckBox"
        case "AXButton": return "Button"
        default: return nil
        }
    }

    /// One decision per actionable field of the window, in order.
    public func fill(form observation: AXSummary, entities: [CuaS1Entity]) async throws -> [CuaS1FormDecision] {
        let ents = entities.map { Entity(label: $0.label, value: $0.value) }
        let options = FormSchema.renderOptions(entities: ents)
        var out: [CuaS1FormDecision] = []
        for (i, e) in observation.elements.enumerated() where e.isEnabled {
            guard let role = Self.formRole(e.role) else { continue }
            let element = FormElement(token: "el_\(i)", role: role, label: e.title, value: e.value, placeholder: "",
                                      checked: role == "CheckBox" ? e.isSelected : nil, frame: .zero).forScoring
            guard element.isActionable else { continue }
            let context = FormSchema.renderContext(formTitle: FormSchema.normalizeTitle(observation.window), element: element)
            let probs = try await scorer.score(context: context, options: options)
            guard probs.count == options.count, let best = probs.indices.max(by: { probs[$0] < probs[$1] }) else {
                throw CuaS1Error.invalidOutput("forms: expected \(options.count) probabilities")
            }
            let (action, entity) = FormSchema.decode(optionIndex: best, entityCount: ents.count)
            let request: ActionRequest?
            switch action {
            case .fill:
                request = entity.map { ActionRequest(kind: .fillField, params: ["name": e.title, "value": ents[$0].value]) }
            case .check, .click:
                request = ActionRequest(kind: .click, params: ["name": e.title])
            default:
                request = nil
            }
            out.append(CuaS1FormDecision(field: e.title, option: options[best], probability: probs[best], request: request))
        }
        return out
    }
}

/// FluidAudio's `CuaS1FormsManager`, loaded from the local snapshot only (never downloads) and
/// only inside `ModelResidency` (§10).
public final class FluidCuaS1FormsScorer: FormOptionScoring, @unchecked Sendable {
    actor Box {
        var manager: CuaS1FormsManager?
        func set(_ m: CuaS1FormsManager?) { manager = m }
    }

    private let box = Box()
    private let residency: ModelResidency
    private let modelURL: URL

    /// `~/Library/Application Support/FluidAudio/Models/cua-s1-forms-coreml/cua_s1_forms_fp16_options32.mlmodelc`.
    public static var defaultModelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FluidAudio/Models/cua-s1-forms-coreml", isDirectory: true)
            .appendingPathComponent(ModelNames.CuaS1Forms.modelFile, isDirectory: true)
    }

    public init(residency: ModelResidency = .shared, modelURL: URL = FluidCuaS1FormsScorer.defaultModelURL) {
        self.residency = residency
        self.modelURL = modelURL
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    func register() async {
        let key = CuaS1Catalog.formsResidencyKey
        if await residency.isRegistered(key) { return }
        let box = self.box, url = modelURL
        let entry = CuaS1Catalog.forms
        await residency.register(key, tier: entry.tier, estimatedBytes: entry.residentBytes, lighterAlternative: nil,
                                 owner: "act",
                                 load: {
                                     guard FileManager.default.fileExists(atPath: url.path) else { throw CuaS1Error.notInstalled }
                                     await box.set(try await CuaS1FormsManager.load(from: url))
                                 },
                                 unload: { await box.set(nil) })
    }

    public func score(context: String, options: [String]) async throws -> [Double] {
        guard isInstalled else { throw CuaS1Error.notInstalled }
        await register()
        let box = self.box
        return try await residency.withModel(CuaS1Catalog.formsResidencyKey) {
            guard let manager = await box.manager else { throw CuaS1Error.notInstalled }
            return try await manager.score(context: context, options: options).probabilities.map(Double.init)
        }
    }
}
