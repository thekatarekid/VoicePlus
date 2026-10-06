import Foundation

/// Launch fix (RC1) — the presence hint while the speech model is still loading.
///
/// The first launch after every update recompiles the bundled CoreML stack for the Neural Engine
/// (the compile cache is keyed to the model files' identity, and the installer just replaced them):
/// 40–50 s on 2026-10-04 and 2026-10-06. For that whole window the chin said "ready" and the hover
/// read "Hold or Double Tap Option to dictate", so the owner pressed, waited, and pressed again.
/// Dictation does work in that window — capture opens at once and the words are kept — but the text
/// can only arrive once the model is in memory, so the hint says that first.
public enum LaunchModelHint {
    public static let loadingPrefix = "Loading speech model"

    /// `hint` as is when the model is ready; prefixed with the loading notice while it loads.
    public static func readyHint(_ hint: String, modelLoading: Bool) -> String {
        modelLoading ? "\(loadingPrefix) — \(hint)" : hint
    }
}
