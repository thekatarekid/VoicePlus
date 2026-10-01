import Engine
import Foundation
import SwiftUI

// V5 HW2 — Settings › Models "Memory" group: shows the RAM class picked at first launch and lets the
// user override it. The plan itself lives in `Engine.ResidencyPlanStore`.

/// The picker's options: Automatic (the detected class) or a fixed class.
public enum MemoryTierChoice: Hashable, Sendable {
    case automatic
    case fixed(MemoryClass)

    public static let all: [MemoryTierChoice] = [.automatic] + MemoryClass.allCases.map { .fixed($0) }
}

@MainActor
public final class MemoryTierSettingsModel: ObservableObject {
    private let store: ResidencyPlanStore
    @Published public private(set) var choice: MemoryTierChoice
    @Published public private(set) var plan: ResidencyPlan

    public init(store: ResidencyPlanStore = .shared) {
        self.store = store
        self.choice = store.overrideClass.map(MemoryTierChoice.fixed) ?? .automatic
        self.plan = store.plan
    }

    public var detected: MemoryClass { store.detectedClass }

    public func title(for choice: MemoryTierChoice) -> String {
        switch choice {
        case .automatic: return "Automatic (\(detected.title))"
        case .fixed(let c): return c.title
        }
    }

    public func select(_ choice: MemoryTierChoice) {
        switch choice {
        case .automatic: store.setOverride(nil)
        case .fixed(let c): store.setOverride(c)
        }
        self.choice = choice
        plan = store.plan
    }

    /// The detail under the picker: the plan's summary, plus why features are hidden.
    public var detail: String {
        [plan.summary, plan.explanation].compactMap { $0 }.joined(separator: " ")
    }

    /// Set when the override asks for more than the detected class (the Mac may slow down).
    public var warning: String? {
        guard case .fixed(let c) = choice,
              MemoryClass.allCases.firstIndex(of: c)! > MemoryClass.allCases.firstIndex(of: detected)! else { return nil }
        return "This tier expects more memory than this Mac has. Models may unload often."
    }
}

struct MemoryTierGroup: View {
    @StateObject private var model = MemoryTierSettingsModel()

    var body: some View {
        GroupBox("Memory", layout: .rows) {
            SettingsPickerRow(title: "Model memory tier", detail: model.detail,
                              selection: Binding(get: { model.choice }, set: { model.select($0) }),
                              options: MemoryTierChoice.all, label: { model.title(for: $0) },
                              identifier: "settings.models.memoryTier")
            if let warning = model.warning {
                RowView("Heads up", detail: warning)
                    .accessibilityIdentifier("settings.models.memoryTier.warning")
            }
        }
    }
}
