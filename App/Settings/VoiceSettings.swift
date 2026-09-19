import Engine
import Foundation
import Pipeline
import Shared
import SwiftUI

// R5.3 — Settings › Voice: the refinement mode (Auto / Always / Never), what it means, and an
// honest statement of whether a second pass can run on this Mac at all (V3 §5.3, §9.7).

/// Where the refinement mode lives, and what it is when nobody has chosen.
///
/// Defaults to `.auto`: the gate is the whole point of R5.3, and `auto` is the only mode that uses
/// it. Note that `auto` does **not** mean "refinement is on" — the `qwenRefinement` flag is off by
/// default (R5.1's own numbers argue against it), so on a stock install the gate's answer is moot
/// until the flag is flipped. That is stated in the tab rather than implied.
public enum RefinementSettings {
    public static let modeKey = "voice.refinement.mode"

    public static func mode(_ store: SettingsStore?) -> RefinementMode {
        guard let raw = store?.string(modeKey), let mode = RefinementMode(rawValue: raw) else { return .auto }
        return mode
    }

    public static func setMode(_ mode: RefinementMode, store: SettingsStore?) {
        store?.set(mode.rawValue, for: modeKey)
    }

    /// The gate this mode is handed to, thresholds included. One place builds it, so no call site
    /// carries a number of its own.
    public static func gate(_ store: SettingsStore?,
                            settings: RefinementGateSettings = .default) -> RefinementGate {
        RefinementGate(mode: mode(store), settings: settings)
    }
}

/// Whether a second pass can actually run here, and how to say so in one sentence.
///
/// Three independent things have to be true, and V3 §9.7 forbids implying any of them: the feature
/// flag, the OS, and 1.2 GB of weights on disk. Each is reported separately so the note can name the
/// one that is missing instead of a vague "unavailable".
public struct RefinementReadiness: Sendable, Equatable {
    /// `qwenRefinement` — default **off** (R5.1: Qwen 0.6B is the weaker model on the recorded
    /// corpus, mean WER 0.178 against Parakeet's 0.099).
    public var flagEnabled: Bool
    /// Why this Mac cannot run the second pass at all (macOS 14, Intel), or nil.
    public var systemReason: String?
    /// Whether a complete weights directory is on disk. No download is ever started to find out.
    public var weightsPresent: Bool

    public init(flagEnabled: Bool, systemReason: String?, weightsPresent: Bool) {
        self.flagEnabled = flagEnabled
        self.systemReason = systemReason
        self.weightsPresent = weightsPresent
    }

    public var isAvailable: Bool { flagEnabled && systemReason == nil && weightsPresent }

    /// What the tab says under the picker. Never claims a pass that cannot run.
    public var note: String {
        if let systemReason {
            return "A second pass cannot run on this Mac: \(systemReason). Everything else here still works; "
                + "one-pass dictation is unaffected."
        }
        if !flagEnabled {
            return "Refinement is switched off in this build (the qwenRefinement flag, Privacy › Diagnostics). "
                + "It is off by default because on the recorded corpus the second model is less accurate "
                + "overall — mean word error 0.18 against the first pass's 0.10. Your choice here is saved "
                + "and takes effect if the flag is turned on."
        }
        if !weightsPresent {
            return "Refinement is enabled, but the 1.2 GB second-pass model is not on this Mac yet. "
                + "Nothing has been downloaded; until it is, every segment keeps its first-pass text."
        }
        return "Ready: the second-pass model is on this Mac."
    }

    /// Resolved from the real flag service and the real weights directory. Reads the disk; never
    /// downloads (`Qwen3WeightsStore.locate()` is a `stat` of files it already expects).
    public static func resolve(flags: FeatureFlagService?,
                               store: Qwen3WeightsStore = Qwen3WeightsStore()) -> RefinementReadiness {
        RefinementReadiness(
            flagEnabled: flags?.isEnabled(id: ModelStack.refinementFlagID) ?? false,
            systemReason: RefinementAvailability.unavailableReason,
            weightsPresent: store.locate() != nil
        )
    }
}

/// Settings › Voice. One control today — the refinement mode — plus the truth about whether it can
/// do anything.
@MainActor
public final class VoiceSettingsViewModel: ObservableObject {
    @Published public var mode: RefinementMode {
        didSet {
            guard mode != oldValue else { return }
            RefinementSettings.setMode(mode, store: store)
        }
    }
    /// Recomputed on `reload()`; the weights can appear while the window is open.
    @Published public private(set) var readiness: RefinementReadiness

    private let store: SettingsStore?
    private let resolve: @MainActor () -> RefinementReadiness

    public init(store: SettingsStore?, flags: FeatureFlagService?) {
        self.store = store
        let resolver: @MainActor () -> RefinementReadiness = { RefinementReadiness.resolve(flags: flags) }
        self.resolve = resolver
        self.readiness = resolver()
        self.mode = RefinementSettings.mode(store)
    }

    /// Injected readiness, for tests and previews: no disk, no flag file.
    public init(store: SettingsStore?, readiness: RefinementReadiness) {
        self.store = store
        self.resolve = { readiness }
        self.readiness = readiness
        self.mode = RefinementSettings.mode(store)
    }

    public func reload() { readiness = resolve() }

    /// What the picker is worth right now. `false` means the control is shown, explained and
    /// disabled rather than pretending to switch something on (V3 §9.7).
    public var isAvailable: Bool { readiness.isAvailable }

    public var note: String { readiness.note }

    /// One line describing what Auto would do, with the thresholds actually in force — so the
    /// numbers on screen are the numbers the gate uses.
    public func autoSummary(settings: RefinementGateSettings = .default) -> String {
        String(format: "Auto refines a segment when the first pass scores at or below %.2f confidence, "
               + "when a word sounds like a name on screen without being it, when the words are not in a "
               + "Latin script, or when the segment runs past %.0f seconds.",
               settings.lowConfidence, settings.longSegmentSeconds)
    }

    /// The gate as configured here. The composition root hands this to the refinement stage.
    ///
    /// When the pass cannot run the mode is forced to `.never` rather than trusted to the caller's
    /// `RefinementGateSignals.refinementAvailable`: a forgotten flag there would let "Always" load a
    /// model that is not on disk. The decision then reads `modeNever`, and the tab is where the
    /// actual reason is spelled out in words.
    public func gate(settings: RefinementGateSettings = .default) -> RefinementGate {
        RefinementGate(mode: isAvailable ? mode : .never, settings: settings)
    }
}

/// The Voice tab. Owns its view model so `SettingsView` needs no new injected dependency (the same
/// arrangement the microphone section uses).
public struct VoiceSettingsTab: View {
    @StateObject private var model: VoiceSettingsViewModel

    public init(store: SettingsStore?, flags: FeatureFlagService?) {
        _model = StateObject(wrappedValue: VoiceSettingsViewModel(store: store, flags: flags))
    }

    public init(model: VoiceSettingsViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    /// S7e — drawn as the design's rows (`RowView` + a menu select, notes in `meta` ink) so it sits in
    /// Voice › Second pass's group like every other row of the page, not as a system form inside it.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowView(Self.title) {
                Picker(Self.title, selection: $model.mode) {
                    ForEach(RefinementMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .disabled(!model.isAvailable)
                .accessibilityLabel(Self.title)
                .accessibilityIdentifier("settings.refinementMode")
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text(model.mode.explanation)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("settings.refinementModeExplanation")
                Text(model.note)
                    .foregroundStyle(model.isAvailable ? WindowColor.secondaryInk : WindowColor.attention)
                    .accessibilityIdentifier("settings.refinementAvailability")
                if model.mode == .auto {
                    Text(model.autoSummary())
                        .foregroundStyle(WindowColor.secondaryInk)
                        .accessibilityIdentifier("settings.refinementAutoSummary")
                }
            }
            .windowFont(Tokens.Typography.meta)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Tokens.Spacing.m)
            .padding(.horizontal, Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
        }
        .onAppear { model.reload() }
    }

    static let title = "Refinement"
}
