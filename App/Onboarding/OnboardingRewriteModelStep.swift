import Providers
import SwiftUI

// X5 — the Rewrite-model step (owner decision, round 3): pick Qwen3.5-2B or Qwen3.5-4B to download,
// or skip. Skipping means one offer in the notch the first time a rewrite command is used, then
// Settings only. The download runs in the background; onboarding never waits for it.

struct OnboardingRewriteModelStep: View {
    @ObservedObject var model: OnboardingViewModel

    private var manager: (any LocalModelManaging)? { model.deps.rewriteModels }
    private var options: [LocalLLMModel] { manager?.models ?? LocalLLMCatalog.shared }
    private var recommendedID: String {
        ProcessInfo.processInfo.physicalMemory >= LocalLLMCatalog.fourBRecommendedBytes
            ? LocalLLMCatalog.qwen35_4B.id : LocalLLMCatalog.qwen35_2B.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingCopy.rewriteHeading).font(.title2.weight(.semibold))
            Text(OnboardingCopy.rewriteBody).foregroundStyle(.secondary)
            ForEach(options) { m in
                let picked = model.machine.rewriteModelPick == m.id
                Button {
                    model.send(.pickRewriteModel(m.id))
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id == LocalLLMCatalog.qwen35_4B.id ? OnboardingCopy.rewriteLargeTitle
                                                                     : OnboardingCopy.rewriteSmallTitle)
                            Text(detail(m)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.machine.rewriteModelPick != nil || manager == nil)
                .accessibilityIdentifier("onboarding.rewriteModel.\(m.id)")
            }
            if model.machine.rewriteModelPick != nil {
                Text(OnboardingCopy.rewriteDownloading).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ m: LocalLLMModel) -> String {
        var parts = ["\(m.sizeLabel) download"]
        if m.id == recommendedID { parts.append(OnboardingCopy.rewriteRecommended) }
        if m.id == LocalLLMCatalog.qwen35_4B.id, m.id != recommendedID { parts.append(OnboardingCopy.rewriteLargeNote) }
        return parts.joined(separator: " · ")
    }
}
