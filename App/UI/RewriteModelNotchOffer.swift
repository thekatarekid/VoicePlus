import Foundation
import Providers
import Shared

/// X5 notch wiring (owner round 3) — when onboarding was skipped, the download of the on-device
/// rewrite model (Qwen3.5-2B / 4B) is offered **once** in the notch, the first time a rewrite command
/// is used; afterwards Settings only (`ModelOfferPolicy`). Nothing downloads unless the user presses
/// Download on the row.
///
/// Two ways the row appears:
/// - `TransformLanding.needsModel` emits `.needsModel(offerDownload: true)` (an LLM command with no
///   model): the driver's reducer owns the row; `sync()` mirrors its Download onto the pill.
/// - `EditModels.notchOfferNotification` (the edit route found no model but the rules handled the
///   command): after `settle`, if the policy still allows it and the notch is empty, the row is shown
///   here and the offer is recorded. A busy notch skips without recording (offered next time).
@MainActor
public final class RewriteModelNotchOffer {
    public static let downloadLabel = "Download"
    public static let offerLine = "Rewrites run on an on-device model · Download it once"

    private let pill: PillViewModel
    private let driver: TransformPillDriver
    private let policy: ModelOfferPolicy
    public var hasReadyModel: () -> Bool
    public var recommendedID: () -> String
    /// Starts the download (live: `EditModels.manager.download`). Called only from the Download button.
    public var startDownload: (String) -> Void
    /// How long the notification waits for the landing's own row (which records the offer first).
    public var settle: TimeInterval = 0.6
    private var offeredID: String?
    private var observer: NSObjectProtocol?

    public init(pill: PillViewModel, driver: TransformPillDriver, policy: ModelOfferPolicy = EditModels.offerPolicy,
                hasReadyModel: @escaping () -> Bool = { EditModels.manager.activeModel != nil },
                recommendedID: @escaping () -> String = {
                    EditModels.manager.recommended()?.id ?? LocalLLMCatalog.qwen35_2B.id
                },
                startDownload: @escaping (String) -> Void = { id in Task { await EditModels.manager.download(id) } }) {
        self.pill = pill
        self.driver = driver
        self.policy = policy
        self.hasReadyModel = hasReadyModel
        self.recommendedID = recommendedID
        self.startDownload = startDownload
        driver.onDownloadModel = { [weak self] in self?.download() }
        pill.onDownloadModel = { [weak self] in
            self?.driver.perform(.downloadModel)
            self?.sync()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Mirror the driver's Download state onto the pill (after every transform event).
    public func sync() { pill.transformOffersDownload = driver.offersDownload }

    /// Listen for `EditModels.notchOfferNotification`.
    public func observe(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: EditModels.notchOfferNotification, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["recommendedModelID"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.settle) { [weak self] in
                    MainActor.assumeIsolated { _ = self?.offerFromNotification(recommendedID: id) }
                }
            }
        }
    }

    /// Shows the one-time row if the policy still allows it and nothing else is on the notch.
    @discardableResult
    public func offerFromNotification(recommendedID id: String?) -> Bool {
        guard policy.shouldOfferInNotch(hasReadyModel: hasReadyModel()) else { return false }
        guard !pill.state.isVisible else { return false }
        policy.recordNotchOfferShown()
        offeredID = id
        driver.handle(.needsModel(line: Self.offerLine, offerDownload: true))
        sync()
        Log.app.notice("rewrite model offered in the notch (one time)")
        return true
    }

    private func download() {
        let id = offeredID ?? recommendedID()
        offeredID = nil
        Log.app.notice("rewrite model download started from the notch")
        startDownload(id)
    }
}
