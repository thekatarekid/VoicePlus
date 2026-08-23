import Engine
import Foundation
import Injection
import Shared

/// `DocumentReadback` (Bet 4 safety rule) over Injection's AX focused-element value.
public final class InjectionDocumentReadback: DocumentReadback, @unchecked Sendable {
    private let system: SystemAccess
    public init(system: SystemAccess) { self.system = system }
    public func currentText() -> String? { (try? system.focusedElement())?.value }
}

/// Supplies the two recognisers the dual-path runner needs. Live: the app's recognizer
/// provider (EOU preview + TDT final); tests inject mocks.
public protocol DualPathRecognizers: Sendable {
    func resolve() async throws -> (preview: PreviewRecognizer, final: FinalRecognizer)?
}

public struct ProviderDualPathRecognizers: DualPathRecognizers {
    let provider: RecognizerProvider
    public init(provider: RecognizerProvider) { self.provider = provider }
    public func resolve() async throws -> (preview: PreviewRecognizer, final: FinalRecognizer)? {
        let r = try await provider.resolve()
        guard let p = r.preview else { return nil }
        return (p, r.final)
    }
}

/// P1.5.2 glue: runs `DualPathReconciler` after a landing when `FeatureFlag.dualPath` is on
/// and corrections are enabled for the app; applied/suggested events land in the ledger
/// (overlay + menu + voice undo). Everything is guarded so a mock engine or missing AX is a no-op.
public final class CorrectionService: @unchecked Sendable {
    public let ledger: CorrectionLedger
    public let flags: FeatureFlagService
    public let settings: SettingsStore
    public let readback: DocumentReadback
    public let replaceSink: ReplaceRangeSink
    public var samples: @Sendable () -> [Float]
    public var recognizers: DualPathRecognizers?
    public var planner = CorrectionPlanner()
    public var correctionLog: CorrectionSink?
    private let lock = NSLock()
    private var reconciler: DualPathReconciler?
    public private(set) var lastTiming: DualPathTiming?

    public init(ledger: CorrectionLedger, flags: FeatureFlagService, settings: SettingsStore, readback: DocumentReadback,
                replaceSink: ReplaceRangeSink, recognizers: DualPathRecognizers?, samples: @escaping @Sendable () -> [Float]) {
        self.ledger = ledger; self.flags = flags; self.settings = settings; self.readback = readback
        self.replaceSink = replaceSink; self.recognizers = recognizers; self.samples = samples
    }

    public func isEnabled(for bundleID: String?) -> Bool {
        flags.isEnabled(.dualPath) && CorrectionSettings.isEnabled(for: bundleID, store: settings)
    }

    /// Injects a prebuilt reconciler (tests) — otherwise one is built from `recognizers` on first use.
    public func install(_ r: DualPathReconciler?) { lock.withLock { reconciler = r } }

    private func resolveReconciler() async -> DualPathReconciler? {
        if let r = lock.withLock({ reconciler }) { return r }
        guard let recognizers, let pair = try? await recognizers.resolve() else { return nil }
        let runner = DualPathRunner(preview: pair.preview, final: pair.final)
        runner.onTiming = { [weak self] t in self?.lock.withLock { self?.lastTiming = t } }
        let r = DualPathReconciler(runner: runner, planner: planner,
                                   applier: CorrectionApplier(replaceSink: replaceSink, eventSink: ledger, correctionLog: correctionLog),
                                   flags: [FeatureFlag.dualPath.id: true])
        lock.withLock { reconciler = r }
        return r
    }

    /// Run after a successful landing. `fieldOffset` = caret where the text was injected.
    @discardableResult
    public func reconcile(utteranceID: UUID, fieldOffset: Int, bundleID: String?) async -> [CorrectionEvent] {
        guard isEnabled(for: bundleID) else { return [] }
        let audio = samples()
        guard !audio.isEmpty, let reconciler = await resolveReconciler() else { return [] }
        ledger.currentAppBundleID = bundleID
        do {
            let (plan, events) = try await reconciler.reconcile(utteranceID: utteranceID, samples: audio, fieldOffset: fieldOffset, readback: readback)
            Log.app.info("dualPath: \(plan.items.count) disagreement(s), \(plan.corrections.count) corrected, \(plan.suggestions.count) suggested")
            return events
        } catch {
            Log.app.error("dualPath reconcile failed: \(error)")
            return []
        }
    }
}
