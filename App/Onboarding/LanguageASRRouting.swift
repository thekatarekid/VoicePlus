import AppKit
import Engine
import Foundation
import Lab
import Shared

/// V5 G1/G2 — the LANG1 answer picks the dictation ASR. Composition-root glue only: the routing
/// itself is `Engine.LanguageRoutedRecognizerProvider`; this file reads the stored languages, builds
/// the Hinglish / Nemotron recognizers from what is installed, and fetches (once, in the background)
/// only the route models the chosen languages need.
public final class LanguageASRRouting: @unchecked Sendable {
    private let settings: () -> SettingsStore?
    private let root: URL
    private let residency: ModelResidency
    private let lock = NSLock()
    private var hinglishBackend: IndicASRBackend?
    private var nemotron: NemotronRuntime?
    private let frontmostBundleID: () -> String?

    public init(settings: @escaping () -> SettingsStore? = { LanguageRuntime.current?.settings },
                root: URL = ModelCatalog.modelsRoot(), residency: ModelResidency = .shared,
                frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.settings = settings; self.root = root; self.residency = residency
        self.frontmostBundleID = frontmostBundleID
    }

    /// The process-wide router (`EngineFactory` hook).
    public static let shared = LanguageASRRouting()

    public var preferences: LanguagePreferences? { LanguagePreferences.load(settings()) }
    /// LANG1 per-app memory: in an app remembered as one language, the route is that language's
    /// (English in Mail → Parakeet; Hindi in WhatsApp → Hinglish), else the chosen languages'.
    public var plan: ASRRoutePlan {
        guard let prefs = preferences else { return .parakeetOnly }
        if let code = AppLanguageMemory(store: settings()).language(for: frontmostBundleID(), chosen: prefs.languages) {
            return prefs.narrowed(to: code).asrRoutePlan
        }
        return prefs.asrRoutePlan
    }

    /// `EngineFactory` hook: wraps the Parakeet provider; with LANG1 unanswered (or English-only)
    /// every resolve is the inner one, byte for byte.
    public static func provider(inner: RecognizerProvider, manager: ModelManager? = nil) -> RecognizerProvider {
        shared.provider(inner: inner, manager: manager)
    }

    public func provider(inner: RecognizerProvider, manager: ModelManager? = nil) -> LanguageRoutedRecognizerProvider {
        if let manager {
            lock.withLock { self.manager = manager }
            observeChanges()
            fetchNeededModels()
        }
        return LanguageRoutedRecognizerProvider(
            inner: inner,
            plan: { [weak self] in self?.plan ?? .parakeetOnly },
            hinglish: { [weak self] in self?.hinglish() },
            multilingual: { [weak self] language in self?.multilingual(language: language) })
    }

    /// The shipped Hinglish candidate when installed (cached; re-checked while missing).
    public func hinglish() -> IndicASRBackend? {
        if let b = lock.withLock({ hinglishBackend }) { return b }
        guard let b = HinglishASRFactory.make(root: root, residency: residency) else { return nil }
        lock.withLock { hinglishBackend = b }
        return b
    }

    /// Nemotron final + preview for `language` when the variant is installed. One runtime (one
    /// resident copy) serves every language: the prompt is per recognizer.
    public func multilingual(language: String?) -> (final: FinalRecognizer, preview: PreviewRecognizer?)? {
        let folder = ModelCatalog.folder(for: .nemotronMultilingual, in: root)
        guard NemotronMultilingualFiles.isInstalled(at: folder) else { return nil }
        let runtime = lock.withLock { () -> NemotronRuntime in
            if let r = nemotron { return r }
            let r = NemotronRuntime.fluid(folder: folder, residency: residency)
            nemotron = r
            return r
        }
        return (NemotronRecognizer(runtime: runtime, language: language), NemotronPreviewRecognizer(runtime: runtime, language: language))
    }

    // MARK: Download only what is needed (LANG1 consumer 1)

    /// Route models the chosen languages need that are missing and actually downloadable (a model
    /// with no remote files — Srota before the owner publishes its CoreML — is installed by its
    /// recipe, never fetched).
    public static func fetchable(_ ids: [ModelID]) -> [ModelID] {
        ids.filter { !ModelCatalog.descriptor($0).remoteFiles.isEmpty }
    }

    private var fetching: Set<ModelID> = []
    /// Only the shipped app (a `.app` bundle) downloads; a test runner never starts a 0.66 GB fetch.
    public var autoFetch = Bundle.main.bundlePath.hasSuffix(".app")
    private weak var manager: ModelManager?

    /// Starts one background fetch per needed, missing, fetchable route model (no-op until the
    /// engine handed over its `ModelManager`, or while LANG1 is unanswered).
    public func fetchNeededModels() {
        guard autoFetch, let manager = lock.withLock({ self.manager }) else { return }
        let needed = Self.fetchable(preferences?.routeModels ?? [])
        for id in needed {
            guard lock.withLock({ fetching.insert(id).inserted }) else { continue }
            Task.detached(priority: .utility) { [weak self] in
                defer { self?.lock.withLock { _ = self?.fetching.remove(id) } }
                guard await !manager.isPresent(id) else { return }
                do {
                    _ = try await manager.ensureAvailable(id)
                    Log.engine.info("language route model installed: \(id.rawValue)")
                } catch {
                    Log.engine.error("language route model fetch failed: \(id.rawValue): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Re-fetch when the languages change (LANG1 answered or edited in Settings).
    private var observer: NSObjectProtocol?
    private func observeChanges() {
        guard lock.withLock({ observer == nil }) else { return }
        let o = NotificationCenter.default.addObserver(forName: LanguagePreferences.didChangeNotification, object: nil, queue: nil) {
            [weak self] _ in self?.fetchNeededModels()
        }
        lock.withLock { observer = o }
    }

    // MARK: V1 — `lab eval --model hinglish-srota | hinglish-nemotron | nemotron-multilingual`

    public static func registerEvalBackends(_ registry: inout LabRegistry, root: URL = ModelCatalog.modelsRoot()) {
        for candidate in HinglishASRCandidate.allCases {
            registry.evalBackends[candidate.evalModelID] = {
                RecognizerEvalBackend(modelID: candidate.evalModelID) {
                    HinglishASRFactory.make(candidate: candidate, root: root)
                }
            }
        }
        registry.evalBackends["nemotron-multilingual"] = {
            RecognizerEvalBackend(modelID: "nemotron-multilingual") {
                LanguageASRRouting(settings: { nil }, root: root).multilingual(language: nil)?.final
            }
        }
    }
}

/// A `FinalRecognizer` on public-set audio for the V1 harness (built lazily on the first item).
final class RecognizerEvalBackend: EvalBackend, @unchecked Sendable {
    let modelID: String
    private let make: @Sendable () -> FinalRecognizer?
    private var recognizer: FinalRecognizer?

    init(modelID: String, make: @escaping @Sendable () -> FinalRecognizer?) { self.modelID = modelID; self.make = make }

    func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput {
        guard stage == .asr, let audioURL else { throw EvalError.stageUnsupported("\(modelID) does \(EvalStage.asr.rawValue) only") }
        if recognizer == nil { recognizer = make() }
        guard let recognizer else { throw EvalError.backendUnavailable("\(modelID) is not installed (see tools/)") }
        let samples = try SampleAudioSource.load16k(url: audioURL)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let spans = try await recognizer.recognize(samples)
        return EvalOutput(text: spans.joinedText, latencyMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
}
