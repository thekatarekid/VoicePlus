import Actions
import Foundation
import Shared
import SwiftUI

// MARK: - V5 CU1 · Settings › Computer use
//
// Muesli-shaped: enable · act key · where the planner runs (local by default, or a pinned Ollama /
// LM Studio / CLI / ChatGPT / key) · planner model · timeout · consent defaults · plan chips. Every
// row writes through an existing owner where one exists (`GeneralSettingsViewModel.actKey` for the
// switch and the key, `ModelsSettingsViewModel` for `routing.act.planner`) and through
// `ComputerUseSettings` for the rest.

@MainActor
public final class ComputerUseSettingsModel: ObservableObject {
    public let store: SettingsStore
    public let general: GeneralSettingsViewModel
    public let models: ModelsSettingsViewModel

    @Published public var plannerModel: ComputerUseSettings.PlannerModel {
        didSet { ComputerUseSettings.setPlannerModel(plannerModel, store: store); plannerModelChanged() }
    }
    @Published public var timeout: TimeInterval {
        didSet { ComputerUseSettings.setTimeout(timeout, store: store) }
    }
    @Published public var reversible: ConsentPolicy.ReversibleHandling {
        didSet { ComputerUseSettings.setConsentPolicy(policy, store: store) }
    }
    @Published public var semi: ConsentPolicy.SemiHandling {
        didSet { ComputerUseSettings.setConsentPolicy(policy, store: store) }
    }
    @Published public var showPlanChips: Bool {
        didSet { ComputerUseSettings.setShowsPlanChips(showPlanChips, store: store) }
    }

    /// Hook for CU8's install status (re-read when the planner model changes).
    var plannerModelChanged: () -> Void = {}

    public init(store: SettingsStore, general: GeneralSettingsViewModel, models: ModelsSettingsViewModel) {
        self.store = store
        self.general = general
        self.models = models
        plannerModel = ComputerUseSettings.plannerModel(store)
        timeout = ComputerUseSettings.timeout(store)
        let policy = ComputerUseSettings.consentPolicy(store)
        reversible = policy.reversible
        semi = policy.semi
        showPlanChips = ComputerUseSettings.showsPlanChips(store)
    }

    public var policy: ConsentPolicy { ConsentPolicy(reversible: reversible, semi: semi) }

    // MARK: Enable + key (= ActKeySettings, through the Shortcuts view model)

    public var isEnabled: Bool {
        get { general.actKey != .off }
        set {
            guard newValue != isEnabled else { return }
            general.actKey = newValue ? .key(lastKey) : .off
            objectWillChange.send()
        }
    }

    /// The key the act key is (or was last) bound to; Right ⌘ when never chosen.
    public var key: HotkeyChoice {
        get { general.actKey.hotkeyChoice ?? lastKey }
        set {
            store.set(newValue.binding.rawValue, for: HotkeyService.actBindingDefaultsKey)
            if isEnabled { general.actKey = .key(newValue) }
            objectWillChange.send()
        }
    }

    private var lastKey: HotkeyChoice {
        store.string(HotkeyService.actBindingDefaultsKey).flatMap(HotkeyChoice.init(rawValue:)) ?? ActKeyChoice.suggestedKey
    }

    public var keyNote: String { general.actKeyNote }

    // MARK: Provider (routing.act.planner)

    public var plannerStage: RoutableStage {
        RoutableStage.all.first { $0.id == ProviderPlanner.stage }!
    }

    public var providerOptions: [ProviderChoice] { models.options(for: plannerStage) }

    public var provider: ProviderChoice {
        get { models.choice(for: ProviderPlanner.stage) }
        set { models.set(newValue, for: ProviderPlanner.stage); objectWillChange.send() }
    }
}

struct ComputerUseSettingsPage: View {
    @ObservedObject var model: ComputerUseSettingsModel
    @ObservedObject var general: GeneralSettingsViewModel
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.computerUse), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(layout: .rows) {
                    SettingsToggleRow(title: ComputerUseCopy.enableTitle, detail: ComputerUseCopy.enableDetail,
                                      isOn: Binding(get: { model.isEnabled }, set: { model.isEnabled = $0 }),
                                      identifier: "computerUse.enabled")
                    SettingsPickerRow(title: ComputerUseCopy.keyTitle, detail: model.keyNote,
                                      selection: Binding(get: { model.key }, set: { model.key = $0 }),
                                      options: HotkeyChoice.allCases, label: { $0.title },
                                      identifier: "computerUse.actKey")
                        .disabled(!model.isEnabled)
                }
                GroupBox(layout: .rows) {
                    SettingsPickerRow(title: ComputerUseCopy.providerTitle, detail: ComputerUseCopy.providerDetail,
                                      selection: Binding(get: { model.provider }, set: { model.provider = $0 }),
                                      options: model.providerOptions, label: ComputerUseCopy.providerTitle,
                                      identifier: "computerUse.provider")
                    SettingsPickerRow(title: ComputerUseCopy.modelTitle, detail: nil,
                                      selection: $model.plannerModel,
                                      options: ComputerUseSettings.PlannerModel.allCases, label: { $0.title },
                                      identifier: "computerUse.plannerModel")
                    RowView(ComputerUseCopy.timeoutTitle, detail: ComputerUseCopy.timeoutDetail) {
                        HStack(spacing: Tokens.Spacing.s) {
                            Slider(value: $model.timeout, in: ComputerUseSettings.timeoutRange,
                                   step: ComputerUseSettings.timeoutStep)
                                .frame(width: 140)
                                .accessibilityLabel(ComputerUseCopy.timeoutTitle)
                                .accessibilityValue(ComputerUseCopy.seconds(model.timeout))
                                .accessibilityIdentifier("computerUse.timeout")
                            Text(ComputerUseCopy.seconds(model.timeout))
                                .windowFont(Tokens.Typography.duration)
                                .foregroundStyle(WindowColor.ink)
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
                GroupBox(ComputerUseCopy.consentTitle, layout: .rows) {
                    SettingsPickerRow(title: ComputerUseCopy.reversibleTitle, detail: nil,
                                      selection: $model.reversible,
                                      options: ConsentPolicy.ReversibleHandling.allCases,
                                      label: { ComputerUseCopy.title($0) }, identifier: "computerUse.consent.reversible")
                    SettingsPickerRow(title: ComputerUseCopy.semiTitle, detail: nil,
                                      selection: $model.semi,
                                      options: ConsentPolicy.SemiHandling.allCases,
                                      label: { ComputerUseCopy.title($0) }, identifier: "computerUse.consent.semi")
                    RowView(ComputerUseCopy.irreversibleTitle, detail: ComputerUseCopy.irreversibleDetail) {
                        Text("Ask first")
                            .windowFont(Tokens.Typography.body)
                            .foregroundStyle(WindowColor.secondaryInk)
                            .accessibilityIdentifier("computerUse.consent.irreversible")
                    }
                    SettingsToggleRow(title: ComputerUseCopy.chipsTitle, detail: ComputerUseCopy.chipsDetail,
                                      isOn: $model.showPlanChips, identifier: "computerUse.showPlanChips")
                }
                SettingsFootnote(ComputerUseCopy.footnote)
            }
        }
    }
}
